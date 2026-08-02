from __future__ import annotations

import os
import re
import socket
from dataclasses import dataclass
from urllib.parse import urlsplit

_JOB_PATTERN = re.compile(r"^projects/[^/]+/locations/[^/]+/jobs/[^/]+$")
_NAME_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,199}$")
_CONTAINER_PATTERN = re.compile(r"^[a-z][a-z0-9-]{0,62}$")


def _required(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"Missing required environment variable: {name}")
    return value


def _bounded_int(name: str, default: int, minimum: int, maximum: int) -> int:
    raw = os.environ.get(name, str(default)).strip()
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"Invalid integer environment variable: {name}") from exc
    if not minimum <= value <= maximum:
        raise ValueError(f"Environment variable outside safe bounds: {name}")
    return value


def _machine_token(name: str) -> str:
    token = _required(name)
    looks_like_supabase_credential = token.startswith(
        ("sb_secret_", "sb_publishable_")
    ) or token.count(".") == 2
    if (
        not 32 <= len(token) <= 512
        or looks_like_supabase_credential
        or any(character.isspace() or ord(character) < 32 for character in token)
    ):
        raise ValueError(f"Invalid machine token configuration: {name}")
    return token


def _gateway_url() -> str:
    value = _required("DISPATCHER_GATEWAY_URL")
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or parsed.path != "/functions/v1/solver-gateway"
    ):
        raise ValueError("Invalid dispatcher gateway URL")
    return value


def _dispatcher_id() -> str:
    explicit = os.environ.get("DISPATCHER_ID", "").strip()
    if explicit:
        value = explicit
    else:
        prefix = os.environ.get("DISPATCHER_ID_PREFIX", "grafik-dispatcher").strip()
        revision = os.environ.get("K_REVISION", "local").strip()
        hostname = os.environ.get("HOSTNAME", socket.gethostname()).strip()
        value = f"{prefix}:{revision}:{hostname}"
    if not 3 <= len(value) <= 200 or not _NAME_PATTERN.fullmatch(value):
        raise ValueError("Invalid dispatcher identity")
    return value


@dataclass(frozen=True)
class DispatcherConfig:
    dispatcher_gateway_url: str
    dispatcher_gateway_token: str
    cloud_run_job: str
    solver_container_name: str
    dispatcher_id: str
    dispatch_lease_seconds: int
    max_dispatch_per_request: int
    reconcile_launch_grace_seconds: int
    reconcile_limit: int
    rpc_timeout_seconds: int
    run_api_timeout_seconds: int

    @classmethod
    def from_environment(cls) -> DispatcherConfig:
        job = _required("CLOUD_RUN_JOB")
        if not _JOB_PATTERN.fullmatch(job):
            raise ValueError("Invalid Cloud Run job resource name")
        container = _required("SOLVER_CONTAINER_NAME")
        if not _CONTAINER_PATTERN.fullmatch(container):
            raise ValueError("Invalid solver container name")
        return cls(
            dispatcher_gateway_url=_gateway_url(),
            dispatcher_gateway_token=_machine_token("DISPATCHER_GATEWAY_TOKEN"),
            cloud_run_job=job,
            solver_container_name=container,
            dispatcher_id=_dispatcher_id(),
            dispatch_lease_seconds=_bounded_int(
                "DISPATCH_LEASE_SECONDS", 90, 15, 300
            ),
            max_dispatch_per_request=_bounded_int(
                "MAX_DISPATCH_PER_REQUEST", 5, 1, 20
            ),
            reconcile_launch_grace_seconds=_bounded_int(
                "RECONCILE_LAUNCH_GRACE_SECONDS", 180, 30, 3600
            ),
            reconcile_limit=_bounded_int("RECONCILE_LIMIT", 20, 1, 100),
            rpc_timeout_seconds=_bounded_int("RPC_TIMEOUT_SECONDS", 10, 1, 30),
            run_api_timeout_seconds=_bounded_int(
                "RUN_API_TIMEOUT_SECONDS", 20, 1, 45
            ),
        )
