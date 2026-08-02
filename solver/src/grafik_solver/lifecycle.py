from __future__ import annotations

import logging
import signal
import threading
import time
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any, Protocol

from .canonical import verify_snapshot_hash
from .config import WorkerConfig
from .cp_sat_engine import (
    CpSatScheduleEngine,
    OptimizationCancelled,
    OptimizationError,
    OptimizationIncomplete,
)
from .models import Snapshot, SnapshotError
from .rpc import Claim, RpcError, SolverGatewayClient
from .validator import VariantValidationError, validate_variant

LOGGER = logging.getLogger(__name__)


class RpcProtocol(Protocol):
    def claim(self, **kwargs: Any) -> Claim | None: ...
    def load_snapshot(self, claim: Claim) -> Any: ...
    def heartbeat(self, claim: Claim, progress: Mapping[str, Any]) -> Any: ...
    def save_variant(self, claim: Claim, variant: Mapping[str, Any]) -> Any: ...
    def finalize(self, claim: Claim) -> Any: ...
    def interrupt(self, claim: Claim, reason: str) -> Any: ...
    def fail_attempt(self, claim: Claim, **kwargs: Any) -> Any: ...


@dataclass
class _StopState:
    event: threading.Event
    lock: threading.Lock
    reason: str | None = None

    def request(self, reason: str) -> None:
        with self.lock:
            if self.reason is None:
                self.reason = reason
        self.event.set()

    def get_reason(self) -> str | None:
        with self.lock:
            return self.reason

    def clear_transient(self) -> None:
        with self.lock:
            if self.reason in {
                "CANCEL_REQUESTED",
                "LEASE_LOST",
                "HEARTBEAT_FAILED",
            }:
                self.reason = None
                self.event.clear()


