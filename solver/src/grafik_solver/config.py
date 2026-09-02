from __future__ import annotations

import os
import re
import socket
from dataclasses import dataclass
from datetime import datetime, timezone
from urllib.parse import urlsplit

from . import __version__


class ConfigurationError(ValueError):
    pass


def _positive_int(name: str, default: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        parsed = int(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be an integer") from exc
    if parsed <= 0:
        raise ConfigurationError(f"{name} must be positive")
    return parsed


def _nonnegative_int(name: str, default: int) -> int:
    raw = os.getenv(name, str(default))
    try:
        parsed = int(raw)
    except ValueError as exc:
        raise ConfigurationError(f"{name} must be an integer") from exc
    if parsed < 0:
        raise ConfigurationError(f"{name} cannot be negative")
    return parsed


@dataclass(frozen=True)
class WorkerConfig:
    solver_gateway_url: str
    solver_gateway_token: str
    solver_version: str
    worker_id: str
    task_attempt: int
    poll_interval_seconds: int
    max_runs: int
    idle_exit_seconds: int
    rpc_timeout_seconds: int
    heartbeat_seconds: int
    lease_seconds: int
    solver_max_seconds: int
    solver_finalization_reserve_seconds: int = 30
    contract_version: str = "SOLVER_CONTRACT_V2"
    source_sha: str = "0" * 40
    image_digest: str = "sha256:" + "0" * 64
    build_timestamp: str = "1970-01-01T00:00:00Z"

    @classmethod
    def from_env(cls) -> WorkerConfig:
        gateway_url = os.getenv("SOLVER_GATEWAY_URL", "").strip().rstrip("/")
        gateway_token = os.getenv("SOLVER_GATEWAY_TOKEN", "").strip()
        parsed_gateway = urlsplit(gateway_url)
        if (
            parsed_gateway.scheme != "https"
            or not parsed_gateway.netloc
            or parsed_gateway.username is not None
            or parsed_gateway.password is not None
            or parsed_gateway.query
            or parsed_gateway.fragment
            or parsed_gateway.path != "/functions/v1/solver-gateway"
        ):
            raise ConfigurationError(
                "SOLVER_GATEWAY_URL must be an HTTPS solver-gateway URL"
            )
        gateway_token_is_api_key = (
            gateway_token.startswith(("sb_secret_", "sb_publishable_"))
            or gateway_token.count(".") == 2
        )
        if (
            not 32 <= len(gateway_token) <= 512
            or gateway_token_is_api_key
            or any(
                character.isspace() or not character.isprintable()
                for character in gateway_token
            )
        ):
            raise ConfigurationError(
                "SOLVER_GATEWAY_TOKEN must be a dedicated 32-512 character token"
            )
        task_attempt = _positive_int("WORKER_TASK_ATTEMPT", 1)
        if task_attempt > 20:
            raise ConfigurationError("WORKER_TASK_ATTEMPT cannot exceed 20")
        explicit_worker_id = os.getenv("WORKER_ID", "").strip()
        worker_source = explicit_worker_id or socket.gethostname() or "solver-worker"
        worker_source = re.sub(r"[^A-Za-z0-9._:@/-]", "-", worker_source)
        worker_id = f"{worker_source}:{os.getpid()}"[:200]
        if len(worker_id) < 3:
            raise ConfigurationError("WORKER_ID must contain at least 3 characters")
        solver_version = os.getenv("SOLVER_VERSION", __version__).strip()
        if (
            not 1 <= len(solver_version) <= 200
            or any(
                character.isspace() or not character.isprintable()
                for character in solver_version
            )
        ):
            raise ConfigurationError("SOLVER_VERSION must identify this worker image")
        contract_version = os.getenv("SOLVER_CONTRACT_VERSION", "").strip()
        if not re.fullmatch(r"[A-Z][A-Z0-9_]{2,99}", contract_version):
            raise ConfigurationError(
                "SOLVER_CONTRACT_VERSION must be an explicit version identifier"
            )
        declared_source_sha = os.getenv("SOLVER_SOURCE_SHA", "").strip()
        platform_source_sha = os.getenv("NF_DEPLOYMENT_SHA", "").strip()
        if (
            platform_source_sha
            and declared_source_sha
            and platform_source_sha != declared_source_sha
        ):
            raise ConfigurationError(
                "SOLVER_SOURCE_SHA must match NF_DEPLOYMENT_SHA"
            )
        source_sha = platform_source_sha or declared_source_sha
        if not re.fullmatch(r"[0-9a-f]{40}", source_sha):
            raise ConfigurationError(
                "NF_DEPLOYMENT_SHA or SOLVER_SOURCE_SHA must be the exact lowercase "
                "40-character Git SHA"
            )
        image_digest = os.getenv("SOLVER_IMAGE_DIGEST", "").strip()
        if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_digest):
            raise ConfigurationError(
                "SOLVER_IMAGE_DIGEST must be an immutable sha256 image digest"
            )
        build_timestamp = os.getenv("SOLVER_BUILD_TIMESTAMP", "").strip()
        try:
            parsed_build_timestamp = datetime.fromisoformat(
                build_timestamp.removesuffix("Z") + "+00:00"
            )
        except ValueError as exc:
            raise ConfigurationError(
                "SOLVER_BUILD_TIMESTAMP must be an ISO-8601 UTC timestamp"
            ) from exc
        if (
            not build_timestamp.endswith("Z")
            or parsed_build_timestamp.tzinfo != timezone.utc
            or parsed_build_timestamp.microsecond != 0
        ):
            raise ConfigurationError(
                "SOLVER_BUILD_TIMESTAMP must be an ISO-8601 UTC timestamp"
            )
        heartbeat_seconds = _positive_int("HEARTBEAT_SECONDS", 20)
        lease_seconds = _positive_int("LEASE_SECONDS", 90)
        if not 30 <= lease_seconds <= 900:
            raise ConfigurationError("LEASE_SECONDS must be between 30 and 900")
        if heartbeat_seconds >= lease_seconds:
            raise ConfigurationError(
                "HEARTBEAT_SECONDS must be lower than LEASE_SECONDS"
            )
        solver_max_seconds = _positive_int("SOLVER_MAX_SECONDS", 300)
        finalization_reserve = _nonnegative_int(
            "SOLVER_FINALIZATION_RESERVE_SECONDS", 30
        )
        if finalization_reserve >= solver_max_seconds:
            raise ConfigurationError(
                "SOLVER_FINALIZATION_RESERVE_SECONDS must be lower than "
                "SOLVER_MAX_SECONDS"
            )
        return cls(
            solver_gateway_url=gateway_url,
            solver_gateway_token=gateway_token,
            solver_version=solver_version,
            worker_id=worker_id,
            task_attempt=task_attempt,
            poll_interval_seconds=_positive_int("POLL_INTERVAL_SECONDS", 10),
            max_runs=_nonnegative_int("MAX_RUNS", 0),
            idle_exit_seconds=_nonnegative_int("IDLE_EXIT_SECONDS", 0),
            rpc_timeout_seconds=_positive_int("RPC_TIMEOUT_SECONDS", 20),
            heartbeat_seconds=heartbeat_seconds,
            lease_seconds=lease_seconds,
            solver_max_seconds=solver_max_seconds,
            solver_finalization_reserve_seconds=finalization_reserve,
            contract_version=contract_version,
            source_sha=source_sha,
            image_digest=image_digest,
            build_timestamp=build_timestamp,
        )
