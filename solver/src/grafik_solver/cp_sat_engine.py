from __future__ import annotations

import logging
import math
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
from .slots import (
    Slot,
    consecutive_shift_sequence,
    generate_slots,
    shift_sequence_boundaries,
)


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

# Large coverage proofs can spend a bounded part of the shared CP-SAT budget on
# period relaxations. Their proven bounds remain valid monthly lower bounds:
# every feasible monthly roster, restricted to a block, is feasible in that
# block's relaxed model. Small models stay on the cheaper monolithic path.
MIN_DECOMPOSED_PROOF_SLOTS = 500
DECOMPOSED_PROOF_BUDGET_FRACTION = 0.35
MAX_DECOMPOSED_PROOF_SECONDS = 300.0
BOUNDARY_PROOF_BUDGET_FRACTION = 0.35

# A relaxed UAT run accepts a feasible coverage incumbent, so it must not spend
# the entire shared worker budget trying to prove the monthly minimum.  The
# remaining time is more valuable for materializing and validating strategies.
MAX_RELAXED_COVERAGE_SECONDS = 30.0
MAX_RELAXED_STRATEGY_SECONDS = 35.0
MAX_RELAXED_STRATEGY_WARM_START_SECONDS = 15.0
RELAXED_STRATEGY_FINAL_RESERVE_SECONDS = 7.0
MAX_RELAXED_DIVERSITY_SECONDS = 6.0
RELAXED_DIVERSITY_FRACTION = 0.01
MAX_RELAXED_DIVERSITY_ASSIGNMENT_CHANGES = 20
OBJECTIVE_COEFFICIENT_SCALE = 1_000_000_000


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
    coverage_aggregated_seats: int = 0


@dataclass(frozen=True)
class _CoverageCertificate:
    lower_bound: int
    blocks: tuple[Mapping[str, Any], ...]
    boundary_partitions: tuple[Mapping[str, Any], ...]
    all_weeks_optimal: bool
    assignment_hints: Mapping[tuple[str, str], int]
    unfilled_hints: Mapping[str, int]


