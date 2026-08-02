from __future__ import annotations

import os
import re
import socket
import uuid
from dataclasses import dataclass
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


def _required_uuid(name: str) -> str:
    raw = os.getenv(name, "").strip()
    try:
        return str(uuid.UUID(raw))
    except (ValueError, AttributeError) as exc:
        raise ConfigurationError(f"{name} must be a UUID") from exc


@dataclass(frozen=True)
class WorkerConfig:
    solver_gateway_url: str
    solver_gateway_token: str
    run_id: str
    dispatch_token: str
    solver_version: str
    worker_id: str
    task_attempt: int
    rpc_timeout_seconds: int
    heartbeat_seconds: int
    lease_seconds: int
    solver_max_seconds: int
    solver_finalization_reserve_seconds: int = 30

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
        run_id = _required_uuid("RUN_ID")
        dispatch_token = _required_uuid("DISPATCH_TOKEN")
        task_attempt = _positive_int("DISPATCH_ATTEMPT", 1)
        if task_attempt > 20:
            raise ConfigurationError("DISPATCH_ATTEMPT cannot exceed 20")
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
            run_id=run_id,
            dispatch_token=dispatch_token,
            solver_version=solver_version,
            worker_id=worker_id,
            task_attempt=task_attempt,
            rpc_timeout_seconds=_positive_int("RPC_TIMEOUT_SECONDS", 20),
            heartbeat_seconds=heartbeat_seconds,
            lease_seconds=lease_seconds,
            solver_max_seconds=solver_max_seconds,
            solver_finalization_reserve_seconds=finalization_reserve,
        )
