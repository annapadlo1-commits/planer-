from __future__ import annotations

import json
import random
import time
import urllib.error
import urllib.request
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

ALLOWED_GATEWAY_ACTIONS = frozenset(
    {
        "solver_claim_next_v2",
        "solver_load_snapshot_v2",
        "solver_heartbeat_v2",
        "solver_save_variant_v2",
        "solver_finalize_v2",
        "solver_interrupt_v2",
        "solver_fail_attempt_v2",
    }
)
MAX_GATEWAY_REQUEST_BYTES = 8 * 1024 * 1024
MAX_GATEWAY_RESPONSE_BYTES = 64 * 1024 * 1024


class RpcError(RuntimeError):
    def __init__(self, message: str, *, retryable: bool, status: int | None = None):
        super().__init__(message)
        self.retryable = retryable
        self.status = status


def _pick(raw: Mapping[str, Any], *names: str, default: Any = None) -> Any:
    for name in names:
        if name in raw:
            return raw[name]
    return default


def _row(value: Any) -> Mapping[str, Any] | None:
    if value is None:
        return None
    if isinstance(value, list):
        if not value:
            return None
        value = value[0]
    if isinstance(value, Mapping):
        return value
    raise RpcError("RPC returned an unexpected response shape", retryable=False)


@dataclass(frozen=True)
class Claim:
    run_id: str
    attempt_id: str
    lease_token: str


@dataclass(frozen=True)
class SnapshotEnvelope:
    snapshot: Mapping[str, Any]
    snapshot_hash: str


@dataclass(frozen=True)
class Heartbeat:
    cancel_requested: bool
    lease_valid: bool


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):  # noqa: ANN001
        return None


