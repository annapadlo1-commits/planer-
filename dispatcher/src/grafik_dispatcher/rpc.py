from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
import uuid
from collections.abc import Callable
from dataclasses import dataclass
from enum import StrEnum
from typing import Any

ALLOWED_DISPATCHER_ACTIONS = frozenset(
    {
        "solver_dispatch_next_v2",
        "solver_mark_dispatched_v2",
        "solver_release_dispatch_v2",
        "solver_reconcile_stale_v2",
    }
)
MAX_GATEWAY_REQUEST_BYTES = 8192
MAX_GATEWAY_RESPONSE_BYTES = 1_048_576
_EXECUTION_NAME_PATTERN = re.compile(
    r"^projects/[^/]+/locations/[^/]+/jobs/[^/]+/executions/[^/]+$"
)
_CONCLUSIVE_STATES = frozenset(
    {"SUCCEEDED", "FAILED", "CANCELLED", "TERMINAL_UNKNOWN", "NOT_FOUND"}
)


class RpcError(RuntimeError):
    def __init__(self, function: str, status: int | None, retryable: bool):
        super().__init__(
            f"Dispatcher gateway action {function} failed (status={status})"
        )
        self.function = function
        self.status = status
        self.retryable = retryable


@dataclass(frozen=True)
class DispatchReservation:
    run_id: str
    dispatch_token: str
    queue_message_id: int
    dispatch_attempt: int
    solver_version: str


@dataclass(frozen=True)
class DispatchInFlight:
    run_id: str
    claimed_unacknowledged: bool = False


class RecoveryKind(StrEnum):
    RESERVATION_EXPIRED = "RESERVATION_EXPIRED"
    CLAIMED_UNACKNOWLEDGED = "CLAIMED_UNACKNOWLEDGED"
    LAUNCH_EXPIRED = "LAUNCH_EXPIRED"
    LEASE_EXPIRED = "LEASE_EXPIRED"


@dataclass(frozen=True)
class RecoveryCandidate:
    run_id: str
    kind: RecoveryKind
    dispatch_attempt: int
    dispatch_token: str | None
    attempt_number: int | None
    execution_name: str | None
    solver_version: str


@dataclass(frozen=True)
class RecoveryApplyResult:
    applied: bool
    outcome: str
    queue_message_id: int | None = None


UrlOpen = Callable[..., Any]


def _positive_int(payload: dict[str, Any], key: str, function: str) -> int:
    value = payload.get(key)
    if type(value) is not int or value <= 0:
        raise RpcError(function, None, False)
    return value


def _uuid(value: object, function: str) -> str:
    try:
        return str(uuid.UUID(str(value)))
    except (TypeError, ValueError, AttributeError) as exc:
        raise RpcError(function, None, False) from exc


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(
        self,
        req: Any,
        fp: Any,
        code: int,
        msg: str,
        headers: Any,
        newurl: str,
    ) -> None:
        return None


