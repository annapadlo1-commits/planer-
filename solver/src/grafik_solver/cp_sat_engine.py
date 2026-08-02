from __future__ import annotations

import logging
import threading
import time
from collections import defaultdict
from collections.abc import Callable, Iterable, Mapping
from dataclasses import dataclass, replace
from datetime import date, timedelta
from typing import Any
from zoneinfo import ZoneInfo

try:
    from ortools.sat.python import cp_model
except ImportError:  # pragma: no cover - exercised by container/runtime checks
    cp_model = None  # type: ignore[assignment]

from .canonical import sha256_hex
from .eligibility import EligibilityIndex, violates_rest
from .models import (
    Assignment,
    Employee,
    Snapshot,
    SnapshotError,
    Strategy,
    VariantResult,
)
from .pay_rules import (
    COST_SCALE,
    matching_monthly_rules,
    quote_assignment,
    quote_selected_assignments,
    validate_pay_rules,
)
from .slots import Slot, generate_slots


class SolverUnavailable(RuntimeError):
    pass


class OptimizationError(RuntimeError):
    pass


class OptimizationCancelled(OptimizationError):
    pass


class OptimizationIncomplete(OptimizationError):
    pass


LOGGER = logging.getLogger(__name__)


METRIC_ALIASES = {
    "COST": "TOTAL_COST",
    "TOTAL_COST_UNITS": "TOTAL_COST",
    "PREFERENCES": "PREFERENCE_VIOLATIONS",
    "HOME_LOCATION": "HOME_LOCATION_VIOLATIONS",
    "NOMINAL_DEVIATION": "NOMINAL_DEVIATION_MINUTES",
    "OVERTIME": "OVERTIME_MINUTES",
    "LOAD_SPREAD": "LOAD_SPREAD_MINUTES",
    "BASELINE_CHANGES_COUNT": "BASELINE_CHANGES",
    "UNFILLED_SEATS": "UNFILLED",
    "TOTAL_COST_MINOR": "TOTAL_COST",
    "WORKLOAD_VARIANCE": "LOAD_SPREAD_MINUTES",
    "WEEKEND_VARIANCE": "WEEKEND_SPREAD",
    "NON_HOME_LOCATION_COUNT": "HOME_LOCATION_VIOLATIONS",
}

# Technical resource ceilings, not business rules. Matrix remains fully
# dynamic inside these bounds; the limits protect PostgreSQL, the worker host and
# CP-SAT's signed 64-bit arithmetic from an accidental unbounded scenario.
MAX_SOLVER_SLOTS = 25_000
MAX_SOLVER_EMPLOYEES = 5_000
MAX_SOLVER_STRATEGIES = 32
MAX_SOLVER_DECISION_PAIRS = 2_000_000
SAFE_CP_SAT_INTEGER = 2**60


def _sum(expressions: Iterable[Any]) -> Any:
    return sum(expressions, 0)


def _days(start: date, end: date) -> list[date]:
    return [
        date.fromordinal(ordinal)
        for ordinal in range(start.toordinal(), end.toordinal() + 1)
    ]


@dataclass
class _Artifacts:
    model: Any
    x: dict[tuple[str, str], Any]
    unfilled: dict[str, Any]
    work: dict[tuple[str, str], Any]
    day_work: dict[tuple[str, date], Any]
    total_minutes: dict[str, Any]
    metrics: dict[str, Any]
    metric_bounds: dict[str, int]
    hint_variables: tuple[Any, ...]
    static_quotes: dict[tuple[str, str], Any]
    complete_coverage_hint: bool = False
    coverage_symmetry_constraints: int = 0