class SolverGatewayClient:
    def __init__(
        self,
        gateway_url: str,
        gateway_token: str,
        *,
        timeout_seconds: int = 20,
        maximum_attempts: int = 4,
    ):
        self.gateway_url = gateway_url.rstrip("/")
        self._gateway_token = gateway_token
        self.timeout_seconds = timeout_seconds
        self.maximum_attempts = max(1, maximum_attempts)
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}),
            _NoRedirectHandler(),
        )

    def _headers(self) -> dict[str, str]:
        return {
            "X-Solver-Gateway-Token": self._gateway_token,
            "Content-Type": "application/json",
            "Accept": "application/json",
            "User-Agent": "grafik-solver/0.1",
        }

    def call(self, name: str, payload: Mapping[str, Any]) -> Any:
        if name not in ALLOWED_GATEWAY_ACTIONS:
            raise RpcError(f"Gateway action {name} is not allowed", retryable=False)
        try:
            body = json.dumps(
                {"action": name, "args": dict(payload)},
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode("utf-8")
        except (TypeError, ValueError) as exc:
            raise RpcError(
                f"Gateway request {name} is not valid JSON", retryable=False
            ) from exc
        if len(body) > MAX_GATEWAY_REQUEST_BYTES:
            raise RpcError(
                f"Gateway request {name} exceeds the client limit",
                retryable=False,
            )
        last_error: RpcError | None = None
        for attempt in range(self.maximum_attempts):
            request = urllib.request.Request(
                url=self.gateway_url,
                data=body,
                headers=self._headers(),
                method="POST",
            )
            try:
                with self._opener.open(
                    request, timeout=self.timeout_seconds
                ) as response:
                    raw = response.read(MAX_GATEWAY_RESPONSE_BYTES + 1)
                    if len(raw) > MAX_GATEWAY_RESPONSE_BYTES:
                        raise RpcError(
                            f"Gateway response {name} exceeds the client limit",
                            retryable=False,
                        )
                    return None if not raw else json.loads(raw.decode("utf-8"))
            except urllib.error.HTTPError as exc:
                retryable = exc.code == 429 or 500 <= exc.code < 600
                last_error = RpcError(
                    f"Gateway action {name} returned HTTP {exc.code}",
                    retryable=retryable,
                    status=exc.code,
                )
                exc.close()
                if not retryable:
                    raise last_error from exc
            except (urllib.error.URLError, TimeoutError, ConnectionError):
                last_error = RpcError(
                    f"Gateway action {name} failed due to a network error",
                    retryable=True,
                )
            except json.JSONDecodeError as exc:
                raise RpcError(
                    f"Gateway action {name} returned invalid JSON", retryable=False
                ) from exc
            if attempt + 1 < self.maximum_attempts:
                delay = min(0.25 * (2**attempt), 2.0) + random.uniform(0.0, 0.1)
                time.sleep(delay)
        assert last_error is not None
        raise last_error

    def claim(
        self,
        *,
        worker_id: str,
        worker_version: str,
        task_attempt: int,
        lease_seconds: int,
    ) -> Claim | None:
        raw = _row(
            self.call(
                "solver_claim_next_v2",
                {
                    "p_worker_id": worker_id,
                    "p_worker_version": worker_version,
                    "p_task_attempt": task_attempt,
                    "p_lease_seconds": lease_seconds,
                },
            )
        )
        return self._claim_from(raw, "solver_claim_next_v2")

    @staticmethod
    def _claim_from(raw: Mapping[str, Any] | None, action: str) -> Claim | None:
        if raw is None or _pick(raw, "claimed", default=True) is False:
            return None
        claimed_run_id = _pick(raw, "runId", "run_id")
        attempt_id = _pick(raw, "attemptId", "attempt_id")
        lease_token = _pick(raw, "leaseToken", "lease_token")
        if not all((claimed_run_id, attempt_id, lease_token)):
            raise RpcError(f"{action} omitted lease fields", retryable=False)
        return Claim(str(claimed_run_id), str(attempt_id), str(lease_token))

    def load_snapshot(self, claim: Claim) -> SnapshotEnvelope:
        raw = _row(
            self.call(
                "solver_load_snapshot_v2",
                {
                    "p_run_id": claim.run_id,
                    "p_attempt_id": claim.attempt_id,
                    "p_lease_token": claim.lease_token,
                },
            )
        )
        if raw is None:
            raise RpcError(
                "solver_load_snapshot_v2 returned no snapshot", retryable=False
            )
        snapshot = _pick(raw, "snapshot", "snapshot_json")
        snapshot_hash = _pick(raw, "snapshotHash", "snapshot_hash")
        if not isinstance(snapshot, Mapping) or not snapshot_hash:
            raise RpcError(
                "solver_load_snapshot_v2 returned an invalid envelope", retryable=False
            )
        return SnapshotEnvelope(
            snapshot=dict(snapshot), snapshot_hash=str(snapshot_hash)
        )

    def heartbeat(self, claim: Claim, progress: Mapping[str, Any]) -> Heartbeat:
        raw = _row(
            self.call(
                "solver_heartbeat_v2",
                {
                    "p_run_id": claim.run_id,
                    "p_attempt_id": claim.attempt_id,
                    "p_lease_token": claim.lease_token,
                    "p_progress": dict(progress),
                },
            )
        )
        return Heartbeat(
            cancel_requested=bool(
                _pick(raw or {}, "cancelRequested", "cancel_requested", default=False)
            ),
            lease_valid=bool(
                _pick(raw or {}, "leaseValid", "lease_valid", default=True)
            ),
        )

    def save_variant(self, claim: Claim, variant: Mapping[str, Any]) -> Any:
        return self.call(
            "solver_save_variant_v2",
            {
                "p_run_id": claim.run_id,
                "p_attempt_id": claim.attempt_id,
                "p_lease_token": claim.lease_token,
                "p_variant": dict(variant),
            },
        )

    def finalize(self, claim: Claim) -> Any:
        return self.call(
            "solver_finalize_v2",
            {
                "p_run_id": claim.run_id,
                "p_attempt_id": claim.attempt_id,
                "p_lease_token": claim.lease_token,
            },
        )

    def interrupt(self, claim: Claim, reason: str) -> Any:
        return self.call(
            "solver_interrupt_v2",
            {
                "p_run_id": claim.run_id,
                "p_attempt_id": claim.attempt_id,
                "p_lease_token": claim.lease_token,
                "p_reason": reason,
            },
        )

    def fail_attempt(
        self,
        claim: Claim,
        *,
        error_code: str,
        error_message: str,
        retryable: bool,
    ) -> Any:
        return self.call(
            "solver_fail_attempt_v2",
            {
                "p_run_id": claim.run_id,
                "p_attempt_id": claim.attempt_id,
                "p_lease_token": claim.lease_token,
                "p_error_code": error_code,
                "p_error_message": error_message[:1000],
                "p_retryable": retryable,
            },
        )