@dataclass(frozen=True)
class _CoverageSubproblem:
    lower_bound: int
    incumbent: int | None
    status: str
    optimal: bool
    assignment_hints: Mapping[tuple[str, str], int]
    unfilled_hints: Mapping[str, int]


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
    def _apply_coverage_solution_hint(
        source: _Artifacts,
        source_solver: Any,
        target: _Artifacts,
        slots: tuple[Slot, ...],
    ) -> int:
        """Expand the aggregate coverage incumbent into a full-model hint."""
        coverage_groups: dict[tuple[str, str], list[Slot]] = defaultdict(list)
        for slot in slots:
            coverage_groups[(slot.demand_id, slot.occurrence_id)].append(slot)

        hinted = 0
        source_is_aggregate = set(source.unfilled) != {slot.id for slot in slots}
        if source_is_aggregate:
            for group_slots in coverage_groups.values():
                ordered_slots = sorted(
                    group_slots, key=lambda item: (item.seat_index, item.id)
                )
                representative = ordered_slots[0]
                selected_employees = sorted(
                    employee_id
                    for (employee_id, slot_id), variable in source.x.items()
                    if slot_id == representative.id and source_solver.value(variable)
                )
                selected_by_slot = {
                    slot.id: (
                        selected_employees[index]
                        if index < len(selected_employees)
                        else None
                    )
                    for index, slot in enumerate(ordered_slots)
                }
                for (employee_id, slot_id), variable in target.x.items():
                    if slot_id not in selected_by_slot:
                        continue
                    if selected_by_slot[slot_id] == employee_id:
                        target.model.add_hint(variable, 1)
                        hinted += 1
                for slot in ordered_slots:
                    variable = target.unfilled.get(slot.id)
                    if variable is not None and selected_by_slot[slot.id] is None:
                        target.model.add_hint(variable, 1)
                        hinted += 1
        else:
            for key, variable in target.x.items():
                source_variable = source.x.get(key)
                if source_variable is not None and source_solver.value(source_variable):
                    target.model.add_hint(variable, 1)
                    hinted += 1
            for slot in slots:
                variable = target.unfilled.get(slot.id)
                source_variable = source.unfilled.get(slot.id)
                if (
                    variable is not None
                    and source_variable is not None
                    and source_solver.value(source_variable)
                ):
                    target.model.add_hint(variable, 1)
                    hinted += 1

        for name in ("work", "day_work"):
            source_variables = getattr(source, name)
            target_variables = getattr(target, name)
            for key, variable in target_variables.items():
                source_variable = source_variables.get(key)
                if source_variable is not None and source_solver.value(source_variable):
                    target.model.add_hint(variable, 1)
                    hinted += 1
        return hinted

    @staticmethod
    def _add_diversity_constraints(
        artifacts: _Artifacts,
        previous_results: Iterable[VariantResult],
    ) -> tuple[dict[str, Any], ...]:
        """Exclude materially equivalent rosters without weakening objectives.

        This runs only after every business objective tier has been frozen at
        its Matrix-defined value plus tolerance.  A replacement roster must
        therefore keep all hard rules, minimum coverage and the current
        strategy's business bounds while changing a small, visible number of
        employee assignments.
        """
        exclusions: list[dict[str, Any]] = []
        for previous in previous_results:
            selected = [
                variable
                for assignment in previous.assignments
                if (
                    variable := artifacts.x.get(
                        (assignment.employee_id, assignment.slot_id)
                    )
                )
                is not None
            ]
            if not selected:
                continue
            required_changes = max(
                1,
                min(
                    MAX_RELAXED_DIVERSITY_ASSIGNMENT_CHANGES,
                    math.ceil(len(selected) * RELAXED_DIVERSITY_FRACTION),
                ),
            )
            artifacts.model.add(_sum(selected) <= len(selected) - required_changes)
            exclusions.append(
                {
                    "strategyId": previous.strategy_id,
                    "minimumAssignmentChanges": required_changes,
                }
            )
        return tuple(exclusions)

    @staticmethod
    def _replace_with_nonzero_solution_hints(
        model: Any,
        solver: Any,
        variables: Iterable[Any],
    ) -> int:
        """Keep useful incumbent decisions without a huge all-zero hint proto."""
        model.clear_hints()
        hinted = 0
        for variable in variables:
            value = int(solver.value(variable))
            if value == 0:
                continue
            model.add_hint(variable, value)
            hinted += 1
        return hinted

    @staticmethod
    def _normalized_tier_value(
        solver: Any,
        artifacts: _Artifacts,
        terms: Iterable[Mapping[str, Any]],
    ) -> int:
        """Evaluate a normalized objective from pre-objective solver metrics."""
        value = 0
        for term in terms:
            raw_value = int(solver.value(artifacts.metrics[term["metric"]]))
            target = term["parameters"].get("targetValue")
            if target is not None:
                raw_value = abs(raw_value - int(target))
            sign = 1 if term["direction"] == "MIN" else -1
            value += sign * int(term["normalizationCoefficient"]) * raw_value
        return value

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
            rendered = f"{value:.6g}" if isinstance(value, float) else str(value)
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

        certificate = self._coverage_certificate(
            snapshot,
            slots,
            eligibility,
            global_deadline,
        )

        common = self._build_model(snapshot, slots, eligibility, coverage_only=True)
        if certificate is not None:
            # The exact certificate supersedes the generic greedy warm start.
            # CP-SAT rejects duplicate hint variables, and the independently
            # solved certificate blocks are not guaranteed to form a monthly
            # hard-feasible assignment that could safely be fixed in place.
            common.model.clear_hints()
            common.complete_coverage_hint = False
            common.model.add(common.metrics["UNFILLED"] >= certificate.lower_bound)
            for key, value in certificate.assignment_hints.items():
                variable = common.x.get(key)
                if variable is not None:
                    common.model.add_hint(variable, value)
            for slot_id, value in certificate.unfilled_hints.items():
                variable = common.unfilled.get(slot_id)
                if variable is not None:
                    common.model.add_hint(variable, value)
        LOGGER.info(
            "Coverage model slots=%s eligiblePairs=%s symmetryConstraints=%s "
            "aggregatedSeats=%s certificateLowerBound=%s",
            len(slots),
            len(common.x),
            common.coverage_symmetry_constraints,
            common.coverage_aggregated_seats,
            certificate.lower_bound if certificate is not None else None,
        )
        self._emit_progress(
            slotCount=len(slots),
            eligibleDecisionPairs=len(common.x),
            coverageSymmetryConstraints=common.coverage_symmetry_constraints,
            coverageAggregatedSeats=common.coverage_aggregated_seats,
            coverageCertificateLowerBound=(
                certificate.lower_bound if certificate is not None else None
            ),
            coverageCertificateBlocks=(
                len(certificate.blocks) if certificate is not None else 0
            ),
        )
        common.model.clear_objective()
        common.model.minimize(common.metrics["UNFILLED"])
        common_time_limit = self._remaining_seconds(global_deadline, "GLOBAL:UNFILLED")
        if not snapshot.settings.require_optimal:
            common_time_limit = min(
                common_time_limit,
                MAX_RELAXED_COVERAGE_SECONDS,
            )
        common_solver, common_status = self._solve_model(
            common.model,
            snapshot,
            strategy=None,
            stage_name="UNFILLED",
            time_limit_seconds=common_time_limit,
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
        strategy_base = self._build_model(snapshot, slots, eligibility)
        self._ensure_deadline(global_deadline, "GLOBAL")
        LOGGER.info(
            "Built one reusable full model for %s strategies: variables=%s",
            strategy_count,
            len(strategy_base.model.proto.variables),
        )
        shared_warm_start_solver: Any | None = None
        if not snapshot.settings.require_optimal:
            # Feasibility of the complete pay/budget model is independent of
            # the business strategy. Solve it once, with the proven minimum
            # coverage fixed, and reuse the incumbent for every cloned
            # strategy model. This removes three nondeterministic warm starts
            # from a monthly run and gives a real snapshot enough time to
            # establish its first full feasible roster.
            warm_artifacts = replace(
                strategy_base,
                model=strategy_base.model.clone(),
            )
            warm_artifacts.model.add(
                warm_artifacts.metrics["UNFILLED"] == minimum_unfilled
            )
            self._apply_coverage_solution_hint(
                common,
                common_solver,
                warm_artifacts,
                slots,
            )
            warm_start_solver, warm_start_status = self._solve_model(
                warm_artifacts.model,
                snapshot,
                strategy=None,
                stage_name="WARM_START",
                time_limit_seconds=min(
                    self._remaining_seconds(global_deadline, "GLOBAL:WARM_START"),
                    MAX_RELAXED_STRATEGY_WARM_START_SECONDS,
                ),
            )
            self._require_optimal(
                warm_start_solver,
                warm_start_status,
                snapshot,
                "GLOBAL:WARM_START",
            )
            shared_warm_start_solver = warm_start_solver
            LOGGER.info(
                "Completed one reusable full-model warm start for %s strategies",
                strategy_count,
            )
        for strategy_index, strategy in enumerate(ordered_strategies):
            if self._cancel_event.is_set():
                raise OptimizationCancelled("Optimization was cancelled")
            self._ensure_deadline(global_deadline, "GLOBAL")
            artifacts = replace(
                strategy_base,
                model=strategy_base.model.clone(),
            )
            strategy_started = self._clock()
            strategy_budget = strategy.time_limit_seconds or self._cp_sat_budget_seconds
            if not snapshot.settings.require_optimal:
                strategy_budget = min(
                    strategy_budget,
                    MAX_RELAXED_STRATEGY_SECONDS,
                )
            strategy_deadline = min(
                global_deadline,
                strategy_started + strategy_budget,
            )
            self._ensure_deadline(strategy_deadline, strategy.code)
            artifacts.model.add(artifacts.metrics["UNFILLED"] == minimum_unfilled)
            coverage_hint_count = self._apply_coverage_solution_hint(
                common, common_solver, artifacts, slots
            )
            LOGGER.info(
                "Strategy %s seeded with %s coverage hint values",
                strategy.code,
                coverage_hint_count,
            )
            stage_results: list[dict[str, Any]] = [
                {
                    "tier": 0,
                    "name": "UNFILLED",
                    "value": minimum_unfilled,
                    "status": common_solver.status_name(common_status),
                    "tolerance": 0,
                    "frozenUpperBound": minimum_unfilled,
                    **(
                        {
                            "certificate": {
                                "kind": "BOUNDARY_AWARE_PERIOD_DECOMPOSITION",
                                "lowerBound": certificate.lower_bound,
                                "allWeeksOptimal": certificate.all_weeks_optimal,
                                "blocks": [dict(item) for item in certificate.blocks],
                                "boundaryPartitions": [
                                    dict(item)
                                    for item in certificate.boundary_partitions
                                ],
                            }
                        }
                        if certificate is not None
                        else {}
                    ),
                }
            ]
            all_stages_optimal = all_common_stages_optimal
            incumbent: dict[int, int] | None = None
            final_solver: Any | None = None
            final_status: Any | None = None
            feasible_fallback_solver: Any | None = None

            if not snapshot.settings.require_optimal:
                if shared_warm_start_solver is None:
                    raise OptimizationIncomplete("GLOBAL:WARM_START missing incumbent")
                full_variables = (
                    artifacts.model.get_int_var_from_proto_index(variable_index)
                    for variable_index in range(len(artifacts.model.proto.variables))
                )
                nonzero_hint_count = self._replace_with_nonzero_solution_hints(
                    artifacts.model,
                    shared_warm_start_solver,
                    full_variables,
                )
                LOGGER.info(
                    "Strategy %s reused a sparse %s-variable full-model warm start",
                    strategy.code,
                    nonzero_hint_count,
                )
                feasible_fallback_solver = shared_warm_start_solver

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
                raw_expression_bound = expression_bound
                normalization_coefficient = 0
                if expression_bound > 0:
                    normalization_coefficient = max(
                        1,
                        round(
                            term.weight * OBJECTIVE_COEFFICIENT_SCALE / expression_bound
                        ),
                    )
                sign = 1 if term.direction == "MIN" else -1
                tier_upper_bounds[term.tier] += (
                    normalization_coefficient * expression_bound
                )
                tier_tolerances[term.tier] += normalization_coefficient * term.tolerance
                if (
                    tier_upper_bounds[term.tier] + tier_tolerances[term.tier]
                    > SAFE_CP_SAT_INTEGER
                ):
                    raise SnapshotError(
                        f"Strategy {strategy.id} tier {term.tier} exceeds the "
                        "safe CP-SAT integer range"
                    )
                tiers[term.tier].append(
                    sign * normalization_coefficient * metric_expression
                )
                tier_terms[term.tier].append(
                    {
                        "metric": metric_name,
                        "direction": term.direction,
                        "weight": term.weight,
                        "tolerance": term.tolerance,
                        "parameters": dict(term.parameters),
                        "normalizationCoefficient": normalization_coefficient,
                        "metricUpperBound": raw_expression_bound,
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
                    time_limit_seconds=max(
                        0.001,
                        self._remaining_seconds(strategy_deadline, strategy.code)
                        - (
                            RELAXED_STRATEGY_FINAL_RESERVE_SECONDS
                            if feasible_fallback_solver is not None
                            else 0.0
                        ),
                    ),
                )
                if (
                    final_status == cp_model.UNKNOWN
                    and feasible_fallback_solver is not None
                ):
                    LOGGER.warning(
                        "Strategy %s feasibility search ended UNKNOWN; using the "
                        "verified full-model warm start",
                        strategy.code,
                    )
                    final_solver = feasible_fallback_solver
                    final_status = cp_model.FEASIBLE
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
                    if incumbent is not None:
                        artifacts.model.clear_hints()
                        for variable in artifacts.hint_variables:
                            if (
                                variable.index in incumbent
                                and incumbent[variable.index] != 0
                            ):
                                artifacts.model.add_hint(
                                    variable, incumbent[variable.index]
                                )
                    fixed_unfilled_tier = tier_index < len(ordered_tiers) and all(
                        term["metric"] == "UNFILLED"
                        and "targetValue" not in term["parameters"]
                        for term in tier_terms[tier]
                    )
                    if fixed_unfilled_tier:
                        exact_value = sum(
                            (1 if term["direction"] == "MIN" else -1)
                            * term["normalizationCoefficient"]
                            * minimum_unfilled
                            for term in tier_terms[tier]
                        )
                        allowed_degradation = tier_tolerances[tier]
                        stage_results.append(
                            {
                                "tier": tier,
                                "name": f"TIER_{tier}",
                                "value": exact_value,
                                "status": "OPTIMAL",
                                "bestBound": float(exact_value),
                                "tolerance": allowed_degradation,
                                "frozenUpperBound": (exact_value + allowed_degradation),
                                "terms": tier_terms[tier],
                            }
                        )
                        artifacts.model.add(
                            expression <= exact_value + allowed_degradation
                        )
                        self._emit_progress(
                            phase=f"TIER_{tier}",
                            progress=10
                            + (
                                80
                                * (strategy_index * len(ordered_tiers) + tier_index)
                                // (strategy_count * len(ordered_tiers))
                            ),
                            strategyId=strategy.id,
                            strategyProgress=(90 * tier_index // len(ordered_tiers)),
                            strategyCount=strategy_count,
                            completedStrategies=strategy_index,
                        )
                        continue
                    artifacts.model.clear_objective()
                    artifacts.model.minimize(expression)
                    final_solver, final_status = self._solve_model(
                        artifacts.model,
                        snapshot,
                        strategy=strategy,
                        stage_name=f"TIER_{tier}",
                        time_limit_seconds=max(
                            0.001,
                            self._remaining_seconds(strategy_deadline, strategy.code)
                            - (
                                RELAXED_STRATEGY_FINAL_RESERVE_SECONDS
                                if feasible_fallback_solver is not None
                                else 0.0
                            ),
                        ),
                    )
                    used_fallback = False
                    if (
                        final_status == cp_model.UNKNOWN
                        and feasible_fallback_solver is not None
                    ):
                        LOGGER.warning(
                            "Strategy %s tier %s ended UNKNOWN; using the "
                            "verified full-model warm start/incumbent",
                            strategy.code,
                            tier,
                        )
                        final_solver = feasible_fallback_solver
                        final_status = cp_model.FEASIBLE
                        used_fallback = True
                    all_stages_optimal &= self._require_optimal(
                        final_solver,
                        final_status,
                        snapshot,
                        f"{strategy.code}:TIER_{tier}",
                    )
                    self._ensure_deadline(
                        strategy_deadline, f"{strategy.code}:TIER_{tier}"
                    )
                    exact_value = (
                        self._normalized_tier_value(
                            final_solver,
                            artifacts,
                            tier_terms[tier],
                        )
                        if used_fallback
                        else int(final_solver.value(expression))
                    )
                    allowed_degradation = tier_tolerances[tier]
                    incumbent = {
                        variable.index: int(final_solver.value(variable))
                        for variable in artifacts.hint_variables
                    }
                    feasible_fallback_solver = final_solver
                    stage_results.append(
                        {
                            "tier": tier,
                            "name": f"TIER_{tier}",
                            "value": exact_value,
                            "status": final_solver.status_name(final_status),
                            **(
                                {}
                                if used_fallback
                                else {"bestBound": final_solver.best_objective_bound}
                            ),
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
            if owner is not None and not snapshot.settings.require_optimal:
                artifacts.model.clear_objective()
                self._replace_with_nonzero_solution_hints(
                    artifacts.model,
                    final_solver,
                    artifacts.hint_variables,
                )
                exclusions = self._add_diversity_constraints(artifacts, results)
                remaining = strategy_deadline - self._clock()
                if exclusions and remaining > 0.05:
                    diversity_solver, diversity_status = self._solve_model(
                        artifacts.model,
                        snapshot,
                        strategy=strategy,
                        stage_name="DIVERSIFY",
                        time_limit_seconds=min(
                            MAX_RELAXED_DIVERSITY_SECONDS,
                            max(0.001, remaining - 0.01),
                        ),
                    )
                    if diversity_status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
                        diversity_stages = [
                            *stage_results,
                            {
                                "tier": max(tiers) + 1 if tiers else 1,
                                "name": "DIVERSIFY",
                                "status": diversity_solver.status_name(
                                    diversity_status
                                ),
                                "businessObjectiveBoundsPreserved": True,
                                "excludedEquivalentStrategies": list(exclusions),
                            },
                        ]
                        candidate = self._extract_result(
                            snapshot,
                            slots,
                            strategy,
                            artifacts,
                            diversity_solver,
                            diversity_stages,
                            optimal=all_stages_optimal,
                        )
                        if candidate.solution_hash not in solution_owners:
                            LOGGER.info(
                                "Strategy %s diversified a tied roster while "
                                "preserving all frozen business bounds",
                                strategy.code,
                            )
                            result = candidate
                            owner = None
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

    @staticmethod
    def _two_day_partitions(
        slots: tuple[Slot, ...],
    ) -> tuple[tuple[tuple[Slot, ...], ...], ...]:
        first_day = min(slot.date for slot in slots)
        last_day = max(slot.date for slot in slots)
        slots_by_day: dict[date, list[Slot]] = defaultdict(list)
        for slot in slots:
            slots_by_day[slot.date].append(slot)

        partitions: list[tuple[tuple[Slot, ...], ...]] = []
        for offset in (0, 1):
            blocks: list[tuple[Slot, ...]] = []
            day = first_day
            if offset:
                first_block = tuple(
                    sorted(slots_by_day.get(day, []), key=lambda item: item.id)
                )
                if first_block:
                    blocks.append(first_block)
                day += timedelta(days=1)
            while day <= last_day:
                next_day = day + timedelta(days=1)
                block = tuple(
                    sorted(
                        slots_by_day.get(day, []) + slots_by_day.get(next_day, []),
                        key=lambda item: (item.start, item.id),
                    )
                )
                if block:
                    blocks.append(block)
                day += timedelta(days=2)
            partitions.append(tuple(blocks))
        return tuple(partitions)

    def _solve_coverage_subproblem(
        self,
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        eligibility: EligibilityIndex,
        *,
        stage_name: str,
        time_limit_seconds: float,
    ) -> _CoverageSubproblem:
        slot_ids = {slot.id for slot in slots}
        block_snapshot = replace(
            snapshot,
            locked_assignments=tuple(
                lock for lock in snapshot.locked_assignments if lock.slot_id in slot_ids
            ),
        )
        artifacts = self._build_model(
            block_snapshot,
            slots,
            eligibility,
            coverage_only=True,
        )
        artifacts.model.clear_objective()
        artifacts.model.minimize(artifacts.metrics["UNFILLED"])
        solver, status = self._solve_model(
            artifacts.model,
            block_snapshot,
            strategy=None,
            stage_name=stage_name,
            time_limit_seconds=max(0.001, time_limit_seconds),
        )
        status_name = solver.status_name(status)
        if status in (cp_model.INFEASIBLE, cp_model.MODEL_INVALID):
            raise OptimizationError(f"{stage_name} is {status_name.lower()}")

        incumbent: int | None = None
        assignment_hints: dict[tuple[str, str], int] = {}
        unfilled_hints: dict[str, int] = {}
        if status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
            incumbent = int(solver.value(artifacts.metrics["UNFILLED"]))
            assignment_hints = {
                key: int(solver.value(variable))
                for key, variable in artifacts.x.items()
            }
            unfilled_hints = {
                slot_id: int(solver.value(variable))
                for slot_id, variable in artifacts.unfilled.items()
            }

        if status == cp_model.OPTIMAL:
            lower_bound = incumbent or 0
        else:
            raw_bound = self._solver_measure(solver, "best_objective_bound")
            lower_bound = (
                max(0, math.ceil(float(raw_bound) - 1e-7))
                if raw_bound is not None and math.isfinite(float(raw_bound))
                else 0
            )
        return _CoverageSubproblem(
            lower_bound=lower_bound,
            incumbent=incumbent,
            status=status_name,
            optimal=status == cp_model.OPTIMAL,
            assignment_hints=assignment_hints,
            unfilled_hints=unfilled_hints,
        )

    def _coverage_certificate(
        self,
        snapshot: Snapshot,
        slots: tuple[Slot, ...],
        eligibility: EligibilityIndex,
        global_deadline: float,
    ) -> _CoverageCertificate | None:
        if (
            not snapshot.settings.require_optimal
            or len(slots) < MIN_DECOMPOSED_PROOF_SLOTS
            or any(budget.hard for budget in snapshot.budgets)
        ):
            return None

        slots_by_week: dict[tuple[int, int], list[Slot]] = defaultdict(list)
        for slot in slots:
            iso = slot.date.isocalendar()
            slots_by_week[(iso.year, iso.week)].append(slot)
        weekly_blocks = [
            tuple(sorted(block, key=lambda item: (item.start, item.id)))
            for _, block in sorted(slots_by_week.items())
            if block
        ]
        if len(weekly_blocks) < 2:
            return None

        started = self._clock()
        certificate_seconds = min(
            MAX_DECOMPOSED_PROOF_SECONDS,
            self._cp_sat_budget_seconds * DECOMPOSED_PROOF_BUDGET_FRACTION,
        )
        certificate_deadline = min(global_deadline, started + certificate_seconds)
        boundary_deadline = min(
            certificate_deadline,
            started + certificate_seconds * BOUNDARY_PROOF_BUDGET_FRACTION,
        )

        boundary_partitions = self._two_day_partitions(slots)
        remaining_boundary_blocks = sum(len(items) for items in boundary_partitions)
        boundary_results: list[Mapping[str, Any]] = []
        boundary_hints: list[tuple[dict[tuple[str, str], int], dict[str, int]]] = []
        for partition_index, partition in enumerate(boundary_partitions, start=1):
            partition_bound = 0
            partition_optimal = True
            partition_assignments: dict[tuple[str, str], int] = {}
            partition_unfilled: dict[str, int] = {}
            solved_blocks = 0
            for block_index, block_slots in enumerate(partition, start=1):
                if self._cancel_event.is_set():
                    raise OptimizationCancelled("Optimization was cancelled")
                remaining = boundary_deadline - self._clock()
                if remaining <= 0.001:
                    partition_optimal = False
                    remaining_boundary_blocks -= 1
                    continue
                proof = self._solve_coverage_subproblem(
                    snapshot,
                    block_slots,
                    eligibility,
                    stage_name=(f"UNFILLED_BOUNDARY_{partition_index}_{block_index}"),
                    time_limit_seconds=(remaining / max(1, remaining_boundary_blocks)),
                )
                remaining_boundary_blocks -= 1
                solved_blocks += 1
                partition_bound += proof.lower_bound
                partition_optimal &= proof.optimal
                partition_assignments.update(proof.assignment_hints)
                partition_unfilled.update(proof.unfilled_hints)
            boundary_results.append(
                {
                    "partition": partition_index,
                    "blockCount": len(partition),
                    "solvedBlocks": solved_blocks,
                    "lowerBound": partition_bound,
                    "allBlocksOptimal": partition_optimal,
                }
            )
            boundary_hints.append((partition_assignments, partition_unfilled))

        strongest_boundary_index = max(
            range(len(boundary_results)),
            key=lambda index: int(boundary_results[index]["lowerBound"]),
        )
        boundary_lower_bound = int(
            boundary_results[strongest_boundary_index]["lowerBound"]
        )
        assignment_hints, unfilled_hints = (
            dict(boundary_hints[strongest_boundary_index][0]),
            dict(boundary_hints[strongest_boundary_index][1]),
        )

        weekly_lower_bound = 0
        all_weeks_optimal = True
        blocks: list[Mapping[str, Any]] = []
        for block_index, block_slots in enumerate(weekly_blocks, start=1):
            if self._cancel_event.is_set():
                raise OptimizationCancelled("Optimization was cancelled")
            remaining_weeks = len(weekly_blocks) - block_index + 1
            remaining = certificate_deadline - self._clock()
            if remaining <= 0.001:
                all_weeks_optimal = False
                blocks.append(
                    {
                        "start": min(slot.date for slot in block_slots).isoformat(),
                        "end": max(slot.date for slot in block_slots).isoformat(),
                        "slotCount": len(block_slots),
                        "status": "UNSOLVED",
                        "lowerBound": 0,
                        "incumbentUnfilled": None,
                    }
                )
                continue
            proof = self._solve_coverage_subproblem(
                snapshot,
                block_slots,
                eligibility,
                stage_name=f"UNFILLED_WEEK_{block_index}",
                time_limit_seconds=remaining / remaining_weeks,
            )
            weekly_lower_bound += proof.lower_bound
            all_weeks_optimal &= proof.optimal
            assignment_hints.update(proof.assignment_hints)
            unfilled_hints.update(proof.unfilled_hints)
            blocks.append(
                {
                    "start": min(slot.date for slot in block_slots).isoformat(),
                    "end": max(slot.date for slot in block_slots).isoformat(),
                    "slotCount": len(block_slots),
                    "status": proof.status,
                    "lowerBound": proof.lower_bound,
                    "incumbentUnfilled": proof.incumbent,
                }
            )

        lower_bound = max(boundary_lower_bound, weekly_lower_bound)
        LOGGER.info(
            "Boundary-aware coverage certificate lowerBound=%s weeklyBound=%s "
            "boundaryBound=%s allWeeksOptimal=%s wallTimeSeconds=%.3f",
            lower_bound,
            weekly_lower_bound,
            boundary_lower_bound,
            all_weeks_optimal,
            self._clock() - started,
        )
        return _CoverageCertificate(
            lower_bound=lower_bound,
            blocks=tuple(blocks),
            boundary_partitions=tuple(boundary_results),
            all_weeks_optimal=all_weeks_optimal,
            assignment_hints=assignment_hints,
            unfilled_hints=unfilled_hints,
        )

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
        if fix_hints:
            # The coverage assignment is already fixed. Presolving the whole
            # dynamic pay model can take far longer than evaluating its
            # dependent variables and is not bounded reliably by CP-SAT's
            # search timer on large monthly instances.
            solver.parameters.cp_model_presolve = False
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
            if set(employee.preferred_shift_template_ids) & set(
                employee.blocked_shift_template_ids
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
        aggregate_coverage = set(unfilled) != {slot.id for slot in slots}
        coverage_groups: dict[tuple[str, str], list[Slot]] = defaultdict(list)
        for slot in slots:
            coverage_groups[(slot.demand_id, slot.occurrence_id)].append(slot)
        if aggregate_coverage:
            decision_slots = {
                min(group, key=lambda item: (item.seat_index, item.id)).id: min(
                    group, key=lambda item: (item.seat_index, item.id)
                )
                for group in coverage_groups.values()
            }
            capacity_by_slot = {
                min(group, key=lambda item: (item.seat_index, item.id)).id: len(group)
                for group in coverage_groups.values()
            }
            decision_id_by_slot = {
                slot.id: min(
                    coverage_groups[(slot.demand_id, slot.occurrence_id)],
                    key=lambda item: (item.seat_index, item.id),
                ).id
                for slot in slots
            }
        else:
            decision_slots = {slot.id: slot for slot in slots}
            capacity_by_slot = {slot.id: 1 for slot in slots}
            decision_id_by_slot = {slot.id: slot.id for slot in slots}

        selected_by_slot: dict[str, set[str]] = defaultdict(set)
        used_occurrences: set[tuple[str, str]] = set()
        daily_count: dict[tuple[str, date], int] = defaultdict(int)
        monthly_minutes: dict[str, int] = defaultdict(int)
        weekly_minutes: dict[tuple[str, tuple[int, int]], int] = defaultdict(int)
        worked_days: dict[str, set[date]] = defaultdict(set)
        sequence_boundaries = shift_sequence_boundaries(snapshot)

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
            # One employee may work at most one primary shift per calendar day.
            # The number of shift templates configured in Matrix is a separate
            # concept and must never relax this invariant.
            if daily_count[(employee.id, slot.date)] >= 1:
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
                or consecutive_shift_sequence(sequence_boundaries, previous, slot)
                or consecutive_shift_sequence(sequence_boundaries, slot, previous)
                for previous in selected_by_employee[employee.id]
            ):
                return False
            if employee.maximum_consecutive_days is not None:
                days = worked_days[employee.id] | {slot.date}
                if longest_run(days) > employee.maximum_consecutive_days:
                    return False
            return True

        def select(employee: Employee, slot: Slot) -> None:
            selected_by_slot[slot.id].add(employee.id)
            selected_by_employee[employee.id].append(slot)
            used_occurrences.add((employee.id, slot.occurrence_id))
            daily_count[(employee.id, slot.date)] += 1
            monthly_minutes[employee.id] += slot.duration_minutes
            weekly_minutes[(employee.id, week_key(slot))] += slot.duration_minutes
            worked_days[employee.id].add(slot.date)

        slots_by_id = {slot.id: slot for slot in slots}
        for lock in sorted(snapshot.locked_assignments, key=lambda item: item.slot_id):
            locked_slot = slots_by_id.get(lock.slot_id)
            employee = employees.get(lock.employee_id)
            if locked_slot is None:
                raise SnapshotError(f"Lock references missing slot {lock.slot_id}")
            if employee is None:
                raise SnapshotError(
                    f"Lock references missing employee {lock.employee_id}"
                )
            decision_id = decision_id_by_slot[locked_slot.id]
            slot = decision_slots[decision_id]
            if (employee.id, decision_id) not in x:
                raise SnapshotError(
                    f"Locked assignment {employee.id}/{slot.id} is not eligible"
                )
            if employee.id in selected_by_slot[decision_id]:
                continue
            if not can_add(employee, slot):
                return 0
            select(employee, slot)

        candidate_ids = {
            slot.id: sorted(
                employee.id
                for employee in snapshot.employees
                if (employee.id, slot.id) in x
            )
            for slot in decision_slots.values()
        }
        ordered_slots = sorted(
            decision_slots.values(),
            key=lambda slot: (
                len(candidate_ids[slot.id]) - capacity_by_slot[slot.id],
                len(candidate_ids[slot.id]),
                slot.start,
                slot.location_id,
                slot.id,
            ),
        )
        for slot in ordered_slots:
            while len(selected_by_slot[slot.id]) < capacity_by_slot[slot.id]:
                candidates = [
                    employees[employee_id]
                    for employee_id in candidate_ids[slot.id]
                    if can_add(employees[employee_id], slot)
                ]
                if not candidates:
                    break
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
            model.add_hint(variable, int(key[0] in selected_by_slot[key[1]]))
        for slot_id, variable in unfilled.items():
            model.add_hint(
                variable,
                capacity_by_slot[slot_id] - len(selected_by_slot[slot_id]),
            )
        return sum(len(selected) for selected in selected_by_slot.values())

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
            if len(ordered) < 2 or any(slot.id in locked_slot_ids for slot in ordered):
                continue
            for left, right in zip(ordered, ordered[1:], strict=False):
                left_rank = (
                    _sum(
                        rank * variable
                        for employee_id, rank in employee_ranks.items()
                        if (variable := x.get((employee_id, left.id))) is not None
                    )
                    + unfilled_rank * unfilled[left.id]
                )
                right_rank = (
                    _sum(
                        rank * variable
                        for employee_id, rank in employee_ranks.items()
                        if (variable := x.get((employee_id, right.id))) is not None
                    )
                    + unfilled_rank * unfilled[right.id]
                )
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
        coverage_groups: dict[tuple[str, str], list[Slot]] = defaultdict(list)
        for slot in slots:
            representative = occurrences.setdefault(slot.occurrence_id, slot)
            if representative.start != slot.start or representative.end != slot.end:
                raise SnapshotError(
                    f"Occurrence {slot.occurrence_id} has inconsistent times"
                )
            slots_by_occurrence[slot.occurrence_id].append(slot)
            coverage_groups[(slot.demand_id, slot.occurrence_id)].append(slot)

        aggregate_coverage = coverage_only and not any(
            budget.hard for budget in snapshot.budgets
        )
        representative_by_group = {
            group_key: min(group, key=lambda item: (item.seat_index, item.id))
            for group_key, group in coverage_groups.items()
        }

        x: dict[tuple[str, str], Any] = {}
        static_quotes: dict[tuple[str, str], Any] = {}
        for employee in snapshot.employees:
            decision_slots = (
                representative_by_group.values() if aggregate_coverage else slots
            )
            for slot in decision_slots:
                if eligibility.evaluate(employee, slot).allowed:
                    key = (employee.id, slot.id)
                    x[key] = model.new_bool_var(f"x|{employee.id}|{slot.id}")
                    static_quotes[key] = quote_assignment(snapshot, employee, slot)

        unfilled: dict[str, Any] = {}
        if aggregate_coverage:
            for group_key, group_slots in coverage_groups.items():
                representative = representative_by_group[group_key]
                candidates = [
                    x[(employee.id, representative.id)]
                    for employee in snapshot.employees
                    if (employee.id, representative.id) in x
                ]
                missing = model.new_int_var(
                    0,
                    len(group_slots),
                    f"u|{representative.id}",
                )
                unfilled[representative.id] = missing
                model.add(_sum(candidates) + missing == len(group_slots))
        else:
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
                if aggregate_coverage:
                    assignment_vars = [
                        x[(employee.id, representative.id)]
                        for group_key, representative in representative_by_group.items()
                        if group_key[1] == occurrence_id
                        and (employee.id, representative.id) in x
                    ]
                else:
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
            decision_slot_id = lock.slot_id
            if aggregate_coverage:
                locked_slot = slots_by_id[lock.slot_id]
                decision_slot_id = representative_by_group[
                    (locked_slot.demand_id, locked_slot.occurrence_id)
                ].id
            variable = x.get((lock.employee_id, decision_slot_id))
            if variable is None:
                raise SnapshotError(
                    f"Locked assignment {lock.employee_id}/{lock.slot_id} "
                    "is not eligible"
                )
            model.add(variable == 1)

        coverage_symmetry_constraints = 0
        if coverage_only and not aggregate_coverage:
            coverage_symmetry_constraints = self._add_coverage_symmetry_breaking(
                model, snapshot, slots, x, unfilled
            )

        timezone = ZoneInfo(snapshot.settings.timezone)
        external_by_employee: dict[str, list[Any]] = defaultdict(list)
        for assignment in snapshot.external_assignments:
            external_by_employee[assignment.employee_id].append(assignment)

        occurrence_items = sorted(occurrences.items(), key=lambda item: item[1].start)
        sequence_boundaries = shift_sequence_boundaries(snapshot)
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
                    ) or consecutive_shift_sequence(
                        sequence_boundaries, first, second
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
                model.add(_sum(day_occurrences) + fixed_count <= 1)
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

        # A published role schedule must leave real, eligible people off duty
        # for daily Tier 1/Tier 2 readiness.  Reserve capacity in the model,
        # instead of discovering only after publication that everybody was
        # assigned.  The concrete Tier order remains a deterministic,
        # auditable publication concern.
        standby_tiers = snapshot.settings.standby_tiers_per_role_day
        if standby_tiers:
            role_day_slots: dict[tuple[str, date], list[Slot]] = defaultdict(list)
            for slot in slots:
                role_day_slots[(slot.role_id, slot.date)].append(slot)
            for (role_id, day), role_slots in role_day_slots.items():
                representative_slots = list({
                    slot.occurrence_id: slot for slot in role_slots
                }.values())
                eligible_employee_ids = [
                    employee.id
                    for employee in snapshot.employees
                    if employee.role_allowed_on(role_id, day)
                    and all(
                        eligibility.evaluate(
                            employee,
                            replace(slot, duty_ids=()),
                        ).allowed
                        for slot in representative_slots
                    )
                ]
                if len(eligible_employee_ids) < standby_tiers:
                    model.add(0 >= standby_tiers)
                    continue
                model.add(
                    _sum(
                        day_work[(employee_id, day)]
                        for employee_id in eligible_employee_ids
                    )
                    <= len(eligible_employee_ids) - standby_tiers
                )

        if aggregate_coverage:
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
                coverage_aggregated_seats=len(slots) - len(coverage_groups),
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
