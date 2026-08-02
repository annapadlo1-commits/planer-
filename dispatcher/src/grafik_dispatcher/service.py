from __future__ import annotations

import logging
from dataclasses import dataclass
from typing import Protocol

from .cloud_run import (
    ExecutionIdentity,
    ExecutionState,
    LaunchDisposition,
    LaunchReceipt,
    LaunchRejected,
    LaunchUncertain,
    RecoveryObservation,
)
from .rpc import (
    DispatchInFlight,
    DispatchReservation,
    RecoveryApplyResult,
    RecoveryCandidate,
    RecoveryKind,
    RpcError,
)

LOGGER = logging.getLogger(__name__)


class DispatchRpc(Protocol):
    def reserve_next(
        self, *, dispatcher_id: str, lease_seconds: int
    ) -> DispatchReservation | DispatchInFlight | None: ...

    def mark_dispatched(
        self, reservation: DispatchReservation, execution_name: str
    ) -> None: ...

    def release(
        self, reservation: DispatchReservation, *, reason: str | None = None
    ) -> None: ...

    def scan_recovery(
        self,
        *,
        dispatcher_id: str,
        limit: int,
        launch_grace_seconds: int,
    ) -> tuple[RecoveryCandidate, ...]: ...

    def apply_recovery(
        self,
        candidate: RecoveryCandidate,
        *,
        dispatcher_id: str,
        launch_grace_seconds: int,
        observed_state: str,
        observed_execution_name: str | None,
    ) -> RecoveryApplyResult: ...


class JobLauncher(Protocol):
    def launch(self, reservation: DispatchReservation) -> LaunchReceipt: ...

    def find_inflight(self, run_id: str) -> tuple[ExecutionIdentity, ...]: ...

    def observe_recovery(self, candidate: RecoveryCandidate) -> RecoveryObservation: ...


class DispatchRetryable(RuntimeError):
    """The request can safely be retried by Cloud Scheduler."""


class DispatchUncertain(RuntimeError):
    """The reservation must be retained until reconciliation is conclusive."""


@dataclass(frozen=True)
class RecoverySweepResult:
    inspected: int = 0
    acknowledged: int = 0
    requeued: int = 0
    failed: int = 0
    cancelled: int = 0
    deferred: int = 0
    stale: int = 0

    @property
    def changed(self) -> int:
        return self.acknowledged + self.requeued + self.failed + self.cancelled


@dataclass(frozen=True)
class DispatchBatchResult:
    started: tuple[tuple[str, str], ...]
    reconciled: tuple[tuple[str, str], ...] = ()
    recovery: RecoverySweepResult = RecoverySweepResult()


