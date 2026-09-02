from __future__ import annotations

import logging
import signal
import threading
import time
from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from typing import Any, Protocol

from .canonical import verify_snapshot_hash
from .config import WorkerConfig
from .cp_sat_engine import (
    CpSatScheduleEngine,
    OptimizationCancelled,
    OptimizationError,
    OptimizationIncomplete,
)
from .models import Snapshot, SnapshotError, VariantResult
from .rpc import Claim, RpcError, SolverGatewayClient
from .validator import VariantValidationError, validate_variant

LOGGER = logging.getLogger(__name__)

_MAX_RANDOM_SEED = 2_147_483_647
_FAIRNESS_RETRY_SEED_STEP = 104_729
_CANONICAL_STRATEGY_CODES = frozenset(
    {"BALANCED", "MIN_COST", "PREFERENCES"}
)


_HEARTBEAT_PROGRESS_KEYS = frozenset(
    {
        "phase",
        "progress",
        "strategyId",
        "strategyProgress",
        "strategyCount",
        "completedStrategies",
        "assignmentCount",
        "unfilledCount",
    }
)


class RpcProtocol(Protocol):
    def claim(self, **kwargs: Any) -> Claim | None: ...
    def load_snapshot(self, claim: Claim) -> Any: ...
    def heartbeat(self, claim: Claim, progress: Mapping[str, Any]) -> Any: ...
    def save_variant(self, claim: Claim, variant: Mapping[str, Any]) -> Any: ...
    def finalize(self, claim: Claim) -> Any: ...
    def interrupt(self, claim: Claim, reason: str) -> Any: ...
    def fail_attempt(self, claim: Claim, **kwargs: Any) -> Any: ...