class CpSatScheduleEngine:
    def __init__(
        self,
        max_total_seconds: int = 300,
        finalization_reserve_seconds: int = 30,
        progress_callback: Callable[[Mapping[str, Any]], None] | None = None,
        result_callback: Callable[[VariantResult], None] | None = None,
        clock: Callable[[], float] = time.monotonic,
    ):
        if cp_model is None:
            raise SolverUnavailable(
                "OR-Tools is not installed; install solver/requirements.txt"
            )
        self.max_total_seconds = max(1, int(max_total_seconds))
        self.finalization_reserve_seconds = max(0, int(finalization_reserve_seconds))
        if self.finalization_reserve_seconds >= self.max_total_seconds:
            raise ValueError(
                "finalization_reserve_seconds must be lower than max_total_seconds"
            )
        self._cp_sat_budget_seconds = (
            self.max_total_seconds - self.finalization_reserve_seconds
        )
        self._clock = clock
        self._current_solver: Any | None = None
        self._solver_lock = threading.Lock()
        self._cancel_event = threading.Event()
        self._progress_callback = progress_callback
        self._result_callback = result_callback

    def set_progress_callback(
        self, callback: Callable[[Mapping[str, Any]], None] | None
    ) -> None:
        self._progress_callback = callback

    def _emit_progress(self, **values: Any) -> None:
        if self._progress_callback is not None:
            self._progress_callback(values)

    @staticmethod
    def _solver_measure(solver: Any, name: str) -> Any | None:
        value = getattr(solver, name, None)
        if value is None:
            return None
        try:
            return value() if callable(value) else value
        except RuntimeError:
            return None

    @classmethod
    def _solver_diagnostics(
        cls, solver: Any, status: Any, stage_name: str
    ) -> dict[str, Any]:
        status_name = solver.status_name(status)
        diagnostics: dict[str, Any] = {
            "stage": stage_name,
            "status": status_name,
        }
        measurements = {
            "wallTimeSeconds": "wall_time",
            "branches": "num_branches",
            "conflicts": "num_conflicts",
        }
        for output_name, solver_name in measurements.items():
            value = cls._solver_measure(solver, solver_name)
            if value is not None:
                diagnostics[output_name] = value
        if status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
            objective = cls._solver_measure(solver, "objective_value")
            best_bound = cls._solver_measure(solver, "best_objective_bound")
            if objective is not None:
                diagnostics["objectiveValue"] = objective
            if best_bound is not None:
                diagnostics["bestBound"] = best_bound
            if objective is not None and best_bound is not None:
                diagnostics["absoluteGap"] = max(
                    0.0, float(objective) - float(best_bound)
                )
        return diagnostics

    @staticmethod
    def _format_solver_diagnostics(diagnostics: Mapping[str, Any]) -> str:
        ordered_names = (
            "status",
            "objectiveValue",
            "bestBound",
            "absoluteGap",
            "wallTimeSeconds",
            "branches",
            "conflicts",
        )
        values: list[str] = []
        for name in ordered_names:
            value = diagnostics.get(name)
            if value is None:
                continue
            if isinstance(value, float):
                rendered = f"{value:.6g}"
            else:
                rendered = str(value)
            values.append(f"{name}={rendered}")
        return "; ".join(values)

    def stop(self) -> None:
        self._cancel_event.set()
        with self._solver_lock:
            solver = self._current_solver
        if solver is not None:
            solver.stop_search()

    def solve(self, snapshot: Snapshot) -> tuple[VariantResult, ...]:
        self._cancel_event.clear()
        global_deadline = self._clock() + self._cp_sat_budget_seconds
        self._validate_snapshot_references(snapshot)
        validate_pay_rules(snapshot)
        slots = generate_slots(snapshot)
        self._validate_capacity(snapshot, slots)
        eligibility = EligibilityIndex(snapshot)

        common = self._build_model(snapshot, slots, eligibility, coverage_only=True)
        LOGGER.info(
            "Coverage model slots=%s eligiblePairs=%s symmetryConstraints=%s",
            len(slots),
            len(common.x),
            common.coverage_symmetry_constraints,
        )
        self._emit_progress(
            slotCount=len(slots),
            eligibleDecisionPairs=len(common.x),
            coverageSymmetryConstraints=common.coverage_symmetry_constraints,
        )
        common.model.clear_objective()
        common.model.minimize(common.metrics["UNFILLED"])
        common_solver, common_status = self._solve_model(
            common.model,
            snapshot,
            strategy=None,
            stage_name="UNFILLED",
            time_limit_seconds=self._remaining_seconds(
                global_deadline, "GLOBAL:UNFILLED"
            ),
            fix_hints=common.complete_coverage_hint,
        )
        if common.complete_coverage_hint and common_status == cp_model.INFEASIBLE:
            common_solver, common_status = self._solve_model(
                common.model,
                snapshot,
                strategy=None,
                stage_name="UNFILLED_FALLBACK",
                time_limit_seconds=self._remaining_seconds(
                    global_deadline, "GLOBAL:UNFILLED_FALLBACK"
                ),
            )
        all_common_stages_optimal = self._require_optimal(
            common_solver, common_status, snapshot, "UNFILLED"
        )
        minimum_unfilled = int(common_solver.value(common.metrics["UNFILLED"]))
        self._ensure_deadline(global_deadline, "GLOBAL:UNFILLED")
        self._emit_progress(
            phase="SOLVING",
            progress=10,
            minimumUnfilled=minimum_unfilled,
            strategyCount=len(snapshot.strategies),
            completedStrategies=0,
        )

        results: list[VariantResult] = []
        solution_owners: dict[str, str] = {}
        ordered_strategies = sorted(
            snapshot.strategies, key=lambda item: (item.sort_order, item.id)
        )
        strategy_count = len(ordered_strategies)
        for strategy_index, strategy in enumerate(ordered_strategies):
            if self._cancel_event.is_set():
                raise OptimizationCancelled("Optimization was cancelled")
            self._ensure_deadline(global_deadline, "GLOBAL")
            artifacts = self._build_model(snapshot, slots, eligibility)
            self._ensure_deadline(global_deadline, "GLOBAL")
            strategy_started = self._clock()
            strategy_deadline = min(
                global_deadline,
                strategy_started
                + (strategy.time_limit_seconds or self._cp_sat_budget_seconds),
            )
            self._ensure_deadline(strategy_deadline, strategy.code)
            artifacts.model.add(artifacts.metrics["UNFILLED"] == minimum_unfilled)
            stage_results: list[dict[str, Any]] = [
                {
                    "tier": 0,
                    "name": "UNFILLED",
                    "value": minimum_unfilled,
                    "status": common_solver.status_name(common_status),
                    "tolerance": 0,
                    "frozenUpperBound": minimum_unfilled,
                }
            ]
            all_stages_optimal = all_common_stages_optimal
            incumbent: dict[int, int] | None = None
            final_solver: Any | None = None
            final_status: Any | None = None
            tiers: dict[int, list[Any]] = defaultdict(list)
            tier_tolerances: dict[int, int] = defaultdict(int)
            tier_upper_bounds: dict[int, int] = defaultdict(int)
            tier_terms: dict[int, list[dict[str, Any]]] = defaultdict(list)
            for term_index, term in enumerate(strategy.objective_terms):
                metric_name = METRIC_ALIASES.get(term.metric, term.metric)
                if metric_name not in artifacts.metrics:
                    raise SnapshotError(
                        f"Strategy {strategy.id} uses unsupported metric {term.metric}"
                    )
                if term.weight == 0:
                    continue
                metric_expression = artifacts.metrics[metric_name]
                expression_bound = artifacts.metric_bounds[metric_name]
                target = term.parameters.get("targetValue")
                if target is not None:
                    metric_bound = artifacts.metric_bounds[metric_name]
                    target_bound = max(int(target), abs(metric_bound - int(target)))
                    if target_bound > SAFE_CP_SAT_INTEGER:
                        raise SnapshotError(
                            f"Strategy {strategy.id} target exceeds the safe "
                            "CP-SAT integer range"
                        )
                    targeted = artifacts.model.new_int_var(
                        0,
                        target_bound,
                        f"objective_target|{strategy.id}|{term.tier}|"
                        f"{metric_name}|{term_index}",
                    )
                    artifacts.model.add_abs_equality(
                        targeted, metric_expression - int(target)
                    )
                    metric_expression = targeted
                    expression_bound = target_bound
                sign = 1 if term.direction == "MIN" else -1
                tier_upper_bounds[term.tier] += abs(term.weight) * expression_bound
                tier_tolerances[term.tier] += term.weight * term.tolerance
                if (
                    tier_upper_bounds[term.tier] + tier_tolerances[term.tier]
                    > SAFE_CP_SAT_INTEGER
                ):
                    raise SnapshotError(
                        f"Strategy {strategy.id} tier {term.tier} exceeds the "
                        "safe CP-SAT integer range"
                    )
                tiers[term.tier].append(sign * term.weight * metric_expression)
                tier_terms[term.tier].append(
                    {
                        "metric": metric_name,
                        "direction": term.direction,
                        "weight": term.weight,
                        "tolerance": term.tolerance,
                        "parameters": dict(term.parameters),
                    }
                )

            self._emit_progress(
                phase="SOLVING",
                progress=10 + (80 * strategy_index // strategy_count),
                strategyId=strategy.id,
                strategyProgress=1,
                strategyCount=strategy_count,
                completedStrategies=strategy_index,
            )

            if not tiers:
                final_solver, final_status = self._solve_model(
                    artifacts.model,
                    snapshot,
                    strategy=strategy,
                    stage_name="FEASIBILITY",
                    time_limit_seconds=self._remaining_seconds(
                        strategy_deadline, strategy.code
                    ),
                )
                all_stages_optimal &= self._require_optimal(
                    final_solver,
                    final_status,
                    snapshot,
                    f"{strategy.code}:FEASIBILITY",
                )
                self._ensure_deadline(strategy_deadline, strategy.code)
            else:
                ordered_tiers = sorted(tiers)
                for tier_index, tier in enumerate(ordered_tiers, start=1):
                    expression = _sum(tiers[tier])
                    artifacts.model.clear_hints()
                    if incumbent is not None:
                        for variable in artifacts.hint_variables:
                            if variable.index in incumbent:
                                artifacts.model.add_hint(
                                    variable, incumbent[variable.index]
                                )
                    artifacts.model.clear_objective()
                    artifacts.model.minimize(expression)
                    final_solver, final_status = self._solve_model(
                        artifacts.model,
                        snapshot,
                        strategy=strategy,
                        stage_name=f"TIER_{tier}",
                        time_limit_seconds=self._remaining_seconds(
                            strategy_deadline, strategy.code
                        ),
                    )
                    all_stages_optimal &= self._require_optimal(
                        final_solver,
                        final_status,
                        snapshot,
                        f"{strategy.code}:TIER_{tier}",
                    )
                    self._ensure_deadline(
                        strategy_deadline, f"{strategy.code}:TIER_{tier}"
                    )
                    exact_value = int(final_solver.value(expression))
                    allowed_degradation = tier_tolerances[tier]
                    incumbent = {
                        variable.index: int(final_solver.value(variable))
                        for variable in artifacts.hint_variables
                    }
                    stage_results.append(
                        {
                            "tier": tier,
                            "name": f"TIER_{tier}",
                            "value": exact_value,
                            "status": final_solver.status_name(final_status),
                            "bestBound": final_solver.best_objective_bound,
                            "tolerance": allowed_degradation,
                            "frozenUpperBound": exact_value + allowed_degradation,
                            "terms": tier_terms[tier],
                        }
                    )
                    artifacts.model.add(expression <= exact_value + allowed_degradation)
                    self._emit_progress(
                        phase=f"TIER_{tier}",
                        progress=10
                        + (
                            80
                            * (strategy_index * len(ordered_tiers) + tier_index)
                            // (strategy_count * len(ordered_tiers))
                        ),
                        strategyId=strategy.id,
                        strategyProgress=90 * tier_index // len(ordered_tiers),
                        strategyCount=strategy_count,
                        completedStrategies=strategy_index,
                    )

            assert final_solver is not None and final_status is not None
            result = self._extract_result(
                snapshot,
                slots,
                strategy,
                artifacts,
                final_solver,
                stage_results,
                optimal=all_stages_optimal,
            )
            self._ensure_deadline(strategy_deadline, strategy.code)
            owner = solution_owners.get(result.solution_hash)
            if owner is not None:
                result = replace(result, equivalent_to_strategy_id=owner)
            else:
                solution_owners[result.solution_hash] = strategy.id
            results.append(result)
            if self._result_callback is not None:
                self._result_callback(result)
            self._emit_progress(
                phase="SOLVING",
                progress=10 + (80 * (strategy_index + 1) // strategy_count),
                strategyId=strategy.id,
                strategyProgress=100,
                strategyCount=strategy_count,
                completedStrategies=strategy_index + 1,
            )
            self._ensure_deadline(global_deadline, "GLOBAL")
        return tuple(results)

    def _remaining_seconds(self, deadline: float, scope: str) -> float:
        remaining = deadline - self._clock()
        if remaining <= 0.001:
            raise OptimizationIncomplete(
                f"{scope} exhausted the shared CP-SAT time budget"
            )
        return remaining

    def _ensure_deadline(self, deadline: float, scope: str) -> None:
        if self._clock() > deadline:
            raise OptimizationIncomplete(
                f"{scope} exceeded the shared CP-SAT time budget"
            )

    def _new_solver(
        self,
        snapshot: Snapshot,
        strategy: Strategy | None,
        time_limit_seconds: float,
        *,
        fix_hints: bool = False,
    ) -> Any:
        solver = cp_model.CpSolver()
        solver.parameters.max_time_in_seconds = max(0.001, time_limit_seconds)
        solver.parameters.num_search_workers = 1
        solver.parameters.random_seed = (
            strategy.random_seed
            if strategy is not None and strategy.random_seed is not None
            else snapshot.settings.random_seed
        )
        solver.parameters.log_search_progress = False
        solver.parameters.fix_variables_to_their_hinted_value = fix_hints
        return solver

    def _solve_model(
        self,
        model: Any,
        snapshot: Snapshot,
        strategy: Strategy | None,
        stage_name: str,
        time_limit_seconds: float,
        fix_hints: bool = False,
    ) -> tuple[Any, Any]:
        if self._cancel_event.is_set():
            raise OptimizationCancelled("Optimization was cancelled")
        validation_error = model.validate()
        if validation_error:
            raise OptimizationError(
                f"Invalid CP-SAT model at {stage_name}: {validation_error}"
            )
        solver = self._new_solver(
            snapshot, strategy, time_limit_seconds, fix_hints=fix_hints
        )
        with self._solver_lock:
            self._current_solver = solver
        try:
            status = solver.solve(model)
        finally:
            with self._solver_lock:
                self._current_solver = None
        if self._cancel_event.is_set():
            raise OptimizationCancelled("Optimization was cancelled")
        diagnostics = self._solver_diagnostics(solver, status, stage_name)
        LOGGER.info(
            "CP-SAT stage %s finished: %s",
            stage_name,
            self._format_solver_diagnostics(diagnostics),
        )
        self._emit_progress(
            solverStage=stage_name,
            solverStatus=diagnostics["status"],
            solverObjectiveValue=diagnostics.get("objectiveValue"),
            solverBestBound=diagnostics.get("bestBound"),
            solverAbsoluteGap=diagnostics.get("absoluteGap"),
            solverWallTimeSeconds=diagnostics.get("wallTimeSeconds"),
            solverBranches=diagnostics.get("branches"),
            solverConflicts=diagnostics.get("conflicts"),
        )
        return solver, status

    @staticmethod
    def _require_optimal(
        solver: Any, status: Any, snapshot: Snapshot, stage_name: str
    ) -> bool:
        name = solver.status_name(status)
        if status == cp_model.OPTIMAL:
            return True
        if status == cp_model.FEASIBLE and not snapshot.settings.require_optimal:
            return False
        if status == cp_model.INFEASIBLE:
            raise OptimizationError(f"{stage_name} is infeasible")
        if status == cp_model.MODEL_INVALID:
            raise OptimizationError(
                f"{stage_name} model is invalid: {solver.solution_info()}"
            )
        diagnostics = CpSatScheduleEngine._solver_diagnostics(
            solver, status, stage_name
        )
        rendered = CpSatScheduleEngine._format_solver_diagnostics(diagnostics)
        raise OptimizationIncomplete(f"{stage_name} ended incomplete; {rendered}")

    @staticmethod
    def _validate_capacity(snapshot: Snapshot, slots: list[Slot]) -> None:
        if len(slots) > MAX_SOLVER_SLOTS:
            raise SnapshotError("Solver slot capacity exceeded")
        if len(snapshot.employees) > MAX_SOLVER_EMPLOYEES:
            raise SnapshotError("Solver employee capacity exceeded")
        if len(snapshot.strategies) > MAX_SOLVER_STRATEGIES:
            raise SnapshotError("Solver strategy capacity exceeded")
        if len(slots) * len(snapshot.employees) > MAX_SOLVER_DECISION_PAIRS:
            raise SnapshotError("Solver decision-variable capacity exceeded")

    @staticmethod
    def _validate_snapshot_references(snapshot: Snapshot) -> None:
        def unique(values: Iterable[str], label: str) -> set[str]:
            items = list(values)
            if len(items) != len(set(items)):
                raise SnapshotError(f"{label} identifiers must be unique")
            return set(items)

        role_ids = unique((item.id for item in snapshot.roles), "Role")
        duty_ids = unique((item.id for item in snapshot.duties), "Duty")
        location_ids = unique((item.id for item in snapshot.locations), "Location")
        employee_ids = unique((item.id for item in snapshot.employees), "Employee")
        template_ids = unique(
            (item.id for item in snapshot.shift_templates), "Shift template"
        )
        unique((item.id for item in snapshot.strategies), "Strategy")
        unique((item.id for item in snapshot.pay_rules), "Pay rule")
        unique((item.id for item in snapshot.budgets), "Budget")
        for template in snapshot.shift_templates:
            if template.location_id not in location_ids:
                raise SnapshotError(
                    f"Shift template {template.id} references missing location "
                    f"{template.location_id}"
                )
        for demand in snapshot.demand:
            if demand.shift_template_id not in template_ids:
                raise SnapshotError(
                    f"Demand {demand.id} references missing template "
                    f"{demand.shift_template_id}"
                )
            if demand.role_id not in role_ids:
                raise SnapshotError(
                    f"Demand {demand.id} references missing role {demand.role_id}"
                )
            missing_duties = set(demand.duty_ids) - duty_ids
            if missing_duties:
                raise SnapshotError(
                    f"Demand {demand.id} references missing duties "
                    f"{sorted(missing_duties)}"
                )
        for employee in snapshot.employees:
            if employee.role_grants is None:
                if set(employee.role_ids) - role_ids:
                    raise SnapshotError(
                        f"Employee {employee.id} references missing roles"
                    )
            else:
                grant_role_ids = [grant.role_id for grant in employee.role_grants]
                if set(grant_role_ids) - role_ids:
                    raise SnapshotError(
                        f"Employee {employee.id} role grants reference missing roles"
                    )
            if employee.duty_capabilities is None and set(employee.duty_ids) - duty_ids:
                raise SnapshotError(f"Employee {employee.id} references missing duties")
            if employee.location_grants is None:
                if set(employee.location_ids) - location_ids:
                    raise SnapshotError(
                        f"Employee {employee.id} references missing locations"
                    )
            else:
                grant_location_ids = [
                    grant.location_id for grant in employee.location_grants
                ]
                if set(grant_location_ids) - location_ids:
                    raise SnapshotError(
                        f"Employee {employee.id} location grants reference missing "
                        "locations"
                    )
            period_template_ids = (
                set(employee.preferred_shift_template_ids)
                | set(employee.avoided_shift_template_ids)
                | set(employee.blocked_shift_template_ids)
            )
            if period_template_ids - template_ids:
                raise SnapshotError(
                    f"Employee {employee.id} shift-period preferences reference "
                    "missing templates"
                )
            if (
                set(employee.preferred_shift_template_ids)
                & set(employee.blocked_shift_template_ids)
            ):
                raise SnapshotError(
                    f"Employee {employee.id} cannot prefer and block the same template"
                )
            if employee.duty_capabilities is not None:
                for capability in employee.duty_capabilities:
                    if capability.duty_id not in duty_ids:
                        raise SnapshotError(
                            f"Employee {employee.id} capability references missing "
                            f"duty {capability.duty_id}"
                        )
                    if (
                        capability.role_id is not None
                        and capability.role_id not in role_ids
                    ):
                        raise SnapshotError(
                            f"Employee {employee.id} capability references missing "
                            f"role {capability.role_id}"
                        )
                    if (
                        capability.location_id is not None
                        and capability.location_id not in location_ids
                    ):
                        raise SnapshotError(
                            f"Employee {employee.id} capability references missing "
                            f"location {capability.location_id}"
                        )
        for budget in snapshot.budgets:
            if (
                budget.location_id is not None
                and budget.location_id not in location_ids
            ):
                raise SnapshotError(
                    f"Budget {budget.id} references missing location "
                    f"{budget.location_id}"
                )
            if budget.role_id is not None and budget.role_id not in role_ids:
                raise SnapshotError(
                    f"Budget {budget.id} references missing role {budget.role_id}"
                )
            if budget.duty_id is not None and budget.duty_id not in duty_ids:
                raise SnapshotError(
                    f"Budget {budget.id} references missing duty {budget.duty_id}"
                )
        for item in (
            *snapshot.availability_windows,
            *snapshot.hard_blocks,
            *snapshot.external_assignments,
        ):
            if item.employee_id not in employee_ids:
                raise SnapshotError(
                    f"Constraint references missing employee {item.employee_id}"
                )
        for lock in snapshot.locked_assignments:
            if lock.employee_id not in employee_ids:
                raise SnapshotError(
                    f"Lock references missing employee {lock.employee_id}"
                )

    @staticmethod
    def _add_greedy_coverage_hint(
        model: Any,
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        eligibility: EligibilityIndex,
        x: Mapping[tuple[str, str], Any],
        unfilled: Mapping[str, Any],
    ) -> int:
        """Add a deterministic, hard-feasible warm start for the coverage proof."""
        employees = {employee.id: employee for employee in snapshot.employees}
        timezone = ZoneInfo(snapshot.settings.timezone)
        selected_by_employee: dict[str, list[Slot]] = defaultdict(list)
        selected_by_slot: dict[str, str] = {}
        used_occurrences: set[tuple[str, str]] = set()
        daily_count: dict[tuple[str, date], int] = defaultdict(int)
        monthly_minutes: dict[str, int] = defaultdict(int)
        weekly_minutes: dict[tuple[str, tuple[int, int]], int] = defaultdict(int)
        worked_days: dict[str, set[date]] = defaultdict(set)

        for external in snapshot.external_assignments:
            local_day = external.start.astimezone(timezone).date()
            duration = int(
                (external.end.timestamp() - external.start.timestamp()) // 60
            )
            key = (local_day.isocalendar().year, local_day.isocalendar().week)
            daily_count[(external.employee_id, local_day)] += 1
            weekly_minutes[(external.employee_id, key)] += duration
            worked_days[external.employee_id].add(local_day)
            if snapshot.period_start <= local_day <= snapshot.period_end:
                monthly_minutes[external.employee_id] += duration

        def week_key(slot: Slot) -> tuple[int, int]:
            calendar = slot.date.isocalendar()
            return calendar.year, calendar.week

        def longest_run(days: set[date]) -> int:
            longest = 0
            current = 0
            previous: date | None = None
            for day in sorted(days):
                if previous is not None and day == previous + timedelta(days=1):
                    current += 1
                else:
                    current = 1
                longest = max(longest, current)
                previous = day
            return longest

        def can_add(employee: Employee, slot: Slot) -> bool:
            if (employee.id, slot.occurrence_id) in used_occurrences:
                return False
            if daily_count[(employee.id, slot.date)] >= employee.maximum_shifts_per_day:
                return False
            if (
                employee.maximum_monthly_minutes is not None
                and monthly_minutes[employee.id] + slot.duration_minutes
                > employee.maximum_monthly_minutes
            ):
                return False
            week = week_key(slot)
            if (
                employee.maximum_weekly_minutes is not None
                and weekly_minutes[(employee.id, week)] + slot.duration_minutes
                > employee.maximum_weekly_minutes
            ):
                return False
            if any(
                violates_rest(
                    previous.start,
                    previous.end,
                    slot.start,
                    slot.end,
                    eligibility.minimum_rest(employee),
                )
                for previous in selected_by_employee[employee.id]
            ):
                return False
            if employee.maximum_consecutive_days is not None:
                days = worked_days[employee.id] | {slot.date}
                if longest_run(days) > employee.maximum_consecutive_days:
                    return False
            return True

        def select(employee: Employee, slot: Slot) -> None:
            selected_by_slot[slot.id] = employee.id
            selected_by_employee[employee.id].append(slot)
            used_occurrences.add((employee.id, slot.occurrence_id))
            daily_count[(employee.id, slot.date)] += 1
            monthly_minutes[employee.id] += slot.duration_minutes
            weekly_minutes[(employee.id, week_key(slot))] += slot.duration_minutes
            worked_days[employee.id].add(slot.date)

        slots_by_id = {slot.id: slot for slot in slots}
        for lock in sorted(snapshot.locked_assignments, key=lambda item: item.slot_id):
            slot = slots_by_id.get(lock.slot_id)
            employee = employees.get(lock.employee_id)
            if slot is None:
                raise SnapshotError(f"Lock references missing slot {lock.slot_id}")
            if employee is None:
                raise SnapshotError(
                    f"Lock references missing employee {lock.employee_id}"
                )
            if (employee.id, slot.id) not in x:
                raise SnapshotError(
                    f"Locked assignment {employee.id}/{slot.id} is not eligible"
                )
            if not can_add(employee, slot):
                return 0
            select(employee, slot)

        candidate_ids = {
            slot.id: sorted(
                employee.id
                for employee in snapshot.employees
                if (employee.id, slot.id) in x
            )
            for slot in slots
        }
        ordered_slots = sorted(
            slots,
            key=lambda slot: (
                len(candidate_ids[slot.id]),
                slot.start,
                slot.location_id,
                slot.id,
            ),
        )
        for slot in ordered_slots:
            if slot.id in selected_by_slot:
                continue
            candidates = [
                employees[employee_id]
                for employee_id in candidate_ids[slot.id]
                if can_add(employees[employee_id], slot)
            ]
            if not candidates:
                continue
            selected = min(
                candidates,
                key=lambda employee: (
                    longest_run(worked_days[employee.id] | {slot.date}),
                    monthly_minutes[employee.id],
                    weekly_minutes[(employee.id, week_key(slot))],
                    employee.id,
                ),
            )
            select(selected, slot)

        for key, variable in x.items():
            model.add_hint(variable, int(selected_by_slot.get(key[1]) == key[0]))
        for slot_id, variable in unfilled.items():
            model.add_hint(variable, int(slot_id not in selected_by_slot))
        return len(selected_by_slot)

    @staticmethod
    def _add_coverage_symmetry_breaking(
        model: Any,
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        x: Mapping[tuple[str, str], Any],
        unfilled: Mapping[str, Any],
    ) -> int:
        """Canonicalize interchangeable seats in the coverage-only proof.

        Seat identifiers are materialization keys, but seats generated from the
        same demand occurrence have identical business constraints.  Ordering
        their selected employee ranks removes factorially many equivalent
        coverage solutions.  A group containing a locked seat is deliberately
        left untouched because the lock makes that seat identity meaningful.
        """
        locked_slot_ids = {item.slot_id for item in snapshot.locked_assignments}
        employee_ranks = {
            employee.id: rank
            for rank, employee in enumerate(
                sorted(snapshot.employees, key=lambda item: item.id), start=1
            )
        }
        unfilled_rank = len(employee_ranks) + 1
        grouped: dict[tuple[str, str], list[Slot]] = defaultdict(list)
        for slot in slots:
            grouped[(slot.demand_id, slot.occurrence_id)].append(slot)

        added = 0
        for group_slots in grouped.values():
            ordered = sorted(group_slots, key=lambda item: (item.seat_index, item.id))
            if len(ordered) < 2 or any(
                slot.id in locked_slot_ids for slot in ordered
            ):
                continue
            for left, right in zip(ordered, ordered[1:]):
                left_rank = _sum(
                    rank * variable
                    for employee_id, rank in employee_ranks.items()
                    if (variable := x.get((employee_id, left.id))) is not None
                ) + unfilled_rank * unfilled[left.id]
                right_rank = _sum(
                    rank * variable
                    for employee_id, rank in employee_ranks.items()
                    if (variable := x.get((employee_id, right.id))) is not None
                ) + unfilled_rank * unfilled[right.id]
                model.add(left_rank <= right_rank)
                added += 1
        return added

    def _build_model(
        self,
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        eligibility: EligibilityIndex,
        *,
        coverage_only: bool = False,
    ) -> _Artifacts:
        model = cp_model.CpModel()
        slots_by_id = {slot.id: slot for slot in slots}
        occurrences: dict[str, Slot] = {}
        slots_by_occurrence: dict[str, list[Slot]] = defaultdict(list)
        for slot in slots:
            representative = occurrences.setdefault(slot.occurrence_id, slot)
            if representative.start != slot.start or representative.end != slot.end:
                raise SnapshotError(
                    f"Occurrence {slot.occurrence_id} has inconsistent times"
                )
            slots_by_occurrence[slot.occurrence_id].append(slot)

        x: dict[tuple[str, str], Any] = {}
        static_quotes: dict[tuple[str, str], Any] = {}
        for employee in snapshot.employees:
            for slot in slots:
                if eligibility.evaluate(employee, slot).allowed:
                    key = (employee.id, slot.id)
                    x[key] = model.new_bool_var(f"x|{employee.id}|{slot.id}")
                    static_quotes[key] = quote_assignment(snapshot, employee, slot)

        unfilled = {slot.id: model.new_bool_var(f"u|{slot.id}") for slot in slots}
        for slot in slots:
            candidates = [
                x[(employee.id, slot.id)]
                for employee in snapshot.employees
                if (employee.id, slot.id) in x
            ]
            model.add(_sum(candidates) + unfilled[slot.id] == 1)

        work: dict[tuple[str, str], Any] = {}
        for employee in snapshot.employees:
            for occurrence_id, occurrence_slots in slots_by_occurrence.items():
                assignment_vars = [
                    x[(employee.id, slot.id)]
                    for slot in occurrence_slots
                    if (employee.id, slot.id) in x
                ]
                if not assignment_vars:
                    continue
                variable = model.new_bool_var(f"work|{employee.id}|{occurrence_id}")
                model.add(_sum(assignment_vars) == variable)
                work[(employee.id, occurrence_id)] = variable

        for lock in snapshot.locked_assignments:
            if lock.slot_id not in slots_by_id:
                raise SnapshotError(f"Lock references missing slot {lock.slot_id}")
            variable = x.get((lock.employee_id, lock.slot_id))
            if variable is None:
                raise SnapshotError(
                    f"Locked assignment {lock.employee_id}/{lock.slot_id} "
                    "is not eligible"
                )
            model.add(variable == 1)

        coverage_symmetry_constraints = 0
        if coverage_only:
            coverage_symmetry_constraints = self._add_coverage_symmetry_breaking(
                model, snapshot, slots, x, unfilled
            )

        timezone = ZoneInfo(snapshot.settings.timezone)
        external_by_employee: dict[str, list[Any]] = defaultdict(list)
        for assignment in snapshot.external_assignments:
            external_by_employee[assignment.employee_id].append(assignment)

        occurrence_items = sorted(occurrences.items(), key=lambda item: item[1].start)
        for employee in snapshot.employees:
            rest_minutes = eligibility.minimum_rest(employee)
            candidate_occurrences = [
                (occurrence_id, slot)
                for occurrence_id, slot in occurrence_items
                if (employee.id, occurrence_id) in work
            ]
            for index, (first_id, first) in enumerate(candidate_occurrences):
                for second_id, second in candidate_occurrences[index + 1 :]:
                    if violates_rest(
                        first.start,
                        first.end,
                        second.start,
                        second.end,
                        rest_minutes,
                    ):
                        model.add(
                            work[(employee.id, first_id)]
                            + work[(employee.id, second_id)]
                            <= 1
                        )

        all_days = _days(snapshot.period_start, snapshot.period_end)
        day_work_day_set = set(all_days)
        day_work: dict[tuple[str, date], Any] = {}
        total_minutes: dict[str, Any] = {}
        max_total_bound = sum(
            slot.duration_minutes for slot in occurrences.values()
        ) + sum(
            int((item.end.timestamp() - item.start.timestamp()) // 60)
            for item in snapshot.external_assignments
        )

        for employee in snapshot.employees:
            external = external_by_employee.get(employee.id, [])
            external_daily_count: dict[date, int] = defaultdict(int)
            external_daily_minutes: dict[date, int] = defaultdict(int)
            for item in external:
                local_day = item.start.astimezone(timezone).date()
                duration = int((item.end.timestamp() - item.start.timestamp()) // 60)
                external_daily_count[local_day] += 1
                external_daily_minutes[local_day] += duration

            for day in all_days:
                day_occurrences = [
                    work[(employee.id, occurrence_id)]
                    for occurrence_id, slot in occurrence_items
                    if slot.date == day and (employee.id, occurrence_id) in work
                ]
                fixed_count = external_daily_count.get(day, 0)
                model.add(
                    _sum(day_occurrences) + fixed_count
                    <= employee.maximum_shifts_per_day
                )
                variable = model.new_bool_var(f"day|{employee.id}|{day.isoformat()}")
                day_work[(employee.id, day)] = variable
                if fixed_count:
                    model.add(variable == 1)
                elif day_occurrences:
                    model.add(_sum(day_occurrences) >= variable)
                    model.add(_sum(day_occurrences) <= len(day_occurrences) * variable)
                else:
                    model.add(variable == 0)

            if employee.maximum_consecutive_days is not None:
                window_size = employee.maximum_consecutive_days + 1
                extended_days = _days(
                    snapshot.period_start
                    - timedelta(days=employee.maximum_consecutive_days),
                    snapshot.period_end
                    + timedelta(days=employee.maximum_consecutive_days),
                )
                for index in range(len(extended_days) - window_size + 1):
                    window = extended_days[index : index + window_size]
                    if not any(day in day_work_day_set for day in window):
                        continue
                    terms = [
                        day_work[(employee.id, day)]
                        if day in day_work_day_set
                        else int(external_daily_count.get(day, 0) > 0)
                        for day in window
                    ]
                    model.add(_sum(terms) <= employee.maximum_consecutive_days)

            external_month_total = sum(
                minutes
                for day, minutes in external_daily_minutes.items()
                if snapshot.period_start <= day <= snapshot.period_end
            )
            assigned_expression = _sum(
                variable * occurrences[occurrence_id].duration_minutes
                for (employee_id, occurrence_id), variable in work.items()
                if employee_id == employee.id
            )
            total = model.new_int_var(0, max_total_bound, f"minutes|{employee.id}")
            model.add(total == assigned_expression + external_month_total)
            total_minutes[employee.id] = total
            if employee.maximum_monthly_minutes is not None:
                model.add(total <= employee.maximum_monthly_minutes)

            weeks: set[tuple[int, int]] = {
                (day.isocalendar().year, day.isocalendar().week) for day in all_days
            }
            if employee.maximum_weekly_minutes is not None:
                for week_key in weeks:
                    assigned_week = _sum(
                        variable * occurrences[occurrence_id].duration_minutes
                        for (employee_id, occurrence_id), variable in work.items()
                        if employee_id == employee.id
                        and (
                            occurrences[occurrence_id].date.isocalendar().year,
                            occurrences[occurrence_id].date.isocalendar().week,
                        )
                        == week_key
                    )
                    external_week = sum(
                        duration
                        for day, duration in external_daily_minutes.items()
                        if (day.isocalendar().year, day.isocalendar().week) == week_key
                    )
                    model.add(
                        assigned_week + external_week <= employee.maximum_weekly_minutes
                    )

        monthly_rules_by_key = {
            (employee.id, slot.id): matching_monthly_rules(snapshot, employee, slot)
            for employee in snapshot.employees
            for slot in slots
            if (employee.id, slot.id) in x
        }

        # Prove obviously loose budgets redundant before adding cost variables.
        # The bound deliberately ignores every staffing/rest limit, uses the
        # most expensive eligible employee independently for every slot, and
        # charges every dynamic rule for the full shift duration.  It can only
        # overestimate real spend.
        assignment_cost_upper = {
            key: static_quotes[key].cost_units
            + sum(
                int(
                    rule.values.get(
                        "rateMinorPerHour",
                        rule.values.get("rate_minor_per_hour"),
                    )
                )
                * slots_by_id[key[1]].duration_minutes
                for rule in monthly_rules_by_key[key]
            )
            for key in x
        }
        eligible_upper_by_slot = {
            slot.id: max(
                (
                    assignment_cost_upper[(employee.id, slot.id)]
                    for employee in snapshot.employees
                    if (employee.id, slot.id) in x
                ),
                default=0,
            )
            for slot in slots
        }
        total_cost_upper = sum(eligible_upper_by_slot.values())
        if (
            any(value > SAFE_CP_SAT_INTEGER for value in assignment_cost_upper.values())
            or total_cost_upper > SAFE_CP_SAT_INTEGER
            or any(
                budget.amount_minor * COST_SCALE > SAFE_CP_SAT_INTEGER
                for budget in snapshot.budgets
            )
        ):
            raise SnapshotError("Cost model exceeds the safe CP-SAT integer range")
        binding_budgets = [
            budget
            for budget in snapshot.budgets
            if budget.hard
            and sum(
                eligible_upper_by_slot[slot.id]
                for slot in slots
                if budget.matches(slot)
            )
            > budget.amount_minor * COST_SCALE
        ]
        if coverage_only and not binding_budgets:
            hinted_assignments = self._add_greedy_coverage_hint(
                model, snapshot, slots, eligibility, x, unfilled
            )
            return _Artifacts(
                model=model,
                x=x,
                unfilled=unfilled,
                work=work,
                day_work=day_work,
                total_minutes=total_minutes,
                metrics={"UNFILLED": _sum(unfilled.values())},
                metric_bounds={"UNFILLED": len(slots)},
                hint_variables=tuple(
                    list(x.values())
                    + list(unfilled.values())
                    + list(work.values())
                    + list(day_work.values())
                ),
                static_quotes=static_quotes,
                complete_coverage_hint=hinted_assignments == len(slots),
                coverage_symmetry_constraints=coverage_symmetry_constraints,
            )

        static_cost_expression = _sum(
            variable * static_quotes[key].cost_units for key, variable in x.items()
        )
        monthly_groups: list[tuple[str, Any, list[Slot], int, int]] = []
        dynamic_total_terms: list[Any] = []
        for employee in snapshot.employees:
            rules = {
                rule.id: rule
                for slot in slots
                if (employee.id, slot.id) in x
                for rule in monthly_rules_by_key[(employee.id, slot.id)]
            }
            for rule_id, rule in sorted(rules.items()):
                matching_slots = sorted(
                    (
                        slot
                        for slot in slots
                        if (employee.id, slot.id) in x
                        and rule in monthly_rules_by_key[(employee.id, slot.id)]
                    ),
                    key=lambda slot: (slot.start, slot.id),
                )
                threshold_raw = rule.values.get(
                    "thresholdMinutes", rule.values.get("threshold_minutes")
                )
                rate_raw = rule.values.get(
                    "rateMinorPerHour", rule.values.get("rate_minor_per_hour")
                )
                threshold = int(threshold_raw)
                rate = int(rate_raw)
                bound = sum(slot.duration_minutes for slot in matching_slots)
                selected_minutes = _sum(
                    x[(employee.id, slot.id)] * slot.duration_minutes
                    for slot in matching_slots
                )
                total_excess = model.new_int_var(
                    0,
                    max(bound - threshold, 0),
                    f"monthly_total_excess|{rule_id}|{employee.id}",
                )
                model.add_max_equality(total_excess, [selected_minutes - threshold, 0])
                dynamic_total_terms.append(total_excess * rate)
                monthly_groups.append(
                    (employee.id, rule, matching_slots, threshold, rate)
                )

        total_cost_expression = static_cost_expression + _sum(dynamic_total_terms)

        for budget in snapshot.budgets:
            if budget.hard and not budget.scope():
                model.add(total_cost_expression <= budget.amount_minor * COST_SCALE)

        scoped_budgets = [budget for budget in binding_budgets if budget.scope()]
        dynamic_cost_by_assignment: dict[tuple[str, str], list[Any]] = defaultdict(list)
        if scoped_budgets:
            # A scoped monthly threshold must know precisely which assignment
            # consumed each marginal minute.  The prefix order is identical to
            # quote_selected_assignments(): employee, start, then slot id.
            for employee_id, rule, matching_slots, threshold, rate in monthly_groups:
                if not any(
                    budget.matches(slot)
                    for budget in scoped_budgets
                    for slot in matching_slots
                ):
                    continue
                cumulative_bound = 0
                previous_cumulative: Any = 0
                previous_excess: Any = 0
                for slot in matching_slots:
                    key = (employee_id, slot.id)
                    cumulative_bound += slot.duration_minutes
                    cumulative = model.new_int_var(
                        0,
                        cumulative_bound,
                        f"monthly_minutes|{rule.id}|{employee_id}|{slot.id}",
                    )
                    model.add(
                        cumulative
                        == previous_cumulative + x[key] * slot.duration_minutes
                    )
                    excess = model.new_int_var(
                        0,
                        max(cumulative_bound - threshold, 0),
                        f"monthly_excess|{rule.id}|{employee_id}|{slot.id}",
                    )
                    model.add_max_equality(excess, [cumulative - threshold, 0])
                    dynamic_cost_by_assignment[key].append(
                        (excess - previous_excess) * rate
                    )
                    previous_cumulative = cumulative
                    previous_excess = excess

        for budget in scoped_budgets:
            scoped_cost = _sum(
                x[key] * static_quotes[key].cost_units
                + _sum(dynamic_cost_by_assignment[key])
                for key in x
                if budget.matches(slots_by_id[key[1]])
            )
            model.add(scoped_cost <= budget.amount_minor * COST_SCALE)

        if coverage_only:
            return _Artifacts(
                model=model,
                x=x,
                unfilled=unfilled,
                work=work,
                day_work=day_work,
                total_minutes=total_minutes,
                metrics={"UNFILLED": _sum(unfilled.values())},
                metric_bounds={"UNFILLED": len(slots)},
                hint_variables=tuple(
                    list(x.values())
                    + list(unfilled.values())
                    + list(work.values())
                    + list(day_work.values())
                ),
                static_quotes=static_quotes,
                coverage_symmetry_constraints=coverage_symmetry_constraints,
            )

        preference_expression = _sum(
            variable
            * (
                int(
                    bool(employee.preferred_shift_template_ids)
                    and slot.shift_template_id
                    not in employee.preferred_shift_template_ids
                )
                + int(slot.shift_template_id in employee.avoided_shift_template_ids)
                + int(
                    bool(employee.preferred_location_ids)
                    and slot.location_id not in employee.preferred_location_ids
                )
                + int(slot.date in employee.soft_day_off_dates)
            )
            for employee in snapshot.employees
            for slot in slots
            if (variable := x.get((employee.id, slot.id))) is not None
        )
        # All standard-allowed locations consume the same ordinary contract
        # limit. The former "home location" marker is no longer an objective.
        home_expression = 0

        deviation_vars: list[Any] = []
        overtime_vars: list[Any] = []
        weekend_vars: list[Any] = []
        deviation_bound_total = 0
        overtime_bound_total = 0
        for employee in snapshot.employees:
            total = total_minutes[employee.id]
            if employee.nominal_monthly_minutes is not None:
                nominal = employee.nominal_monthly_minutes
                deviation = model.new_int_var(
                    0, max_total_bound + nominal, f"deviation|{employee.id}"
                )
                model.add_abs_equality(deviation, total - nominal)
                deviation_vars.append(deviation)
                deviation_bound_total += max_total_bound + nominal
                overtime = model.new_int_var(
                    0, max_total_bound, f"overtime|{employee.id}"
                )
                model.add_max_equality(overtime, [total - nominal, 0])
                overtime_vars.append(overtime)
                overtime_bound_total += max_total_bound
            external_weekends = sum(
                1
                for item in external_by_employee.get(employee.id, [])
                if snapshot.period_start
                <= item.start.astimezone(timezone).date()
                <= snapshot.period_end
                and item.start.astimezone(timezone).date().isoweekday() in {6, 7}
            )
            weekend = model.new_int_var(
                0, len(occurrences) + external_weekends, f"weekends|{employee.id}"
            )
            model.add(
                weekend
                == _sum(
                    variable
                    for (employee_id, occurrence_id), variable in work.items()
                    if employee_id == employee.id
                    and occurrences[occurrence_id].date.isoweekday() in {6, 7}
                )
                + external_weekends
            )
            weekend_vars.append(weekend)

        if total_minutes:
            max_load = model.new_int_var(0, max_total_bound, "max_load")
            min_load = model.new_int_var(0, max_total_bound, "min_load")
            model.add_max_equality(max_load, list(total_minutes.values()))
            model.add_min_equality(min_load, list(total_minutes.values()))
            load_spread: Any = max_load - min_load
            weekend_bound = len(occurrences) + max(
                (
                    sum(
                        1
                        for item in external_by_employee.get(employee.id, [])
                        if snapshot.period_start
                        <= item.start.astimezone(timezone).date()
                        <= snapshot.period_end
                        and item.start.astimezone(timezone).date().isoweekday()
                        in {6, 7}
                    )
                    for employee in snapshot.employees
                ),
                default=0,
            )
            max_weekend = model.new_int_var(0, weekend_bound, "max_weekend")
            min_weekend = model.new_int_var(0, weekend_bound, "min_weekend")
            model.add_max_equality(max_weekend, weekend_vars)
            model.add_min_equality(min_weekend, weekend_vars)
            weekend_spread: Any = max_weekend - min_weekend
        else:
            load_spread = 0
            weekend_spread = 0
            weekend_bound = 0

        baseline = {
            item.slot_id: item.employee_id for item in snapshot.baseline_assignments
        }
        if len(baseline) != len(snapshot.baseline_assignments):
            raise SnapshotError("Baseline assignment slot identifiers must be unique")
        baseline_terms: list[Any] = []
        for slot_id, employee_id in baseline.items():
            if slot_id not in slots_by_id:
                raise SnapshotError(f"Baseline references missing slot {slot_id}")
            if employee_id is None:
                baseline_terms.append(1 - unfilled[slot_id])
            else:
                variable = x.get((employee_id, slot_id))
                baseline_terms.append(1 if variable is None else 1 - variable)

        metrics = {
            "UNFILLED": _sum(unfilled.values()),
            "TOTAL_COST": total_cost_expression,
            "PREFERENCE_VIOLATIONS": preference_expression,
            "HOME_LOCATION_VIOLATIONS": home_expression,
            "NOMINAL_DEVIATION_MINUTES": _sum(deviation_vars),
            "OVERTIME_MINUTES": _sum(overtime_vars),
            "LOAD_SPREAD_MINUTES": load_spread,
            "WEEKEND_SPREAD": weekend_spread,
            "BASELINE_CHANGES": _sum(baseline_terms),
        }
        metric_bounds = {
            "UNFILLED": len(slots),
            "TOTAL_COST": total_cost_upper,
            "PREFERENCE_VIOLATIONS": 4 * len(slots),
            "HOME_LOCATION_VIOLATIONS": 0,
            "NOMINAL_DEVIATION_MINUTES": deviation_bound_total,
            "OVERTIME_MINUTES": overtime_bound_total,
            "LOAD_SPREAD_MINUTES": max_total_bound,
            "WEEKEND_SPREAD": weekend_bound,
            "BASELINE_CHANGES": len(baseline_terms),
        }
        hint_variables = tuple(
            list(x.values())
            + list(unfilled.values())
            + list(work.values())
            + list(day_work.values())
        )
        return _Artifacts(
            model=model,
            x=x,
            unfilled=unfilled,
            work=work,
            day_work=day_work,
            total_minutes=total_minutes,
            metrics=metrics,
            metric_bounds=metric_bounds,
            hint_variables=hint_variables,
            static_quotes=static_quotes,
        )

    @staticmethod
    def _extract_result(
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        strategy: Strategy,
        artifacts: _Artifacts,
        solver: Any,
        stage_results: list[dict[str, Any]],
        *,
        optimal: bool,
    ) -> VariantResult:
        employees = {employee.id: employee for employee in snapshot.employees}
        assignments: list[Assignment] = []
        selected_map: dict[str, str | None] = {}
        selected_items: list[tuple[Employee, Slot]] = []
        for slot in slots:
            selected_employee: str | None = None
            for employee_id, employee in employees.items():
                variable = artifacts.x.get((employee_id, slot.id))
                if variable is not None and solver.value(variable):
                    selected_employee = employee_id
                    selected_items.append((employee, slot))
                    break
            selected_map[slot.id] = selected_employee
        complete_quotes = quote_selected_assignments(snapshot, selected_items)
        for employee, slot in selected_items:
            quote = complete_quotes[(employee.id, slot.id)]
            assignments.append(
                Assignment(
                    slot_id=slot.id,
                    employee_id=employee.id,
                    cost_units=quote.cost_units,
                    cost_components=tuple(
                        component.to_dict() for component in quote.components
                    ),
                )
            )
        unfilled_ids = tuple(
            slot.id for slot in slots if solver.value(artifacts.unfilled[slot.id])
        )
        metrics = {
            name: int(solver.value(expression))
            for name, expression in artifacts.metrics.items()
        }
        return VariantResult(
            strategy_id=strategy.id,
            strategy_code=strategy.code,
            label=strategy.label,
            sort_order=strategy.sort_order,
            assignments=tuple(assignments),
            unfilled_slot_ids=unfilled_ids,
            metrics=metrics,
            stage_objectives=tuple(stage_results),
            optimal=optimal,
            solution_hash=sha256_hex(selected_map),
        )