class DispatcherGatewayClient:
    def __init__(
        self,
        gateway_url: str,
        gateway_token: str,
        *,
        timeout_seconds: int,
        urlopen: UrlOpen | None = None,
    ) -> None:
        self._gateway_url = gateway_url
        self._gateway_token = gateway_token
        self._timeout_seconds = timeout_seconds
        self._urlopen = urlopen or urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _NoRedirectHandler()
        ).open

    def _headers(self) -> dict[str, str]:
        return {
            "Accept": "application/json",
            "Content-Type": "application/json",
            "X-Dispatcher-Gateway-Token": self._gateway_token,
            "User-Agent": "grafik-cloud-run-dispatcher/0.1",
        }

    def _call(self, function: str, payload: dict[str, Any]) -> dict[str, Any]:
        if function not in ALLOWED_DISPATCHER_ACTIONS:
            raise RpcError(function, None, False)
        try:
            body = json.dumps(
                {"action": function, "args": payload},
                ensure_ascii=False,
                separators=(",", ":"),
            ).encode()
        except (TypeError, ValueError) as exc:
            raise RpcError(function, None, False) from exc
        if len(body) > MAX_GATEWAY_REQUEST_BYTES:
            raise RpcError(function, None, False)
        request = urllib.request.Request(
            self._gateway_url, data=body, method="POST", headers=self._headers()
        )
        try:
            with self._urlopen(request, timeout=self._timeout_seconds) as response:
                raw = response.read(MAX_GATEWAY_RESPONSE_BYTES + 1)
                if len(raw) > MAX_GATEWAY_RESPONSE_BYTES:
                    raise RpcError(function, None, False)
        except urllib.error.HTTPError as exc:
            status = int(exc.code)
            exc.close()
            raise RpcError(
                function,
                status,
                status in frozenset({408, 425, 429}) or status >= 500,
            ) from exc
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            raise RpcError(function, None, True) from exc
        try:
            decoded = json.loads(raw or b"{}")
        except (json.JSONDecodeError, UnicodeDecodeError) as exc:
            raise RpcError(function, None, False) from exc
        if not isinstance(decoded, dict):
            raise RpcError(function, None, False)
        return decoded

    def reserve_next(
        self, *, dispatcher_id: str, lease_seconds: int
    ) -> DispatchReservation | DispatchInFlight | None:
        function = "solver_dispatch_next_v2"
        payload = self._call(
            function,
            {
                "p_dispatcher_id": dispatcher_id,
                "p_lease_seconds": lease_seconds,
            },
        )
        if payload.get("found") is not True:
            if payload.get("dispatchInFlight") is True:
                return DispatchInFlight(
                    _uuid(payload.get("runId"), function),
                    payload.get("claimedUnacknowledged") is True,
                )
            return None
        return DispatchReservation(
            _uuid(payload.get("runId"), function),
            _uuid(payload.get("dispatchToken"), function),
            _positive_int(payload, "queueMessageId", function),
            _positive_int(payload, "dispatchAttempt", function),
            self._solver_version(payload, function),
        )

    @staticmethod
    def _solver_version(payload: dict[str, Any], function: str) -> str:
        value = payload.get("solverVersion")
        if (
            not isinstance(value, str)
            or not 1 <= len(value) <= 200
            or any(ord(character) < 32 or character.isspace() for character in value)
        ):
            raise RpcError(function, None, False)
        return value

    def mark_dispatched(
        self, reservation: DispatchReservation, execution_name: str
    ) -> None:
        payload = self._call(
            "solver_mark_dispatched_v2",
            {
                "p_run_id": reservation.run_id,
                "p_dispatch_token": reservation.dispatch_token,
                "p_execution_name": execution_name,
            },
        )
        if payload.get("marked") is not True:
            raise RpcError("solver_mark_dispatched_v2", None, False)

    def release(
        self, reservation: DispatchReservation, *, reason: str | None = None
    ) -> None:
        payload = self._call(
            "solver_release_dispatch_v2",
            {
                "p_run_id": reservation.run_id,
                "p_dispatch_token": reservation.dispatch_token,
                "p_reason": (reason or "Cloud Run odrzucił uruchomienie")[:300],
            },
        )
        if payload.get("released") is not True:
            raise RpcError("solver_release_dispatch_v2", None, False)

    def scan_recovery(
        self,
        *,
        dispatcher_id: str,
        limit: int,
        launch_grace_seconds: int,
    ) -> tuple[RecoveryCandidate, ...]:
        function = "solver_reconcile_stale_v2"
        payload = self._call(
            function,
            {
                "p_dispatcher_id": dispatcher_id,
                "p_mode": "SCAN",
                "p_limit": limit,
                "p_launch_grace_seconds": launch_grace_seconds,
                "p_run_id": None,
                "p_kind": None,
                "p_dispatch_token": None,
                "p_dispatch_attempt": None,
                "p_attempt_number": None,
                "p_execution_name": None,
                "p_observed_state": None,
            },
        )
        rows = payload.get("candidates")
        if not isinstance(rows, list) or len(rows) > limit:
            raise RpcError(function, None, False)
        result: list[RecoveryCandidate] = []
        seen: set[tuple[str, RecoveryKind, int]] = set()
        for row in rows:
            if not isinstance(row, dict):
                raise RpcError(function, None, False)
            try:
                kind = RecoveryKind(str(row["kind"]))
                run_id = _uuid(row.get("runId"), function)
                dispatch_attempt = _positive_int(row, "dispatchAttempt", function)
                if dispatch_attempt > 20:
                    raise RpcError(function, None, False)
                token = (
                    None
                    if row.get("dispatchToken") is None
                    else _uuid(row.get("dispatchToken"), function)
                )
                attempt = (
                    None
                    if row.get("attemptNumber") is None
                    else _positive_int(row, "attemptNumber", function)
                )
                execution = row.get("executionName")
                if execution is not None and (
                    not isinstance(execution, str)
                    or not _EXECUTION_NAME_PATTERN.fullmatch(execution)
                ):
                    raise RpcError(function, None, False)
                solver_version = self._solver_version(row, function)
                if kind is RecoveryKind.RESERVATION_EXPIRED:
                    valid = token is not None and attempt is None and execution is None
                elif kind is RecoveryKind.CLAIMED_UNACKNOWLEDGED:
                    valid = (
                        token is not None
                        and attempt is not None
                        and execution is None
                    )
                elif kind is RecoveryKind.LAUNCH_EXPIRED:
                    valid = token is None and attempt is None and execution is not None
                else:
                    valid = (
                        token is None
                        and attempt is not None
                        and execution is not None
                    )
                identity = (run_id, kind, dispatch_attempt)
                if not valid or identity in seen:
                    raise RpcError(function, None, False)
                seen.add(identity)
                result.append(
                    RecoveryCandidate(
                        run_id,
                        kind,
                        dispatch_attempt,
                        token,
                        attempt,
                        execution,
                        solver_version,
                    )
                )
            except (KeyError, ValueError) as exc:
                raise RpcError(function, None, False) from exc
        return tuple(result)

    def apply_recovery(
        self,
        candidate: RecoveryCandidate,
        *,
        dispatcher_id: str,
        launch_grace_seconds: int,
        observed_state: str,
        observed_execution_name: str | None,
    ) -> RecoveryApplyResult:
        function = "solver_reconcile_stale_v2"
        if observed_state not in _CONCLUSIVE_STATES:
            raise RpcError(function, None, False)
        execution_name = candidate.execution_name or observed_execution_name
        if candidate.kind in {
            RecoveryKind.RESERVATION_EXPIRED,
            RecoveryKind.CLAIMED_UNACKNOWLEDGED,
        }:
            if observed_state == "NOT_FOUND":
                execution_name = None
            elif (
                candidate.kind is RecoveryKind.CLAIMED_UNACKNOWLEDGED
                or execution_name is None
            ):
                raise RpcError(function, None, False)
        elif execution_name != candidate.execution_name:
            raise RpcError(function, None, False)
        payload = self._call(
            function,
            {
                "p_dispatcher_id": dispatcher_id,
                "p_mode": "APPLY",
                "p_limit": None,
                "p_launch_grace_seconds": launch_grace_seconds,
                "p_run_id": candidate.run_id,
                "p_kind": candidate.kind.value,
                "p_dispatch_token": candidate.dispatch_token,
                "p_dispatch_attempt": candidate.dispatch_attempt,
                "p_attempt_number": candidate.attempt_number,
                "p_execution_name": execution_name,
                "p_observed_state": observed_state,
            },
        )
        applied = payload.get("applied")
        outcome = payload.get("outcome")
        expected = {"REQUEUED", "FAILED", "CANCELLED"} if applied else {"STALE"}
        if type(applied) is not bool or outcome not in expected:
            raise RpcError(function, None, False)
        message_id = (
            _positive_int(payload, "queueMessageId", function)
            if outcome == "REQUEUED"
            else None
        )
        return RecoveryApplyResult(applied, str(outcome), message_id)