class WorkerRuntime:
    def __init__(
        self,
        config: WorkerConfig,
        *,
        rpc: RpcProtocol | None = None,
        engine: CpSatScheduleEngine | None = None,
    ):
        self.config = config
        self.rpc = rpc or SolverGatewayClient(
            config.solver_gateway_url,
            config.solver_gateway_token,
            timeout_seconds=config.rpc_timeout_seconds,
        )
        self.engine = engine or CpSatScheduleEngine(
            max_total_seconds=config.solver_max_seconds,
            finalization_reserve_seconds=config.solver_finalization_reserve_seconds,
        )
        self._stop = _StopState(threading.Event(), threading.Lock())
        self._progress: dict[str, Any] = {"schemaVersion": 2, "phase": "STARTING"}
        self._progress_lock = threading.Lock()
        self._heartbeat_done = threading.Event()
        self._heartbeat_thread: threading.Thread | None = None
        set_progress_callback = getattr(self.engine, "set_progress_callback", None)
        if callable(set_progress_callback):
            set_progress_callback(self._solver_progress)

    def _solver_progress(self, values: Mapping[str, Any]) -> None:
        self._set_progress(**values)

    def request_stop(self, reason: str) -> None:
        self._stop.request(reason)
        self.engine.stop()

    def _set_progress(self, **values: Any) -> None:
        with self._progress_lock:
            self._progress.update(values)

    def _progress_snapshot(self) -> dict[str, Any]:
        with self._progress_lock:
            return dict(self._progress)

    def _heartbeat_loop(self, claim: Claim) -> None:
        failures = 0
        while not self._heartbeat_done.wait(self.config.heartbeat_seconds):
            try:
                heartbeat = self.rpc.heartbeat(claim, self._progress_snapshot())
                failures = 0
                if heartbeat.cancel_requested:
                    self.request_stop("CANCEL_REQUESTED")
                    return
                if not heartbeat.lease_valid:
                    self.request_stop("LEASE_LOST")
                    return
            except RpcError as exc:
                failures += 1
                LOGGER.warning("Heartbeat RPC failed (attempt %s)", failures)
                if not exc.retryable or failures >= 3:
                    self.request_stop("HEARTBEAT_FAILED")
                    return
            except Exception:
                failures += 1
                LOGGER.exception("Unexpected heartbeat failure")
                if failures >= 3:
                    self.request_stop("HEARTBEAT_FAILED")
                    return

    def _start_heartbeat(self, claim: Claim) -> None:
        self._heartbeat_done.clear()
        self._heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop,
            args=(claim,),
            daemon=True,
            name="solver-heartbeat",
        )
        self._heartbeat_thread.start()

    def _stop_heartbeat(self) -> None:
        self._heartbeat_done.set()
        if self._heartbeat_thread is not None:
            self._heartbeat_thread.join(timeout=2.0)

    def _claim_run(self) -> Claim | None:
        return self.rpc.claim(
            worker_id=self.config.worker_id,
            worker_version=self.config.solver_version,
            task_attempt=self.config.task_attempt,
            lease_seconds=self.config.lease_seconds,
        )

    def _execute_claim(self, claim: Claim) -> int:
        self._progress = {"schemaVersion": 2, "phase": "STARTING"}
        try:
            LOGGER.info("Claimed optimizer run %s", claim.run_id)
            envelope = self.rpc.load_snapshot(claim)
            verify_snapshot_hash(envelope.snapshot, envelope.snapshot_hash)
            snapshot = Snapshot.from_dict(envelope.snapshot)
            if snapshot.run_id != claim.run_id:
                raise SnapshotError("Claimed run and snapshot run identifiers differ")

            self._set_progress(
                phase="SOLVING",
                progress=5,
                strategyCount=len(snapshot.strategies),
                completedStrategies=0,
            )
            self._start_heartbeat(claim)
            variants = self.engine.solve(snapshot)
            if self._stop.event.is_set():
                raise OptimizationCancelled(self._stop.get_reason() or "INTERRUPTED")

            self._set_progress(phase="VALIDATING", progress=91, completedStrategies=0)
            for index, variant in enumerate(variants, start=1):
                if self._stop.event.is_set():
                    raise OptimizationCancelled(
                        self._stop.get_reason() or "INTERRUPTED"
                    )
                report = validate_variant(snapshot, variant)
                report.raise_for_errors()
                self.rpc.save_variant(claim, variant.to_dict())
                self._set_progress(
                    phase="SAVING",
                    progress=91 + (7 * index // len(variants)),
                    completedStrategies=index,
                    assignmentCount=report.assignment_count,
                    unfilledCount=report.unfilled_count,
                )
            if self._stop.event.is_set():
                raise OptimizationCancelled(self._stop.get_reason() or "INTERRUPTED")
            self._set_progress(
                phase="FINALIZING",
                progress=99,
                completedStrategies=len(variants),
            )
            self.rpc.finalize(claim)
            LOGGER.info(
                "Optimizer run %s finalized with %s variants",
                claim.run_id,
                len(variants),
            )
            return 0
        except OptimizationCancelled:
            reason = self._stop.get_reason() or "INTERRUPTED"
            LOGGER.warning("Optimizer run interrupted: %s", reason)
            if reason != "LEASE_LOST":
                self._best_effort_interrupt(claim, reason)
            return 0 if reason == "CANCEL_REQUESTED" else 1
        except Exception as exc:  # noqa: BLE001 - process boundary persists every failure
            retryable, code = self._classify_failure(exc)
            LOGGER.error("Optimizer run failed (%s): %s", code, exc)
            self._best_effort_fail(claim, code, str(exc), retryable)
            return 1
        finally:
            self._stop_heartbeat()

    def run_once(self) -> int:
        try:
            claim = self._claim_run()
        except RpcError as exc:
            LOGGER.error("Could not claim optimizer work: %s", exc)
            return 1
        if claim is None:
            LOGGER.info("No queued optimizer run was available")
            return 0
        return self._execute_claim(claim)

    def run(self) -> int:
        processed_runs = 0
        last_result = 0
        idle_since = time.monotonic()

        while not self._stop.event.is_set():
            try:
                claim = self._claim_run()
            except RpcError as exc:
                LOGGER.error("Could not claim optimizer work: %s", exc)
                if not exc.retryable:
                    return 1
                last_result = 1
                if self._stop.event.wait(self.config.poll_interval_seconds):
                    break
                continue

            if claim is None:
                if (
                    self.config.idle_exit_seconds > 0
                    and time.monotonic() - idle_since
                    >= self.config.idle_exit_seconds
                ):
                    LOGGER.info("Idle exit threshold reached")
                    return last_result
                if self._stop.event.wait(self.config.poll_interval_seconds):
                    break
                continue

            idle_since = time.monotonic()
            last_result = max(last_result, self._execute_claim(claim))
            processed_runs += 1
            self._stop.clear_transient()
            if self.config.max_runs and processed_runs >= self.config.max_runs:
                return last_result

        return last_result

    def _best_effort_interrupt(self, claim: Claim, reason: str) -> None:
        try:
            self.rpc.interrupt(claim, reason)
        except Exception:
            LOGGER.exception("Could not persist optimizer interruption")

    def _best_effort_fail(
        self, claim: Claim, code: str, message: str, retryable: bool
    ) -> None:
        try:
            self.rpc.fail_attempt(
                claim,
                error_code=code,
                error_message=message,
                retryable=retryable,
            )
        except Exception:
            LOGGER.exception("Could not persist optimizer failure")

    @staticmethod
    def _classify_failure(exc: Exception) -> tuple[bool, str]:
        if isinstance(exc, RpcError):
            return exc.retryable, "RPC_ERROR"
        if isinstance(exc, OptimizationIncomplete):
            return True, "OPTIMIZATION_INCOMPLETE"
        if isinstance(exc, OptimizationError):
            return False, "OPTIMIZATION_ERROR"
        if isinstance(exc, VariantValidationError):
            return False, "INVALID_VARIANT"
        if isinstance(exc, (SnapshotError, ValueError)):
            return False, "INVALID_SNAPSHOT"
        return True, "WORKER_ERROR"


def install_signal_handlers(runtime: WorkerRuntime) -> None:
    def handle_signal(signum: int, _frame: Any) -> None:
        LOGGER.warning("Received signal %s", signum)
        runtime.request_stop("WORKER_TERMINATED")

    signal.signal(signal.SIGTERM, handle_signal)
    signal.signal(signal.SIGINT, handle_signal)
