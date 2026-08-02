from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import asdict, is_dataclass
from datetime import date, datetime, time
from decimal import Decimal
from enum import Enum
from typing import Any


def normalize(value: Any, *, exclude_snapshot_hash: bool = False) -> Any:
    if is_dataclass(value):
        value = asdict(value)
    if isinstance(value, Mapping):
        return {
            str(key): normalize(item, exclude_snapshot_hash=exclude_snapshot_hash)
            for key, item in sorted(value.items(), key=lambda pair: str(pair[0]))
            if not (
                exclude_snapshot_hash and str(key) in {"snapshotHash", "snapshot_hash"}
            )
        }
    if isinstance(value, (set, frozenset)):
        normalized = [
            normalize(item, exclude_snapshot_hash=exclude_snapshot_hash)
            for item in value
        ]
        return sorted(normalized, key=canonical_json)
    if isinstance(value, (list, tuple)):
        return [
            normalize(item, exclude_snapshot_hash=exclude_snapshot_hash)
            for item in value
        ]
    if isinstance(value, datetime):
        return value.isoformat()
    if isinstance(value, (date, time)):
        return value.isoformat()
    if isinstance(value, Decimal):
        return format(value, "f")
    if isinstance(value, Enum):
        return normalize(value.value, exclude_snapshot_hash=exclude_snapshot_hash)
    if value is None or isinstance(value, (str, int, bool)):
        return value
    if isinstance(value, float):
        if not value.is_integer():
            raise TypeError("Canonical snapshots must not contain non-integral floats")
        return int(value)
    raise TypeError(f"Unsupported canonical value: {type(value).__name__}")


def canonical_json(value: Any, *, exclude_snapshot_hash: bool = False) -> str:
    return json.dumps(
        normalize(value, exclude_snapshot_hash=exclude_snapshot_hash),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def sha256_hex(value: Any, *, exclude_snapshot_hash: bool = False) -> str:
    payload = canonical_json(value, exclude_snapshot_hash=exclude_snapshot_hash).encode(
        "utf-8"
    )
    return hashlib.sha256(payload).hexdigest()


def verify_snapshot_hash(snapshot: Mapping[str, Any], expected_hash: str) -> str:
    actual_hash = sha256_hex(snapshot, exclude_snapshot_hash=True)
    if not expected_hash or actual_hash.lower() != expected_hash.lower():
        expected_label = expected_hash or "<missing>"
        raise ValueError(
            f"Snapshot hash mismatch: expected {expected_label}, got {actual_hash}"
        )
    return actual_hash