def validate_run_strategy_contract(snapshot: Snapshot) -> None:
    """Reject incomplete current strategy contracts before any solver work.

    Legacy unversioned fixtures remain parseable for isolated engine tests. A
    snapshot emitted by the versioned database contract must contain the exact
    product set once each, so neither an older nor an alternative producer can
    silently reduce the variants persisted for a run.
    """

    if snapshot.settings.strategy_semantics_version is None:
        return
    codes = tuple(strategy.code.upper() for strategy in snapshot.strategies)
    if (
        len(codes) != len(_CANONICAL_STRATEGY_CODES)
        or set(codes) != _CANONICAL_STRATEGY_CODES
    ):
        raise SnapshotError(
            "STRATEGY_SET_MISMATCH: current snapshot contract requires "
            "BALANCED, MIN_COST and PREFERENCES exactly once"
        )


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
        clock: Callable[[], float] = time.monotonic,
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
        self._heartbeat_lock = threading.Lock()
        self._heartbeat_failures = 0
        self._last_heartbeat_monotonic = 0.0
        self._active_claim: Claim | None = None
        self._clock = clock
        set_progress_callback = getattr(self.engine, "set_progress_callback", None)
        if callable(set_progress_callback):
            set_progress_callback(self._solver_progress)

    def _solver_progress(self, values: Mapping[str, Any]) -> None:
        # The gateway intentionally validates an exact, small heartbeat schema.
        # Engine-only diagnostics belong in logs and result artifacts; forwarding
        # them would make an otherwise healthy lease fail with HTTP 400.
        heartbeat_values = {
            key: value
            for key, value in values.items()
            if key in _HEARTBEAT_PROGRESS_KEYS and value is not None
        }
        if heartbeat_values:
            self._set_progress(**heartbeat_values)
        # OR-Tools can hold the GIL long enough to starve the background
        # heartbeat thread. Every completed solver stage reaches this callback,
        # so use the boundary as a synchronous lease-renewal checkpoint when
        # the regular heartbeat interval has elapsed.
        claim = self._active_claim
        if claim is not None:
            self._heartbeat_once(claim)

    def request_stop(self, reason: str) -> None:
        self._stop.request(reason)
        self.engine.stop()

    def _set_progress(self, **values: Any) -> None:
        with self._progress_lock:
            self._progress.update(values)

    def _progress_snapshot(self) -> dict[str, Any]:
        with self._progress_lock:
            return dict(self._progress)

    def _heartbeat_once(self, claim: Claim, *, force: bool = False) -> bool:
        with self._heartbeat_lock:
            now = self._clock()
            if (
                not force
                and now - self._last_heartbeat_monotonic
                < self.config.heartbeat_seconds
            ):
                return True
            try:
                heartbeat = self.rpc.heartbeat(claim, self._progress_snapshot())
                self._heartbeat_failures = 0
                self._last_heartbeat_monotonic = self._clock()
                if heartbeat.cancel_requested:
                    self.request_stop("CANCEL_REQUESTED")
                    return False
                if not heartbeat.lease_valid:
                    self.request_stop("LEASE_LOST")
                    return False
                return True
            except RpcError as exc:
                self._heartbeat_failures += 1
                LOGGER.warning(
                    "Heartbeat RPC failed (attempt %s; status=%s; retryable=%s): %s",
                    self._heartbeat_failures,
                    exc.status,
                    exc.retryable,
                    exc,
                )
                if not exc.retryable or self._heartbeat_failures >= 3:
                    self.request_stop("HEARTBEAT_FAILED")
                    return False
                return True
            except Exception:
                self._heartbeat_failures += 1
                LOGGER.exception("Unexpected heartbeat failure")
                if self._heartbeat_failures >= 3:
                    self.request_stop("HEARTBEAT_FAILED")
                    return False
                return True

    def _heartbeat_loop(
        self, claim: Claim, heartbeat_done: threading.Event
    ) -> None:
        while not heartbeat_done.wait(self.config.heartbeat_seconds):
            if not self._heartbeat_once(claim):
                return

    def _start_heartbeat(self, claim: Claim) -> None:
        heartbeat_done = threading.Event()
        self._heartbeat_done = heartbeat_done
        with self._heartbeat_lock:
            self._heartbeat_failures = 0
            self._last_heartbeat_monotonic = self._clock()
            self._active_claim = claim
        self._heartbeat_thread = threading.Thread(
            target=self._heartbeat_loop,
            args=(claim, heartbeat_done),
            daemon=True,
            name="solver-heartbeat",
        )
        self._heartbeat_thread.start()

    def _stop_heartbeat(self) -> None:
        self._active_claim = None
        self._heartbeat_done.set()
        if self._heartbeat_thread is not None:
            self._heartbeat_thread.join(timeout=2.0)
        self._heartbeat_thread = None

    def _claim_run(self) -> Claim | None:
        return self.rpc.claim(
            worker_id=self.config.worker_id,
            worker_version=self.config.solver_version,
            task_attempt=self.config.task_attempt,
            lease_seconds=self.config.lease_seconds,
        )

    @staticmethod
    def _retry_seed(seed: int, attempt_index: int) -> int:
        return (seed + attempt_index * _FAIRNESS_RETRY_SEED_STEP) % _MAX_RANDOM_SEED

    @classmethod
    def _quality_attempt_snapshot(
        cls, snapshot: Snapshot, attempt_index: int
    ) -> Snapshot:
        if attempt_index == 0:
            return snapshot
        retry_seed = cls._retry_seed(snapshot.settings.random_seed, attempt_index)
        strategies = tuple(
            replace(
                strategy,
                random_seed=cls._retry_seed(
                    strategy.random_seed
                    if strategy.random_seed is not None
                    else snapshot.settings.random_seed,
                    attempt_index,
                ),
            )
            for strategy in snapshot.strategies
        )
        return replace(
            snapshot,
            settings=replace(snapshot.settings, random_seed=retry_seed),
            strategies=strategies,
        )

    @staticmethod
    def _preferences_quality(
        variants: tuple[VariantResult, ...],
    ) -> tuple[VariantResult, int, int, int]:
        preferences = next(
            (
                variant
                for variant in variants
                if variant.strategy_code.upper() == "PREFERENCES"
            ),
            None,
        )
        if preferences is None:
            raise SnapshotError(
                "FAIRNESS_QUALITY_TARGET requires the PREFERENCES strategy"
            )
        required_metrics = (
            "LOAD_UTILIZATION_TARGET_COUNT",
            "MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS",
            "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS",
        )
        missing = [
            metric for metric in required_metrics if metric not in preferences.metrics
        ]
        if missing:
            raise OptimizationError(
                "FAIRNESS_QUALITY_TARGET metrics missing: " + ",".join(missing)
            )
        return (
            preferences,
            int(preferences.metrics["LOAD_UTILIZATION_TARGET_COUNT"]),
            int(
                preferences.metrics[
                    "MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS"
                ]
            ),
            int(
                preferences.metrics[
                    "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
                ]
            ),
        )

    @staticmethod
    def _with_quality_audit(
        variants: tuple[VariantResult, ...],
        *,
        attempt_count: int,
        selected_attempt: int,
        selected_seed: int,
        minimum_bps: int,
        maximum_spread_bps: int,
        target_met: bool,
        not_applicable: bool,
        timeout_fallback_used: bool,
    ) -> tuple[VariantResult, ...]:
        audited: list[VariantResult] = []
        for variant in variants:
            if variant.strategy_code.upper() != "PREFERENCES":
                audited.append(variant)
                continue
            metrics = dict(variant.metrics)
            actual_minimum_bps = int(
                metrics["MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS"]
            )
            actual_spread_bps = int(
                metrics["ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"]
            )
            minimum_met = not_applicable or actual_minimum_bps >= minimum_bps
            spread_met = not_applicable or actual_spread_bps <= maximum_spread_bps
            stages_by_name = {
                str(stage.get("name", "")): stage
                for stage in variant.stage_objectives
            }
            minimum_stage = stages_by_name.get("COMMON_FAIRNESS_GUARD", {})
            spread_stage = stages_by_name.get(
                "ESTIMATED_ACHIEVABLE_TARGET_SPREAD_GUARD", {}
            )
            minimum_proven = (
                not minimum_met and minimum_stage.get("status") == "OPTIMAL"
            )
            spread_proven = (
                minimum_met
                and not spread_met
                and spread_stage.get("status") == "OPTIMAL"
            )
            proven_unattainable = minimum_proven or spread_proven
            metrics.update(
                {
                    "FAIRNESS_TARGET_MET": int(target_met),
                    "FAIRNESS_TARGET_MINIMUM_BPS": minimum_bps,
                    "FAIRNESS_TARGET_MAXIMUM_SPREAD_BPS": maximum_spread_bps,
                    "FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS": actual_minimum_bps,
                    "FAIRNESS_TARGET_ACTUAL_SPREAD_BPS": actual_spread_bps,
                    "FAIRNESS_TARGET_MINIMUM_MET": int(minimum_met),
                    "FAIRNESS_TARGET_SPREAD_MET": int(spread_met),
                    "FAIRNESS_TARGET_FAILURE_MINIMUM": int(not minimum_met),
                    "FAIRNESS_TARGET_FAILURE_SPREAD": int(not spread_met),
                    "FAIRNESS_TARGET_FAILURE_REASON_COUNT": int(not minimum_met)
                    + int(not spread_met),
                    "FAIRNESS_TARGET_ATTEMPT_COUNT": attempt_count,
                    "FAIRNESS_TARGET_SELECTED_ATTEMPT": selected_attempt,
                    "FAIRNESS_TARGET_SELECTED_SEED": selected_seed,
                    "FAIRNESS_TARGET_RETRY_USED": int(attempt_count > 1),
                    "FAIRNESS_TARGET_FALLBACK_USED": int(
                        not target_met and not not_applicable
                    ),
                    "FAIRNESS_TARGET_TIMEOUT_FALLBACK_USED": int(
                        timeout_fallback_used
                    ),
                    "FAIRNESS_TARGET_PROVEN_UNATTAINABLE": int(
                        proven_unattainable
                    ),
                    # Compatibility-only alias for already deployed v21
                    # consumers. It classifies quality; it never blocks READY.
                    "FAIRNESS_QUALITY_GATE_PASSED": int(target_met),
                }
            )
            target_stage = {
                "tier": 0,
                "name": "FAIRNESS_QUALITY_TARGET",
                "value": actual_spread_bps,
                "status": (
                    "NOT_APPLICABLE"
                    if not_applicable
                    else "TARGET_MET"
                    if target_met
                    else "TARGET_NOT_MET_PROVEN"
                    if proven_unattainable
                    else "TARGET_NOT_MET_TIME_LIMIT"
                    if timeout_fallback_used
                    else "TARGET_NOT_MET_BEST_FOUND"
                ),
                "tolerance": maximum_spread_bps,
                "frozenUpperBound": maximum_spread_bps,
                "timeBudgetSeconds": 0,
                "elapsedSeconds": 0,
                "usedFallback": not target_met and not not_applicable,
            }
            audited.append(
                replace(
                    variant,
                    metrics=metrics,
                    stage_objectives=variant.stage_objectives + (target_stage,),
                )
            )
        return tuple(audited)

    def _solve_with_quality_target(
        self, snapshot: Snapshot
    ) -> tuple[VariantResult, ...]:
        target = snapshot.settings.fairness_quality_target
        if target is None:
            return self.engine.solve(snapshot)

        best_valid: tuple[
            tuple[int, int, int],
            tuple[VariantResult, ...],
            int,
            int,
            int,
            int,
        ] | None = None
        attempts_started = 0
        timeout_fallback_used = False
        for attempt_index in range(target.max_attempts):
            attempt_snapshot = self._quality_attempt_snapshot(snapshot, attempt_index)
            attempt_number = attempt_index + 1
            attempts_started = attempt_number
            LOGGER.info(
                "Fairness target attempt %s/%s seed=%s",
                attempt_number,
                target.max_attempts,
                attempt_snapshot.settings.random_seed,
            )
            try:
                variants = self.engine.solve(attempt_snapshot)
            except OptimizationIncomplete:
                if best_valid is None:
                    raise
                timeout_fallback_used = True
                LOGGER.warning(
                    "Fairness target attempt %s/%s ended without a new complete "
                    "result; returning the already verified best incumbent",
                    attempt_number,
                    target.max_attempts,
                )
                break
            if self._stop.event.is_set():
                raise OptimizationCancelled(
                    self._stop.get_reason() or "INTERRUPTED"
                )
            expected_strategies = {
                strategy.code.upper() for strategy in attempt_snapshot.strategies
            }
            returned_strategies = {
                variant.strategy_code.upper() for variant in variants
            }
            if returned_strategies != expected_strategies:
                raise OptimizationError(
                    "FAIRNESS_TARGET_ATTEMPT_INCOMPLETE: expected "
                    f"{sorted(expected_strategies)}, returned "
                    f"{sorted(returned_strategies)}"
                )
            # Keep the complete engine result atomically. _execute_claim validates
            # every retained variant against the original immutable snapshot
            # before the first save, so a fallback can never bypass hard checks.
            _, target_count, minimum_bps, spread_bps = self._preferences_quality(
                variants
            )
            passed = target_count == 0 or (
                minimum_bps
                >= target.minimum_estimated_achievable_target_utilization_bps
                and spread_bps
                <= target.maximum_estimated_achievable_target_utilization_spread_bps
            )
            if passed:
                return self._with_quality_audit(
                    variants,
                    attempt_count=attempt_number,
                    selected_attempt=attempt_number,
                    selected_seed=attempt_snapshot.settings.random_seed,
                    minimum_bps=target.minimum_estimated_achievable_target_utilization_bps,
                    maximum_spread_bps=(
                        target.maximum_estimated_achievable_target_utilization_spread_bps
                    ),
                    target_met=True,
                    not_applicable=target_count == 0,
                    timeout_fallback_used=False,
                )
            candidate = (1_000 - minimum_bps, spread_bps, attempt_number)
            if best_valid is None or candidate < best_valid[0]:
                best_valid = (
                    candidate,
                    variants,
                    attempt_number,
                    attempt_snapshot.settings.random_seed,
                    target_count,
                    minimum_bps,
                )
            LOGGER.warning(
                "Fairness target attempt %s/%s missed the desired target: "
                "minimum=%s desired=%s spread=%s desiredMaximum=%s",
                attempt_number,
                target.max_attempts,
                minimum_bps,
                target.minimum_estimated_achievable_target_utilization_bps,
                spread_bps,
                target.maximum_estimated_achievable_target_utilization_spread_bps,
            )

        if best_valid is None:
            raise OptimizationIncomplete(
                "FAIRNESS_TARGET_NO_VALID_INCUMBENT: no verified legal variant "
                "was returned by the solver"
            )
        (
            (best_deficit, best_spread, _),
            best_variants,
            selected_attempt,
            selected_seed,
            best_target_count,
            _,
        ) = best_valid
        LOGGER.warning(
            "Fairness target not met after %s attempt(s); returning the best "
            "verified legal incumbent minimum=%.1f%% spread=%.1f p.p.",
            attempts_started,
            (1_000 - best_deficit) / 10,
            best_spread / 10,
        )
        return self._with_quality_audit(
            best_variants,
            attempt_count=attempts_started,
            selected_attempt=selected_attempt,
            selected_seed=selected_seed,
            minimum_bps=target.minimum_estimated_achievable_target_utilization_bps,
            maximum_spread_bps=(
                target.maximum_estimated_achievable_target_utilization_spread_bps
            ),
            target_met=False,
            not_applicable=best_target_count == 0,
            timeout_fallback_used=timeout_fallback_used,
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
            validate_run_strategy_contract(snapshot)

            self._set_progress(
                phase="SOLVING",
                progress=5,
                strategyCount=len(snapshot.strategies),
                completedStrategies=0,
            )
            self._start_heartbeat(claim)
            variants = self._solve_with_quality_target(snapshot)
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
            finalization = self.rpc.finalize(claim)
            if isinstance(finalization, Mapping):
                final_status = str(finalization.get("status", "READY")).upper()
                if final_status not in {"READY", "CANCELLED"}:
                    LOGGER.error(
                        "Optimizer run %s finalization was rejected: %s",
                        claim.run_id,
                        finalization,
                    )
                    return 1
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
            # The same immutable snapshot, solver image and time budget produce
            # the same proof failure. Retrying only burns the budget again;
            # infrastructure/RPC failures remain independently retryable.
            return False, "OPTIMIZATION_INCOMPLETE"
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
