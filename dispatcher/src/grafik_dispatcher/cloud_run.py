from __future__ import annotations

import re
import time
import uuid
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum
from typing import Any, Protocol

from .rpc import DispatchReservation, RecoveryCandidate, RecoveryKind

_EXECUTION_PATTERN = re.compile(
    r"projects/[^/]+/locations/[^/]+/jobs/[^/]+/executions/[^/]+"
)


class LaunchRejected(RuntimeError):
    """The Run API conclusively rejected the launch."""


class LaunchUncertain(RuntimeError):
    """The launch may have happened and therefore must not be repeated blindly."""


class ReconciliationUnavailable(RuntimeError):
    """Cloud Run execution state could not be read conclusively."""


class ExecutionState(StrEnum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"
    TERMINAL_UNKNOWN = "TERMINAL_UNKNOWN"
    NOT_FOUND = "NOT_FOUND"
    UNKNOWN = "UNKNOWN"

    @property
    def terminal(self) -> bool:
        return self in {
            self.SUCCEEDED,
            self.FAILED,
            self.CANCELLED,
            self.TERMINAL_UNKNOWN,
        }


class LaunchDisposition(StrEnum):
    CREATED = "CREATED"
    EXISTING = "EXISTING"
    RECOVERED_AFTER_UNCERTAIN = "RECOVERED_AFTER_UNCERTAIN"


@dataclass(frozen=True)
class ExecutionIdentity:
    execution_name: str
    run_id: str
    dispatch_token: str
    dispatch_attempt: int
    solver_version: str
    state: ExecutionState = ExecutionState.UNKNOWN


@dataclass(frozen=True)
class LaunchReceipt:
    execution: ExecutionIdentity
    disposition: LaunchDisposition


@dataclass(frozen=True)
class RecoveryObservation:
    state: ExecutionState
    execution: ExecutionIdentity | None = None


class CloudRunApi(Protocol):
    def list_executions(
        self, *, limit: int | None
    ) -> tuple[ExecutionIdentity, ...]: ...

    def get_execution(self, execution_name: str) -> ExecutionIdentity | None: ...

    def start_execution(self, reservation: DispatchReservation) -> str: ...


def dispatch_override_environment(
    reservation: DispatchReservation,
) -> tuple[tuple[str, str], ...]:
    # SOLVER_VERSION deliberately is not an override. It is immutable job image
    # configuration and the SQL claim is the final version fence.
    return (
        ("RUN_ID", reservation.run_id),
        ("DISPATCH_TOKEN", reservation.dispatch_token),
        ("DISPATCH_ATTEMPT", str(reservation.dispatch_attempt)),
    )


def build_run_job_request(
    run_v2: Any,
    *,
    job_name: str,
    container_name: str,
    reservation: DispatchReservation,
) -> Any:
    container_override = run_v2.RunJobRequest.Overrides.ContainerOverride(
        name=container_name,
        env=[
            run_v2.EnvVar(name=name, value=value)
            for name, value in dispatch_override_environment(reservation)
        ],
    )
    return run_v2.RunJobRequest(
        name=job_name,
        overrides=run_v2.RunJobRequest.Overrides(
            container_overrides=[container_override], task_count=1
        ),
    )


def _valid_execution_name(job_name: str, execution_name: str) -> bool:
    return bool(
        _EXECUTION_PATTERN.fullmatch(execution_name)
        and execution_name.startswith(f"{job_name}/executions/")
    )


def _nonnegative(value: object) -> int:
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        return 0
    return max(parsed, 0)


def _execution_state(execution: object) -> ExecutionState:
    running = _nonnegative(getattr(execution, "running_count", 0))
    succeeded = _nonnegative(getattr(execution, "succeeded_count", 0))
    failed = _nonnegative(getattr(execution, "failed_count", 0))
    cancelled = _nonnegative(getattr(execution, "cancelled_count", 0))
    task_count = _nonnegative(getattr(execution, "task_count", 0))
    terminal = bool(getattr(execution, "completion_time", None)) or (
        task_count > 0
        and running == 0
        and succeeded + failed + cancelled >= task_count
    )
    if terminal:
        if failed:
            return ExecutionState.FAILED
        if cancelled:
            return ExecutionState.CANCELLED
        if succeeded:
            return ExecutionState.SUCCEEDED
        return ExecutionState.TERMINAL_UNKNOWN
    if running:
        return ExecutionState.RUNNING
    return ExecutionState.PENDING


def execution_identity_from_resource(
    execution: object, *, job_name: str, container_name: str
) -> ExecutionIdentity | None:
    name = str(getattr(execution, "name", ""))
    if not _valid_execution_name(job_name, name):
        return None
    template = getattr(execution, "template", None)
    containers = getattr(template, "containers", ()) if template else ()
    container = next(
        (
            item
            for item in (containers or ())
            if str(getattr(item, "name", "")) == container_name
        ),
        None,
    )
    if container is None:
        return None
    env = {
        str(getattr(item, "name", "")): str(getattr(item, "value", ""))
        for item in (getattr(container, "env", ()) or ())
        if getattr(item, "name", None)
    }
    try:
        run_id = str(uuid.UUID(env["RUN_ID"]))
        token = str(uuid.UUID(env["DISPATCH_TOKEN"]))
        attempt = int(env["DISPATCH_ATTEMPT"])
        solver_version = env.get("SOLVER_VERSION", "<missing>")
        if (
            not 1 <= len(solver_version) <= 200
            or any(
                ord(character) < 32 or character.isspace()
                for character in solver_version
            )
        ):
            solver_version = "<invalid>"
        if attempt <= 0:
            return None
        return ExecutionIdentity(
            name,
            run_id,
            token,
            attempt,
            solver_version,
            _execution_state(execution),
        )
    except (KeyError, TypeError, ValueError):
        return None


@dataclass(frozen=True)
class _GoogleCloudRunApi:
    job_name: str
    container_name: str
    api_timeout_seconds: int

    def list_executions(
        self, *, limit: int | None
    ) -> tuple[ExecutionIdentity, ...]:
        try:
            from google.cloud import run_v2

            client = run_v2.ExecutionsClient()
            pager = client.list_executions(
                request=run_v2.ListExecutionsRequest(
                    parent=self.job_name,
                    page_size=min(limit or 100, 100),
                    show_deleted=False,
                ),
                retry=None,
                timeout=min(self.api_timeout_seconds, 5),
            )
            identities: list[ExecutionIdentity] = []
            for scanned, resource in enumerate(pager, 1):
                identity = execution_identity_from_resource(
                    resource,
                    job_name=self.job_name,
                    container_name=self.container_name,
                )
                if identity is not None:
                    identities.append(identity)
                if limit is not None and scanned >= limit:
                    break
            return tuple(identities)
        except Exception as exc:
            raise ReconciliationUnavailable(type(exc).__name__) from exc

    def get_execution(self, execution_name: str) -> ExecutionIdentity | None:
        try:
            from google.api_core import exceptions as google_exceptions
            from google.cloud import run_v2
        except Exception as exc:
            raise ReconciliationUnavailable(type(exc).__name__) from exc
        try:
            resource = run_v2.ExecutionsClient().get_execution(
                request=run_v2.GetExecutionRequest(name=execution_name),
                retry=None,
                timeout=min(self.api_timeout_seconds, 5),
            )
        except google_exceptions.NotFound:
            return None
        except Exception as exc:
            raise ReconciliationUnavailable(type(exc).__name__) from exc
        return execution_identity_from_resource(
            resource,
            job_name=self.job_name,
            container_name=self.container_name,
        )

    def start_execution(self, reservation: DispatchReservation) -> str:
        from google.api_core import exceptions as google_exceptions
        from google.auth import exceptions as google_auth_exceptions
        from google.cloud import run_v2

        request = build_run_job_request(
            run_v2,
            job_name=self.job_name,
            container_name=self.container_name,
            reservation=reservation,
        )
        try:
            client = run_v2.JobsClient()
        except google_auth_exceptions.DefaultCredentialsError as exc:
            raise LaunchRejected(type(exc).__name__) from exc
        try:
            operation = client.run_job(
                request=request, retry=None, timeout=self.api_timeout_seconds
            )
        except (
            google_exceptions.BadRequest,
            google_exceptions.Forbidden,
            google_exceptions.NotFound,
            google_exceptions.FailedPrecondition,
            google_exceptions.Unauthenticated,
        ) as exc:
            raise LaunchRejected(type(exc).__name__) from exc
        except Exception as exc:
            raise LaunchUncertain(type(exc).__name__) from exc
        return str(getattr(operation.metadata, "name", ""))


@dataclass(frozen=True)
class CloudRunJobLauncher:
    job_name: str
    container_name: str
    api_timeout_seconds: int
    reconciliation_attempts: int = 3
    reconciliation_delay_seconds: float = 0.5
    reconciliation_scan_limit: int = 100
    api: CloudRunApi | None = None
    sleep: Callable[[float], None] = field(default=time.sleep)

    def _api(self) -> CloudRunApi:
        return self.api or _GoogleCloudRunApi(
            self.job_name, self.container_name, self.api_timeout_seconds
        )

    @staticmethod
    def _matches(
        execution: ExecutionIdentity, reservation: DispatchReservation
    ) -> bool:
        # The image version is intentionally excluded from deduplication. An old
        # image is still a launched execution; SQL rejects its claim safely.
        return (
            execution.run_id == reservation.run_id
            and execution.dispatch_token == reservation.dispatch_token
            and execution.dispatch_attempt == reservation.dispatch_attempt
        )

    def _find(
        self,
        api: CloudRunApi,
        reservation: DispatchReservation,
        *,
        exhaustive: bool = False,
    ) -> ExecutionIdentity | None:
        return next(
            (
                item
                for item in api.list_executions(
                    limit=None if exhaustive else self.reconciliation_scan_limit
                )
                if self._matches(item, reservation)
            ),
            None,
        )

    def _reconcile(
        self, api: CloudRunApi, reservation: DispatchReservation
    ) -> ExecutionIdentity | None:
        last_error: ReconciliationUnavailable | None = None
        successful_read = False
        for attempt in range(max(self.reconciliation_attempts, 1)):
            if attempt and self.reconciliation_delay_seconds:
                self.sleep(self.reconciliation_delay_seconds)
            try:
                execution = self._find(api, reservation)
                successful_read = True
            except ReconciliationUnavailable as exc:
                last_error = exc
                continue
            if execution is not None:
                return execution
        if not successful_read and last_error:
            raise LaunchUncertain("RECONCILIATION_UNAVAILABLE") from last_error
        return None

    def launch(self, reservation: DispatchReservation) -> LaunchReceipt:
        api = self._api()
        try:
            existing = self._find(api, reservation)
        except ReconciliationUnavailable as exc:
            raise LaunchUncertain("PREFLIGHT_RECONCILIATION_FAILED") from exc
        if existing:
            return LaunchReceipt(existing, LaunchDisposition.EXISTING)
        try:
            execution_name = api.start_execution(reservation)
        except LaunchRejected:
            raise
        except Exception as exc:
            recovered = self._reconcile(api, reservation)
            if recovered:
                return LaunchReceipt(
                    recovered, LaunchDisposition.RECOVERED_AFTER_UNCERTAIN
                )
            if isinstance(exc, LaunchUncertain):
                raise
            raise LaunchUncertain(type(exc).__name__) from exc
        if not _valid_execution_name(self.job_name, execution_name):
            recovered = self._reconcile(api, reservation)
            if recovered:
                return LaunchReceipt(
                    recovered, LaunchDisposition.RECOVERED_AFTER_UNCERTAIN
                )
            raise LaunchUncertain("MISSING_EXECUTION_NAME")
        return LaunchReceipt(
            ExecutionIdentity(
                execution_name,
                reservation.run_id,
                reservation.dispatch_token,
                reservation.dispatch_attempt,
                reservation.solver_version,
                ExecutionState.PENDING,
            ),
            LaunchDisposition.CREATED,
        )

    def find_inflight(self, run_id: str) -> tuple[ExecutionIdentity, ...]:
        try:
            executions = self._api().list_executions(limit=None)
        except ReconciliationUnavailable as exc:
            raise LaunchUncertain("INFLIGHT_RECONCILIATION_FAILED") from exc
        return tuple(item for item in executions if item.run_id == run_id)

    def observe_recovery(self, candidate: RecoveryCandidate) -> RecoveryObservation:
        api = self._api()
        try:
            if candidate.kind in {
                RecoveryKind.RESERVATION_EXPIRED,
                RecoveryKind.CLAIMED_UNACKNOWLEDGED,
            }:
                if candidate.dispatch_token is None:
                    return RecoveryObservation(ExecutionState.UNKNOWN)
                execution = self._find(
                    api,
                    DispatchReservation(
                        candidate.run_id,
                        candidate.dispatch_token,
                        0,
                        candidate.dispatch_attempt,
                        candidate.solver_version,
                    ),
                    exhaustive=True,
                )
            else:
                if candidate.execution_name is None:
                    return RecoveryObservation(ExecutionState.UNKNOWN)
                execution = api.get_execution(candidate.execution_name)
        except ReconciliationUnavailable as exc:
            raise LaunchUncertain("RECOVERY_OBSERVATION_FAILED") from exc
        if execution is None:
            return RecoveryObservation(ExecutionState.NOT_FOUND)
        if (
            execution.run_id != candidate.run_id
            or execution.dispatch_attempt != candidate.dispatch_attempt
            or (
                candidate.execution_name is not None
                and execution.execution_name != candidate.execution_name
            )
        ):
            return RecoveryObservation(ExecutionState.UNKNOWN)
        return RecoveryObservation(execution.state, execution)
