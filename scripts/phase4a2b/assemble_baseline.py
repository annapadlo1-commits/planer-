#!/usr/bin/env python3
"""Assemble and render the reviewed Phase 4A.2B baseline for a local restore.

This command is deliberately local-only. It refuses real-looking project refs
that do not begin with ``local`` so a restore-gate command cannot accidentally
prepare environment-bound UAT functions for a remote project.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path


PROJECT_REF_TOKEN = "__PHASE4A2B_PROJECT_REF__"
LOCAL_PROJECT_REF_RE = re.compile(r"^local[a-z]{15}$")
EXPECTED_FORMAT = "phase4a2b-neutral-baseline-v1"


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def assemble(baseline_dir: Path, project_ref: str, output: Path) -> None:
    if not LOCAL_PROJECT_REF_RE.fullmatch(project_ref):
        raise SystemExit(
            "restore project ref must be exactly 20 lowercase letters and start with 'local'"
        )

    manifest_path = baseline_dir / "manifest.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("format") != EXPECTED_FORMAT:
        raise SystemExit("unsupported baseline manifest format")

    expected_paths = [entry["path"] for entry in manifest.get("files", [])]
    actual_paths = sorted(
        path.name
        for path in baseline_dir.iterdir()
        if path.is_file() and path.suffix in {".sql", ".tmpl"}
    )
    if sorted(expected_paths) != actual_paths:
        raise SystemExit(
            f"baseline file set differs from manifest: expected={sorted(expected_paths)!r} "
            f"actual={actual_paths!r}"
        )

    assembled: list[bytes] = []
    token_count = 0
    for entry in manifest["files"]:
        path = baseline_dir / entry["path"]
        data = path.read_bytes()
        if len(data) != entry["bytes"]:
            raise SystemExit(f"byte count mismatch: {path}")
        if sha256_bytes(data) != entry["sha256"]:
            raise SystemExit(f"SHA-256 mismatch: {path}")

        if path.suffix == ".tmpl":
            text = data.decode("utf-8", errors="strict")
            count = text.count(PROJECT_REF_TOKEN)
            if count != 5:
                raise SystemExit(f"expected five environment tokens in {path}, got {count}")
            token_count += count
            data = text.replace(PROJECT_REF_TOKEN, project_ref).encode("utf-8")
        elif PROJECT_REF_TOKEN.encode("ascii") in data:
            raise SystemExit(f"environment token outside template: {path}")

        assembled.append(data)
        if not data.endswith(b"\n"):
            assembled.append(b"\n")

    if token_count != 5:
        raise SystemExit(f"expected five rendered environment tokens, got {token_count}")

    result = b"".join(assembled)
    if PROJECT_REF_TOKEN.encode("ascii") in result:
        raise SystemExit("unrendered environment token remains")
    if result.count(project_ref.encode("ascii")) != 5:
        raise SystemExit("rendered project ref count changed")

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(result)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline-dir", required=True, type=Path)
    parser.add_argument("--project-ref", required=True)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    assemble(args.baseline_dir, args.project_ref, args.output)


if __name__ == "__main__":
    main()