class DispatchCoordinator:
    def __init__(
        self,
        *,
        rpc: DispatchRpc,
        launcher: JobLauncher,
        dispatcher_id: str,
        lease_seconds: int,
        max_per_request: int,
        launch_grace_seconds: int = 180,
        recovery_limit: int = 20,
    ) -> None:
        self._rpc = rpc
        self._launcher = launcher
        self._dispatcher_id = dispatcher_id
        self._lease_seconds = lease_seconds
        self._max_per_request = max_per_request
        self._launch_grace_seconds = launch_grace_seconds
        self._recovery_limit = recovery_limit

    @staticmethod
    def _reservation_from_execution(
        run_id: str, execution: ExecutionIdentity
    ) -> DispatchReservation:
        return DispatchReservation(
            run_id,
            execution.dispatch_token,
            0,
            execution.dispatch_attempt,
            execution.solver_version,
        )

    def _sweep_recovery(self) -> RecoverySweepResult:
        candidates = self._rpc.scan_recovery(
            dispatcher_id=self._dispatcher_id,
            limit=self._recovery_limit,
            launch_grace_seconds=self._launch_grace_seconds,
        )
        counts = {
            "acknowledged": 0,
            "requeued": 0,
            "failed": 0,
            "cancelled": 0,
            "deferred": 0,
            "stale": 0,
        }
        for candidate in candidates:
            try:
                observation = self._launcher.observe_recovery(candidate)
            except LaunchUncertain:
                LOGGER.warning(
                    "Cloud Run recovery observation unavailable for run_id=%s",
                    candidate.run_id,
                )
                counts["deferred"] += 1
                continue

            # A worker can claim before the dispatcher acknowledgement reaches
            # Postgres. Repair that acknowledgement first, regardless of whether
            # the execution has already completed.
            if (
                candidate.kind is RecoveryKind.CLAIMED_UNACKNOWLEDGED
                and observation.execution is not None
                and observation.state is not ExecutionState.UNKNOWN
            ):
                self._rpc.mark_dispatched(
                    self._reservation_from_execution(
                        candidate.run_id, observation.execution
                    ),
                    observation.execution.execution_name,
                )
                counts["acknowledged"] += 1
                continue

            if observation.state in {
                ExecutionState.PENDING,
                ExecutionState.RUNNING,
                ExecutionState.UNKNOWN,
            }:
                if (
                    candidate.kind is RecoveryKind.RESERVATION_EXPIRED
                    and observation.execution is not None
                    and observation.state
                    in {ExecutionState.PENDING, ExecutionState.RUNNING}
                ):
                    self._rpc.mark_dispatched(
                        self._reservation_from_execution(
                            candidate.run_id, observation.execution
                        ),
                        observation.execution.execution_name,
                    )
                    counts["acknowledged"] += 1
                else:
                    counts["deferred"] += 1
                continue

            if not observation.state.terminal and (
                observation.state is not ExecutionState.NOT_FOUND
            ):
                counts["deferred"] += 1
                continue

            outcome = self._rpc.apply_recovery(
                candidate,
                dispatcher_id=self._dispatcher_id,
                launch_grace_seconds=self._launch_grace_seconds,
                observed_state=observation.state.value,
                observed_execution_name=(
                    observation.execution.execution_name
                    if observation.execution
                    else None
                ),
            )
            if not outcome.applied:
                counts["stale"] += 1
            elif outcome.outcome == "REQUEUED":
                counts["requeued"] += 1
            elif outcome.outcome == "FAILED":
                counts["failed"] += 1
            elif outcome.outcome == "CANCELLED":
                counts["cancelled"] += 1
        return RecoverySweepResult(inspected=len(candidates), **counts)

    def _reconcile_inflight(self, inflight: DispatchInFlight) -> tuple[str, bool]:
        try:
            executions = self._launcher.find_inflight(inflight.run_id)
        except LaunchUncertain as exc:
            raise DispatchUncertain("INFLIGHT_RECONCILIATION_FAILED") from exc
        if not executions:
            raise DispatchUncertain("EXECUTION_NOT_VISIBLE")
        for execution in executions:
            reservation = self._reservation_from_execution(
                inflight.run_id, execution
            )
            try:
                if inflight.claimed_unacknowledged:
                    self._rpc.mark_dispatched(
                        reservation, execution.execution_name
                    )
                    return execution.execution_name, True
                if execution.state.terminal:
                    self._rpc.release(
                        reservation,
                        reason=f"Cloud Run execution {execution.state.value}",
                    )
                    return execution.execution_name, False
                self._rpc.mark_dispatched(reservation, execution.execution_name)
                return execution.execution_name, True
            except RpcError as exc:
                if exc.retryable:
                    raise DispatchUncertain("RECONCILIATION_RPC_FAILED") from exc
                continue
        raise DispatchUncertain("MATCHING_DISPATCH_TOKEN_NOT_FOUND")

    def dispatch_batch(self) -> DispatchBatchResult:
        recovery = self._sweep_recovery()
        started: list[tuple[str, str]] = []
        reconciled: list[tuple[str, str]] = []
        for _ in range(self._max_per_request):
            dispatch = self._rpc.reserve_next(
                dispatcher_id=self._dispatcher_id,
                lease_seconds=self._lease_seconds,
            )
            if dispatch is None:
                break
            if isinstance(dispatch, DispatchInFlight):
                execution_name, acknowledged = self._reconcile_inflight(dispatch)
                if not acknowledged:
                    raise DispatchRetryable("TERMINAL_EXECUTION_RELEASED")
                started.append((dispatch.run_id, execution_name))
                reconciled.append((dispatch.run_id, execution_name))
                continue
            try:
                receipt = self._launcher.launch(dispatch)
            except LaunchRejected as exc:
                try:
                    self._rpc.release(dispatch, reason=str(exc))
                except RpcError as release_error:
                    raise DispatchUncertain("RELEASE_FAILED") from release_error
                raise DispatchRetryable("RUN_API_REJECTED") from exc
            except LaunchUncertain as exc:
                LOGGER.error(
                    "Cloud Run launch is uncertain for run_id=%s; reservation retained",
                    dispatch.run_id,
                )
                raise DispatchUncertain("RUN_API_UNCERTAIN") from exc

            if receipt.execution.state.terminal:
                try:
                    self._rpc.release(
                        dispatch,
                        reason=(
                            f"Cloud Run execution {receipt.execution.state.value} "
                            "before acknowledgement"
                        ),
                    )
                except RpcError as release_error:
                    raise DispatchUncertain("RELEASE_FAILED") from release_error
                raise DispatchRetryable("TERMINAL_EXECUTION_RELEASED")

            execution_name = receipt.execution.execution_name
            try:
                self._rpc.mark_dispatched(dispatch, execution_name)
            except RpcError as exc:
                LOGGER.error(
                    "Could not acknowledge execution for run_id=%s execution=%s",
                    dispatch.run_id,
                    execution_name,
                )
                raise DispatchUncertain("ACKNOWLEDGEMENT_FAILED") from exc
            started.append((dispatch.run_id, execution_name))
            if receipt.disposition is not LaunchDisposition.CREATED:
                reconciled.append((dispatch.run_id, execution_name))
        return DispatchBatchResult(tuple(started), tuple(reconciled), recovery)
