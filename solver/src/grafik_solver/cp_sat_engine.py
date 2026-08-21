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
    # Public Matrix workbooks keep their stable metric codes, while the engine
    # optimizes a role-aware fairness score.  Comparing one global minimum and
    # maximum for a whole category hid severe inequalities inside small roles
    # (for example two BARBACK employees).  The separate public max-spread
    # metric remains available for an understandable percentage in the UI.
    "LOAD_SPREAD": "ROLE_LOAD_FAIRNESS_SCORE",
    "LOAD_SPREAD_MINUTES": "ROLE_LOAD_FAIRNESS_SCORE",
    "BASELINE_CHANGES_COUNT": "BASELINE_CHANGES",
    "UNFILLED_SEATS": "UNFILLED",
    "TOTAL_COST_MINOR": "TOTAL_COST",
    "WORKLOAD_VARIANCE": "ROLE_LOAD_FAIRNESS_SCORE",
    "WEEKEND_SPREAD": "ROLE_WEEKEND_FAIRNESS_SCORE",
    "WEEKEND_VARIANCE": "ROLE_WEEKEND_FAIRNESS_SCORE",
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
# Monthly category schedules are commonly smaller than the old 500-seat gate.
# They still need the same structural-vacancy proof as the largest teams: a
# feasible incumbent is not evidence that an apparently free employee could
# not fill a vacancy. The decomposition is generic, so the same gate covers
# every built-in and employer-defined category without special cases.
MIN_DECOMPOSED_PROOF_SLOTS = 250
DECOMPOSED_PROOF_BUDGET_FRACTION = 0.35
MAX_DECOMPOSED_PROOF_SECONDS = 300.0
BOUNDARY_PROOF_BUDGET_FRACTION = 0.35

# A relaxed UAT run accepts a feasible coverage incumbent, so it must not spend
# the entire shared worker budget trying to prove the monthly minimum.  The
# remaining time is more valuable for materializing and validating strategies.
MAX_RELAXED_STRATEGY_WARM_START_SECONDS = 15.0
RELAXED_STRATEGY_FINAL_RESERVE_SECONDS = 7.0
MAX_RELAXED_COMMON_FAIRNESS_SECONDS = 12.0
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


def coverage_minimum_is_proven(
    minimum_unfilled: int,
    proven_lower_bound: int,
    solver_status: Any,
) -> bool:
    """Return whether a displayed shortage is mathematically established."""
    return (
        solver_status == cp_model.OPTIMAL
        or minimum_unfilled == proven_lower_bound
    )


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

    @staticmethod
    def _cost_precedes_other_goals(strategy: Strategy) -> bool:
        """Return whether Matrix objectives make cost the leading business goal.

        Strategy codes and labels are editable Matrix data, so neither may be
        used as a hidden switch.  The tier order of active objective terms is
        the only authoritative contract.
        """
        metric_tiers: dict[str, list[int]] = defaultdict(list)
        for term in strategy.objective_terms:
            if term.weight == 0:
                continue
            metric_tiers[METRIC_ALIASES.get(term.metric, term.metric)].append(
                term.tier
            )
        cost_tiers = metric_tiers.get("TOTAL_COST", [])
        other_goal_tiers = [
            tier
            for metric_name, tiers in metric_tiers.items()
            if metric_name not in {"TOTAL_COST", "UNFILLED"}
            for tier in tiers
        ]
        return bool(cost_tiers) and (
            not other_goal_tiers or min(cost_tiers) < min(other_goal_tiers)
        )

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
        # Coverage is still the absolute first priority.  For schedules with
        # the same number of filled seats, dedicated role holders precede
        # BACKUP grants (for example HOST before a waiter with HOST duty).
        role_priority_multiplier = common.metric_bounds["ROLE_BACKUP_PENALTY"] + 1
        common.model.minimize(
            common.metrics["UNFILLED"] * role_priority_multiplier
            + common.metrics["ROLE_BACKUP_PENALTY"]
        )
        common_time_limit = self._remaining_seconds(global_deadline, "GLOBAL:UNFILLED")
        if not snapshot.settings.require_optimal:
            # Coverage is the first and most important business objective.  Its
            # relaxed budget must scale with the Matrix configuration instead
            # of being silently truncated by a hard-coded worker constant.  A
            # fair share of the remaining global budget still protects the
            # later strategy variants from starvation.
            # Coverage is an invariant shared by every displayed strategy, not
            # merely a fourth variant.  Give it half of the remaining budget;
            # strategies share the other half.  The previous 1/(N+1) split
            # could freeze an early feasible incumbent with avoidable vacancies
            # and then faithfully reproduce that defect on every card.
            fair_coverage_share = common_time_limit * 0.5
            configured_strategy_limits = [
                float(strategy.time_limit_seconds)
                for strategy in snapshot.strategies
                if strategy.time_limit_seconds is not None
            ]
            configured_coverage_ceiling = (
                max(configured_strategy_limits)
                if configured_strategy_limits
                else fair_coverage_share
            )
            common_time_limit = min(
                common_time_limit,
                max(fair_coverage_share, configured_coverage_ceiling),
                configured_coverage_ceiling * 2,
            )
        common_solver, common_status = self._solve_model(
            common.model,
            snapshot,
            strategy=None,
            stage_name="UNFILLED",
            time_limit_seconds=common_time_limit,
            # A complete greedy hint proves that zero vacancies are feasible,
            # but it does not prove that the hinted BACKUP assignments are
            # necessary.  Fixing every hinted variable here used to turn the
            # warm start into the whole search space, so CP-SAT reported the
            # first complete (and sometimes role-wrong) roster as OPTIMAL.
            # Keep the hint as an incumbent and search the real model.  With a
            # zero-backup incumbent the mathematical lower bound closes the
            # stage immediately; a positive value still needs a real proof.
            fix_hints=False,
            disable_presolve=common.complete_coverage_hint,
        )
        all_common_stages_optimal = self._require_optimal(
            common_solver, common_status, snapshot, "UNFILLED"
        )
        minimum_unfilled = int(common_solver.value(common.metrics["UNFILLED"]))
        minimum_role_backup_penalty = int(
            common_solver.value(common.metrics["ROLE_BACKUP_PENALTY"])
        )
        # Complete coverage alone does not prove that a BACKUP assignment was
        # necessary.  A zero backup penalty is a mathematical lower bound; a
        # positive value may be frozen for every strategy only after CP-SAT has
        # proved the combined coverage/role-priority objective optimal.  This
        # remains an objective (never a hard ban), so BACKUP can still repair a
        # real STANDARD shortage without creating avoidable vacancies.
        if (
            minimum_role_backup_penalty > 0
            and common_status != cp_model.OPTIMAL
        ):
            raise OptimizationIncomplete(
                "ROLE_BACKUP_PENALTY_UNPROVEN: solver nie potwierdził, że "
                "użycie roli dodatkowej jest konieczne przy najlepszym "
                "pokryciu obsady"
            )
        raw_common_bound = self._solver_measure(
            common_solver, "best_objective_bound"
        )
        solver_coverage_lower_bound = (
            max(
                0,
                math.floor(
                    float(raw_common_bound) / role_priority_multiplier + 1e-7
                ),
            )
            if raw_common_bound is not None
            and math.isfinite(float(raw_common_bound))
            else 0
        )
        proven_coverage_lower_bound = (
            max(
                certificate.lower_bound if certificate is not None else 0,
                solver_coverage_lower_bound,
            )
        )
        coverage_minimum_proven = coverage_minimum_is_proven(
            minimum_unfilled,
            proven_coverage_lower_bound,
            common_status,
        )
        # A vacancy is a business claim. Never publish one when CP-SAT's own
        # lower bound says that a better-covered roster may still exist. This
        # exact condition caused UAT runs for BAR/PIZZABAR/KUCHNIA/ZMYWAK to
        # expose 1-3 vacancies although the recorded coverage bound was zero
        # and a leader could immediately fill the same seat without an
        # override. A non-optimal complete roster remains acceptable (there is
        # no better coverage than zero); an unexplained incomplete roster does
        # not.
        if minimum_unfilled > 0 and not coverage_minimum_proven:
            raise OptimizationIncomplete(
                "UNFILLED_NOT_PROVEN: silnik nie zakończył minimalizacji "
                f"braków (znaleziono {minimum_unfilled}, potwierdzona dolna "
                f"granica {proven_coverage_lower_bound}). Uruchom generowanie "
                "ponownie albo ułóż grafik w Studio; ten wynik nie zostanie "
                "pokazany jako rzeczywisty niedobór zespołu."
            )

        # Coverage has now been proved (or a complete zero-vacancy incumbent is
        # itself the proof) and the minimum use of BACKUP roles is fixed.  Before
        # expanding that roster into the expensive pay/strategy model, improve
        # the shared assignment on the small hard-constraint model by maximizing
        # the least realized attainable target.  This is a seed, not a hidden
        # business optimum: every strategy still performs its own auditable
        # lexicographic stages, but it no longer starts from an arbitrary
        # coverage-only roster that can give one person 10 h and another 180 h.
        common_hint_solver = common_solver
        fair_coverage_seed_status: str | None = None
        fair_coverage_seed_budget = 0.0
        fair_coverage_spread_status: str | None = None
        fair_coverage_spread_budget = 0.0
        fair_coverage_seed_minimum = int(
            common_solver.value(
                common.metrics["MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS"]
            )
        )
        if (
            not snapshot.settings.require_optimal
            and any(
                strategy.code.upper() == "PREFERENCES"
                for strategy in snapshot.strategies
            )
            and common.metric_bounds[
                "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS"
            ]
            > 0
        ):
            common.model.add(common.metrics["UNFILLED"] == minimum_unfilled)
            common.model.add(
                common.metrics["ROLE_BACKUP_PENALTY"]
                == minimum_role_backup_penalty
            )
            common.model.clear_objective()
            self._replace_with_nonzero_solution_hints(
                common.model,
                common_solver,
                common.hint_variables,
            )
            common.model.minimize(
                common.metrics[
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS"
                ]
            )
            remaining_for_seed = self._remaining_seconds(
                global_deadline, "GLOBAL:FAIR_COVERAGE_SEED:BUDGET"
            )
            configured_preference_budgets = [
                float(strategy.time_limit_seconds)
                for strategy in snapshot.strategies
                if strategy.code.upper() == "PREFERENCES"
                and strategy.time_limit_seconds is not None
            ]
            preferred_seed_ceiling = (
                max(configured_preference_budgets) * 0.5
                if configured_preference_budgets
                else remaining_for_seed * 0.2
            )
            fair_coverage_seed_budget = max(
                0.001,
                min(
                    remaining_for_seed * 0.2,
                    max(15.0, min(120.0, preferred_seed_ceiling)),
                ),
            )
            fair_seed_solver, fair_seed_status = self._solve_model(
                common.model,
                snapshot,
                strategy=None,
                stage_name="FAIR_COVERAGE_SEED",
                time_limit_seconds=fair_coverage_seed_budget,
            )
            if fair_seed_status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
                candidate_minimum = int(
                    fair_seed_solver.value(
                        common.metrics[
                            "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS"
                        ]
                    )
                )
                if candidate_minimum >= fair_coverage_seed_minimum:
                    common_hint_solver = fair_seed_solver
                    fair_coverage_seed_minimum = candidate_minimum
                    fair_coverage_seed_status = fair_seed_solver.status_name(
                        fair_seed_status
                    )
            LOGGER.info(
                "Fair coverage seed status=%s minimumAchievableUtilizationBps=%s "
                "timeBudgetSeconds=%.3f",
                fair_coverage_seed_status,
                fair_coverage_seed_minimum,
                fair_coverage_seed_budget,
            )
            if fair_coverage_seed_status is not None:
                # Strict second lexicographic step: keep the best minimum and
                # then lower the maximum utilization.  With fixed coverage this
                # distributes all remaining work instead of allowing the first
                # constrained employee to define the minimum while somebody
                # else remains close to 100%.
                common.model.add(
                    common.metrics["MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS"]
                    >= fair_coverage_seed_minimum
                )
                common.model.clear_objective()
                self._replace_with_nonzero_solution_hints(
                    common.model,
                    common_hint_solver,
                    common.hint_variables,
                )
                common.model.minimize(
                    common.metrics["ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"]
                )
                remaining_for_spread = self._remaining_seconds(
                    global_deadline, "GLOBAL:FAIR_COVERAGE_SPREAD:BUDGET"
                )
                preferred_spread_ceiling = (
                    max(configured_preference_budgets) * 0.3
                    if configured_preference_budgets
                    else remaining_for_spread * 0.15
                )
                fair_coverage_spread_budget = max(
                    0.001,
                    min(
                        remaining_for_spread * 0.15,
                        max(10.0, min(60.0, preferred_spread_ceiling)),
                    ),
                )
                spread_solver, spread_status = self._solve_model(
                    common.model,
                    snapshot,
                    strategy=None,
                    stage_name="FAIR_COVERAGE_SPREAD",
                    time_limit_seconds=fair_coverage_spread_budget,
                )
                if spread_status in (cp_model.FEASIBLE, cp_model.OPTIMAL):
                    common_hint_solver = spread_solver
                    fair_coverage_spread_status = spread_solver.status_name(
                        spread_status
                    )
                LOGGER.info(
                    "Fair coverage spread status=%s spreadBps=%s "
                    "timeBudgetSeconds=%.3f",
                    fair_coverage_spread_status,
                    int(
                        common_hint_solver.value(
                            common.metrics[
                                "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
                            ]
                        )
                    ),
                    fair_coverage_spread_budget,
                )
        fair_coverage_seed_spread = int(
            common_hint_solver.value(
                common.metrics["ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"]
            )
        )
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
        # Cost-first is solved last in normal comparison mode. This lets it use
        # every already verified complete roster as a price ceiling; a card
        # labelled "Minimalny koszt" can therefore never be more expensive than
        # another displayed variant merely because its own time limit expired.
        # The decision is derived from Matrix objective tiers, never a mutable
        # strategy code or label.
        ordered_strategies = sorted(
            snapshot.strategies,
            key=lambda item: (
                1 if self._cost_precedes_other_goals(item) else 0,
                item.sort_order,
                item.id,
            ),
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
            warm_artifacts.model.add(
                warm_artifacts.metrics["ROLE_BACKUP_PENALTY"]
                == minimum_role_backup_penalty
            )
            self._apply_coverage_solution_hint(
                common,
                common_hint_solver,
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
                # The coverage incumbent already fixes one selected employee (or
                # the vacancy variable) for every seat.  Treat those sparse
                # positive hints as fixed here: the seat equalities force all
                # competing assignment variables to zero, while the remaining
                # pay/budget variables are evaluated from that roster.  This
                # avoids an unbounded presolve pass on a large monthly model;
                # CP-SAT's search timer does not reliably interrupt that pass.
                fix_hints=True,
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
        # A relaxed monthly solve can finish a later strategy with a weaker
        # incumbent than one already found for the same snapshot. That is
        # especially misleading for a Matrix-defined fairness-first strategy:
        # it could show a worse load spread only because its time limit expired.
        # Keep the best verified fairness incumbent as a feasible guard for
        # later strategies whose Matrix tiers put fairness ahead of cost.
        best_fairness_seed_solver: Any | None = None
        best_fairness_key: tuple[int, int, int] | None = None
        best_fairness_bounds: dict[str, int] = {}
        best_cost_seed_solver: Any | None = None
        best_cost_value: int | None = None

        for strategy_index, strategy in enumerate(ordered_strategies):
            if self._cancel_event.is_set():
                raise OptimizationCancelled("Optimization was cancelled")
            self._ensure_deadline(global_deadline, "GLOBAL")
            artifacts = replace(
                strategy_base,
                model=strategy_base.model.clone(),
            )
            strategy_started = self._clock()
            # The Matrix value is the authoritative per-strategy ceiling. Split
            # the remaining worker budget fairly between strategies so an early
            # variant cannot starve a later one, but never replace the configured
            # value with a hidden hard-coded cap.
            remaining_strategy_count = strategy_count - strategy_index
            remaining_strategy_budget = self._remaining_seconds(
                global_deadline,
                f"{strategy.code}:BUDGET",
            )
            fair_strategy_share = (
                remaining_strategy_budget / max(1, remaining_strategy_count)
            )
            configured_strategy_budget = (
                strategy.time_limit_seconds
                if strategy.time_limit_seconds is not None
                else fair_strategy_share
            )
            # In normal planning mode every variant receives a fair slice so an
            # early strategy cannot starve the comparison.  Audit mode has a
            # different contract: every completed strategy must be proven
            # optimal, therefore it may consume the remaining global budget and
            # the run fails explicitly if the proof cannot be completed.
            strategy_budget = min(
                float(configured_strategy_budget),
                (
                    remaining_strategy_budget
                    if snapshot.settings.require_optimal
                    else fair_strategy_share
                ),
            )
            strategy_deadline = min(
                global_deadline,
                strategy_started + strategy_budget,
            )
            self._ensure_deadline(strategy_deadline, strategy.code)
            artifacts.model.add(artifacts.metrics["UNFILLED"] == minimum_unfilled)
            artifacts.model.add(
                artifacts.metrics["ROLE_BACKUP_PENALTY"]
                == minimum_role_backup_penalty
            )
            coverage_hint_count = self._apply_coverage_solution_hint(
                common, common_hint_solver, artifacts, slots
            )
            LOGGER.info(
                "Strategy %s seeded with %s coverage hint values",
                strategy.code,
                coverage_hint_count,
            )
            preference_fairness_strategy = strategy.code.upper() == "PREFERENCES"

            def effective_objective_tier(metric_name: str, configured_tier: int) -> int:
                """Keep the PREFERENCES promise safe from stale Matrix ordering."""
                if not preference_fairness_strategy:
                    return configured_tier
                return {
                    "UNFILLED": 1,
                    "ROLE_LOAD_FAIRNESS_SCORE": 2,
                    "LOAD_UTILIZATION_SPREAD_BPS": 2,
                    "NOMINAL_DEVIATION_MINUTES": 3,
                    "PREFERENCE_VIOLATIONS": 4,
                    "ROLE_WEEKEND_FAIRNESS_SCORE": 5,
                    "WEEKEND_SPREAD": 5,
                    "TOTAL_COST": 6,
                    "HOME_LOCATION_VIOLATIONS": 6,
                    "OVERTIME_MINUTES": 7,
                    "BASELINE_CHANGES": 7,
                    "BUDGET_TARGET_EXCESS": 8,
                }.get(metric_name, max(9, configured_tier))

            active_metric_tiers: dict[str, list[int]] = defaultdict(list)
            for objective_term in strategy.objective_terms:
                if objective_term.weight == 0:
                    continue
                metric_name = METRIC_ALIASES.get(
                    objective_term.metric, objective_term.metric
                )
                active_metric_tiers[metric_name].append(
                    effective_objective_tier(metric_name, objective_term.tier)
                )
            fairness_tiers = [
                tier
                for metric_name in (
                    "ROLE_LOAD_FAIRNESS_SCORE",
                    "LOAD_UTILIZATION_SPREAD_BPS",
                    "NOMINAL_DEVIATION_MINUTES",
                )
                for tier in active_metric_tiers.get(metric_name, [])
            ]
            cost_tiers = active_metric_tiers.get("TOTAL_COST", [])
            fairness_first = bool(fairness_tiers) and (
                not cost_tiers or min(fairness_tiers) < min(cost_tiers)
            )
            cost_first = self._cost_precedes_other_goals(strategy)
            applied_fairness_bounds: dict[str, int] = {}
            if fairness_first and best_fairness_seed_solver is not None:
                for metric_name in (
                    "ROLE_LOAD_FAIRNESS_SCORE",
                    "LOAD_UTILIZATION_SPREAD_BPS",
                    "NOMINAL_DEVIATION_MINUTES",
                ):
                    if (
                        metric_name in active_metric_tiers
                        and metric_name in best_fairness_bounds
                    ):
                        bound = best_fairness_bounds[metric_name]
                        artifacts.model.add(artifacts.metrics[metric_name] <= bound)
                        applied_fairness_bounds[metric_name] = bound
                LOGGER.info(
                    "Strategy %s received Matrix-driven fairness guards %s",
                    strategy.code,
                    applied_fairness_bounds,
                )
            applied_cost_bound: int | None = None
            if cost_first and best_cost_seed_solver is not None and best_cost_value is not None:
                artifacts.model.add(artifacts.metrics["TOTAL_COST"] <= best_cost_value)
                applied_cost_bound = best_cost_value
                LOGGER.info(
                    "Strategy %s received verified comparison cost guard %s",
                    strategy.code,
                    applied_cost_bound,
                )
            stage_results: list[dict[str, Any]] = [
                {
                    "tier": 0,
                    "name": "UNFILLED",
                    "value": minimum_unfilled,
                    "status": common_solver.status_name(common_status),
                    "tolerance": 0,
                    "frozenUpperBound": minimum_unfilled,
                    "roleBackupPenalty": minimum_role_backup_penalty,
                    "fairCoverageSeedMinimumAchievableUtilizationBps": (
                        fair_coverage_seed_minimum
                    ),
                    "fairCoverageSeedAchievableUtilizationSpreadBps": (
                        fair_coverage_seed_spread
                    ),
                    **(
                        {
                            "fairCoverageSeedStatus": fair_coverage_seed_status,
                            "fairCoverageSeedTimeBudgetSeconds": round(
                                fair_coverage_seed_budget, 3
                            ),
                        }
                        if fair_coverage_seed_status is not None
                        else {}
                    ),
                    **(
                        {
                            "fairCoverageSpreadStatus": fair_coverage_spread_status,
                            "fairCoverageSpreadTimeBudgetSeconds": round(
                                fair_coverage_spread_budget, 3
                            ),
                        }
                        if fair_coverage_spread_status is not None
                        else {}
                    ),
                    **(
                        {"fairnessIncumbentGuard": dict(applied_fairness_bounds)}
                        if applied_fairness_bounds
                        else {}
                    ),
                    **(
                        {"costIncumbentGuard": applied_cost_bound}
                        if applied_cost_bound is not None
                        else {}
                    ),
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
                seed_solver = (
                    best_cost_seed_solver
                    if cost_first and best_cost_seed_solver is not None
                    else best_fairness_seed_solver
                    if fairness_first and best_fairness_seed_solver is not None
                    else shared_warm_start_solver
                )
                nonzero_hint_count = self._replace_with_nonzero_solution_hints(
                    artifacts.model,
                    seed_solver,
                    full_variables,
                )
                LOGGER.info(
                    "Strategy %s reused a sparse %s-variable full-model warm start",
                    strategy.code,
                    nonzero_hint_count,
                )
                feasible_fallback_solver = seed_solver

            # Overtime is a product-level gate, not a configurable strategy
            # preference.  Once the best possible coverage has been frozen,
            # every strategy must first minimize overtime and only then apply
            # its Matrix-defined cost, preference and fairness tiers.  Without
            # this gate a cost-first strategy could deliberately overload the
            # cheapest employee even when another eligible employee could cover
            # the same slot inside their nominal time.
            overtime_expression = artifacts.metrics["OVERTIME_MINUTES"]
            overtime_bound = artifacts.metric_bounds["OVERTIME_MINUTES"]
            if overtime_bound > 0:
                configured_tier_count = len(
                    {
                        term.tier
                        for term in strategy.objective_terms
                        if term.weight != 0
                    }
                )
                fallback_overtime = (
                    None
                    if feasible_fallback_solver is None
                    else int(
                        feasible_fallback_solver.value(
                            artifacts.metrics["OVERTIME_MINUTES"]
                        )
                    )
                )
                overtime_solver = feasible_fallback_solver
                overtime_status = cp_model.OPTIMAL if fallback_overtime == 0 else None
                overtime_value = 0 if fallback_overtime == 0 else None
                used_overtime_fallback = False
                overtime_time_budget = 0.0

                if overtime_value is None:
                    artifacts.model.clear_objective()
                    artifacts.model.minimize(overtime_expression)
                    remaining_overtime_budget = self._remaining_seconds(
                        strategy_deadline, f"{strategy.code}:OVERTIME_GATE:BUDGET"
                    )
                    if snapshot.settings.require_optimal:
                        overtime_time_budget = remaining_overtime_budget
                    else:
                        usable_overtime_budget = max(
                            0.001,
                            remaining_overtime_budget
                            - (
                                RELAXED_STRATEGY_FINAL_RESERVE_SECONDS
                                if feasible_fallback_solver is not None
                                else 0.0
                            ),
                        )
                        overtime_time_budget = max(
                            0.001,
                            usable_overtime_budget
                            / max(1, configured_tier_count + 1),
                        )
                    overtime_solver, overtime_status = self._solve_model(
                        artifacts.model,
                        snapshot,
                        strategy=strategy,
                        stage_name="OVERTIME_GATE",
                        time_limit_seconds=overtime_time_budget,
                        disable_presolve=(
                            not snapshot.settings.require_optimal
                            and feasible_fallback_solver is not None
                        ),
                    )
                    if (
                        overtime_status == cp_model.UNKNOWN
                        and feasible_fallback_solver is not None
                    ):
                        LOGGER.warning(
                            "Strategy %s overtime gate ended UNKNOWN; using the "
                            "verified full-model warm start/incumbent",
                            strategy.code,
                        )
                        overtime_solver = feasible_fallback_solver
                        overtime_status = cp_model.FEASIBLE
                        used_overtime_fallback = True
                    assert overtime_solver is not None and overtime_status is not None
                    overtime_value = int(overtime_solver.value(overtime_expression))
                    # Zero is the mathematical lower bound, even when CP-SAT
                    # returns FEASIBLE at the time boundary before promoting the
                    # status to OPTIMAL.
                    overtime_optimal = (
                        overtime_value == 0 or overtime_status == cp_model.OPTIMAL
                    )
                    if not overtime_optimal:
                        self._require_optimal(
                            overtime_solver,
                            overtime_status,
                            snapshot,
                            f"{strategy.code}:OVERTIME_GATE",
                        )
                    all_stages_optimal &= overtime_optimal
                    incumbent = {
                        variable.index: int(overtime_solver.value(variable))
                        for variable in artifacts.hint_variables
                    }
                    feasible_fallback_solver = overtime_solver

                assert overtime_value is not None
                artifacts.model.add(overtime_expression <= overtime_value)
                stage_results[0].update(
                    {
                        "overtimeMinimum": overtime_value,
                        "overtimeStatus": (
                            "OPTIMAL"
                            if overtime_value == 0
                            else overtime_solver.status_name(overtime_status)
                        ),
                        "overtimeFrozenUpperBound": overtime_value,
                        **(
                            {"overtimeTimeBudgetSeconds": round(overtime_time_budget, 3)}
                            if overtime_time_budget > 0
                            else {"overtimeVerifiedZeroIncumbent": True}
                        ),
                        **(
                            {"overtimeUsedFallback": True}
                            if used_overtime_fallback
                            else {}
                        ),
                    }
                )

            tiers: dict[int, list[Any]] = defaultdict(list)
            tier_tolerances: dict[int, int] = defaultdict(int)
            tier_upper_bounds: dict[int, int] = defaultdict(int)
            tier_terms: dict[int, list[dict[str, Any]]] = defaultdict(list)
            for term_index, term in enumerate(strategy.objective_terms):
                metric_name = METRIC_ALIASES.get(term.metric, term.metric)
                effective_tier = effective_objective_tier(metric_name, term.tier)
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
                tier_upper_bounds[effective_tier] += (
                    normalization_coefficient * expression_bound
                )
                tier_tolerances[effective_tier] += (
                    normalization_coefficient * term.tolerance
                )
                if (
                    tier_upper_bounds[effective_tier]
                    + tier_tolerances[effective_tier]
                    > SAFE_CP_SAT_INTEGER
                ):
                    raise SnapshotError(
                        f"Strategy {strategy.id} tier {effective_tier} exceeds the "
                        "safe CP-SAT integer range"
                    )
                tiers[effective_tier].append(
                    sign * normalization_coefficient * metric_expression
                )
                tier_terms[effective_tier].append(
                    {
                        "metric": metric_name,
                        "direction": term.direction,
                        "weight": term.weight,
                        "tolerance": term.tolerance,
                        "parameters": dict(term.parameters),
                        "normalizationCoefficient": normalization_coefficient,
                        "metricUpperBound": raw_expression_bound,
                        **(
                            {"configuredTier": term.tier}
                            if effective_tier != term.tier
                            else {}
                        ),
                    }
                )

            # This guard is intentionally outside editable Matrix strategy
            # terms. Coverage and overtime remain earlier hard product gates;
            # every displayed strategy must then protect target employees from
            # unjustified zero hours and extreme category-wide utilization
            # spread before pursuing cost, preference or presentation-specific
            # fairness objectives.
            # Tier 0 is reserved for this product-wide gate.  The gateway
            # contract accepts objective tiers only in the 0..100000 range;
            # using a negative synthetic tier made an otherwise valid SALA
            # result fail only when the worker tried to persist it.
            # Keep the zero-hour decision as its own first search stage.  The
            # previous single weighted expression mixed zero-hour employees,
            # minimum utilization and all role/location spreads.  On the real
            # monthly SALA model that search exhausted its short budget before
            # it improved the warm start, then the relaxed-mode fallback froze
            # four employees at 0 h as a valid FEASIBLE result.  A dedicated
            # stage is both much smaller and auditable: zero is a mathematical
            # optimum; a positive value may only be accepted with an OPTIMAL
            # certificate proving that hard constraints make it unavoidable.
            zero_hour_guard_tier = -3
            if artifacts.metric_bounds["ZERO_TARGET_EMPLOYEE_COUNT"] > 0:
                tiers[zero_hour_guard_tier].append(
                    artifacts.metrics["ZERO_TARGET_EMPLOYEE_COUNT"]
                )
                tier_upper_bounds[zero_hour_guard_tier] = artifacts.metric_bounds[
                    "ZERO_TARGET_EMPLOYEE_COUNT"
                ]
                tier_tolerances[zero_hour_guard_tier] = 0
                tier_terms[zero_hour_guard_tier].append(
                    {
                        "metric": "ZERO_TARGET_EMPLOYEE_COUNT",
                        "direction": "MIN",
                        "weight": 1,
                        "tolerance": 0,
                        "parameters": {},
                        "normalizationCoefficient": 1,
                        "metricUpperBound": artifacts.metric_bounds[
                            "ZERO_TARGET_EMPLOYEE_COUNT"
                        ],
                    }
                )

            # A primary/ordinary role is not cancelled by hours assigned in a
            # different role.  In particular, a KELNER who can additionally
            # cover HOST as BACKUP must still receive a KELNER assignment when
            # that is feasible.  Keep this as a separate exact stage so a
            # positive value is accepted only with a proof that hard rules make
            # it unavoidable; BACKUP-only grants never participate.
            primary_role_guard_tier = -2
            primary_role_guard_metric = "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"
            primary_role_guard_bound = artifacts.metric_bounds[
                primary_role_guard_metric
            ]
            if primary_role_guard_bound > 0:
                tiers[primary_role_guard_tier].append(
                    artifacts.metrics[primary_role_guard_metric]
                )
                tier_upper_bounds[primary_role_guard_tier] = (
                    primary_role_guard_bound
                )
                tier_tolerances[primary_role_guard_tier] = 0
                tier_terms[primary_role_guard_tier].append(
                    {
                        "metric": primary_role_guard_metric,
                        "direction": "MIN",
                        "weight": 1,
                        "tolerance": 0,
                        "parameters": {},
                        "normalizationCoefficient": 1,
                        "metricUpperBound": primary_role_guard_bound,
                    }
                )

            # Negative values are internal ordering keys only.  Persisted
            # objective tiers remain non-negative for the gateway contract.
            guard_tier = -1
            guard_metric = (
                "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS"
                if preference_fairness_strategy
                else "COMMON_FAIRNESS_GUARD_SCORE"
            )
            guard_bound = artifacts.metric_bounds[guard_metric]
            if guard_bound > 0:
                tiers[guard_tier].append(artifacts.metrics[guard_metric])
                tier_upper_bounds[guard_tier] = guard_bound
                tier_tolerances[guard_tier] = 0
                tier_terms[guard_tier].append(
                    {
                        "metric": guard_metric,
                        "direction": "MIN",
                        "weight": 1,
                        "tolerance": 0,
                        # The gateway only permits the public objective
                        # parameter `targetValue`; the metric name itself is
                        # the durable audit identifier for this product gate.
                        "parameters": {},
                        "normalizationCoefficient": 1,
                        "metricUpperBound": guard_bound,
                    }
                )

            spread_guard_tier = 0
            spread_guard_metric = "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
            spread_guard_bound = artifacts.metric_bounds[spread_guard_metric]
            if preference_fairness_strategy and spread_guard_bound > 0:
                tiers[spread_guard_tier].append(
                    artifacts.metrics[spread_guard_metric]
                )
                tier_upper_bounds[spread_guard_tier] = spread_guard_bound
                tier_tolerances[spread_guard_tier] = 0
                tier_terms[spread_guard_tier].append(
                    {
                        "metric": spread_guard_metric,
                        "direction": "MIN",
                        "weight": 1,
                        "tolerance": 0,
                        "parameters": {},
                        "normalizationCoefficient": 1,
                        "metricUpperBound": spread_guard_bound,
                    }
                )

            def stage_name(tier: int) -> str:
                if tier == zero_hour_guard_tier:
                    return "ZERO_HOUR_GUARD"
                if tier == primary_role_guard_tier:
                    return "PRIMARY_ROLE_GUARD"
                if tier == guard_tier:
                    return "COMMON_FAIRNESS_GUARD"
                if tier == spread_guard_tier:
                    return "ACHIEVABLE_TARGET_SPREAD_GUARD"
                return f"TIER_{tier}"

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
                    disable_presolve=(
                        not snapshot.settings.require_optimal
                        and feasible_fallback_solver is not None
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
                    certified_tier_value: int | None = None
                    if preference_fairness_strategy and feasible_fallback_solver is not None:
                        if tier == guard_tier and fair_coverage_seed_status == "OPTIMAL":
                            candidate = 1000 - fair_coverage_seed_minimum
                            if int(
                                feasible_fallback_solver.value(
                                    artifacts.metrics[guard_metric]
                                )
                            ) == candidate:
                                certified_tier_value = candidate
                        elif (
                            tier == spread_guard_tier
                            and fair_coverage_spread_status == "OPTIMAL"
                            and int(
                                feasible_fallback_solver.value(
                                    artifacts.metrics[
                                        "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS"
                                    ]
                                )
                            )
                            >= fair_coverage_seed_minimum
                            and int(
                                feasible_fallback_solver.value(
                                    artifacts.metrics[spread_guard_metric]
                                )
                            )
                            == fair_coverage_seed_spread
                        ):
                            certified_tier_value = fair_coverage_seed_spread
                    if certified_tier_value is not None:
                        allowed_degradation = tier_tolerances[tier]
                        stage_results.append(
                            {
                                "tier": 0 if tier < 0 else tier,
                                "name": stage_name(tier),
                                "value": certified_tier_value,
                                "status": "OPTIMAL",
                                "bestBound": float(certified_tier_value),
                                "tolerance": allowed_degradation,
                                "frozenUpperBound": (
                                    certified_tier_value + allowed_degradation
                                ),
                                "terms": tier_terms[tier],
                                "certifiedCoverageSeed": True,
                            }
                        )
                        artifacts.model.add(
                            expression
                            <= certified_tier_value + allowed_degradation
                        )
                        self._emit_progress(
                            phase=f"TIER_{tier}",
                            progress=10
                            + (
                                80
                                * (
                                    strategy_index * len(ordered_tiers)
                                    + tier_index
                                )
                                // (strategy_count * len(ordered_tiers))
                            ),
                            strategyId=strategy.id,
                            strategyProgress=(90 * tier_index // len(ordered_tiers)),
                            strategyCount=strategy_count,
                            completedStrategies=strategy_index,
                        )
                        continue
                    # Every supported business metric is non-negative. If the
                    # verified Matrix-compatible incumbent already reaches zero
                    # for an all-minimization tier, zero is a mathematical lower
                    # bound and there is nothing left to prove. Freezing it here
                    # preserves the exact business result and gives later tiers
                    # (notably workload fairness) their configured solve time.
                    incumbent_zero_tier = (
                        feasible_fallback_solver is not None
                        and all(
                            term["direction"] == "MIN"
                            and "targetValue" not in term["parameters"]
                            for term in tier_terms[tier]
                        )
                        and self._normalized_tier_value(
                            feasible_fallback_solver,
                            artifacts,
                            tier_terms[tier],
                        )
                        == 0
                    )
                    if incumbent_zero_tier:
                        allowed_degradation = tier_tolerances[tier]
                        stage_results.append(
                            {
                                "tier": 0 if tier < 0 else tier,
                                "name": stage_name(tier),
                                "value": 0,
                                "status": "OPTIMAL",
                                "bestBound": 0.0,
                                "tolerance": allowed_degradation,
                                "frozenUpperBound": allowed_degradation,
                                "terms": tier_terms[tier],
                                "verifiedZeroIncumbent": True,
                            }
                        )
                        artifacts.model.add(expression <= allowed_degradation)
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
                                "tier": 0 if tier < 0 else tier,
                                "name": stage_name(tier),
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
                    remaining_tier_count = len(ordered_tiers) - tier_index + 1
                    remaining_tier_budget = self._remaining_seconds(
                        strategy_deadline,
                        f"{strategy.code}:TIER_{tier}:BUDGET",
                    )
                    if snapshot.settings.require_optimal:
                        tier_time_budget = remaining_tier_budget
                    else:
                        # In comparison mode every remaining business tier must
                        # receive solver time.  Giving the first non-trivial tier
                        # the whole remaining budget made later objectives (most
                        # visibly the promised fair workload distribution) fall
                        # back to the shared feasibility roster, so all three
                        # strategy cards could be identical.  Split only the
                        # currently available time; an early proof automatically
                        # leaves its unused share for the following tiers.
                        usable_tier_budget = max(
                            0.001,
                            remaining_tier_budget
                            - (
                                RELAXED_STRATEGY_FINAL_RESERVE_SECONDS
                                if feasible_fallback_solver is not None
                                else 0.0
                            ),
                        )
                        tier_time_budget = max(
                            0.001,
                            usable_tier_budget / max(1, remaining_tier_count),
                        )
                        if preference_fairness_strategy and tier == guard_tier:
                            # The large monthly model needs materially more than
                            # an equal per-tier slice to improve max-min fairness.
                            # Reserve 40% for all later goals (including actual
                            # preferences), but give the defining fairness gate
                            # the majority share.  This affects PREFERENCES only.
                            tier_time_budget = max(
                                tier_time_budget,
                                min(
                                    usable_tier_budget,
                                    max(0.001, strategy_budget * 0.60),
                                ),
                            )
                        elif preference_fairness_strategy and tier == 2:
                            tier_time_budget = max(
                                tier_time_budget,
                                min(
                                    usable_tier_budget,
                                    max(0.001, strategy_budget * 0.60),
                                ),
                            )
                        if tier in (
                            zero_hour_guard_tier,
                            primary_role_guard_tier,
                            guard_tier,
                            spread_guard_tier,
                        ) and not (
                            preference_fairness_strategy
                            and tier in (guard_tier, spread_guard_tier)
                        ):
                            tier_time_budget = min(
                                tier_time_budget,
                                MAX_RELAXED_COMMON_FAIRNESS_SECONDS,
                            )
                    final_solver, final_status = self._solve_model(
                        artifacts.model,
                        snapshot,
                        strategy=strategy,
                        stage_name=f"TIER_{tier}",
                        time_limit_seconds=tier_time_budget,
                        # A verified full-model incumbent already exists in
                        # relaxed planning mode.  On large monthly instances
                        # CP-SAT presolve can run past max_time_in_seconds and
                        # consume the shared deadline before the next strategy
                        # receives any time.  Search the hinted model directly;
                        # UNKNOWN still falls back to the verified incumbent.
                        disable_presolve=(
                            not snapshot.settings.require_optimal
                            and feasible_fallback_solver is not None
                            and tier
                            not in (zero_hour_guard_tier, primary_role_guard_tier)
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
                    if (
                        tier in (zero_hour_guard_tier, primary_role_guard_tier)
                        and exact_value > 0
                        and final_status != cp_model.OPTIMAL
                    ):
                        raise OptimizationIncomplete(
                            f"{strategy.code}:{stage_name(tier)}_UNPROVEN:"
                            f"{exact_value}"
                        )
                    allowed_degradation = tier_tolerances[tier]
                    incumbent = {
                        variable.index: int(final_solver.value(variable))
                        for variable in artifacts.hint_variables
                    }
                    feasible_fallback_solver = final_solver
                    stage_results.append(
                        {
                            "tier": 0 if tier < 0 else tier,
                            "name": stage_name(tier),
                            "value": exact_value,
                            "status": final_solver.status_name(final_status),
                            **(
                                {}
                                if used_fallback
                                else {"bestBound": final_solver.best_objective_bound}
                            ),
                            "tolerance": allowed_degradation,
                            "frozenUpperBound": exact_value + allowed_degradation,
                            "timeBudgetSeconds": round(tier_time_budget, 3),
                            "terms": tier_terms[tier],
                            **(
                                {"verifiedZeroIncumbent": True}
                                if exact_value == 0
                                and final_status == cp_model.OPTIMAL
                                else {}
                            ),
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

            # A zero-valued tier can be frozen from the verified incumbent
            # without another CP-SAT call.  When every configured tier follows
            # that fast path, the incumbent is also the final roster.
            if final_solver is None and feasible_fallback_solver is not None:
                final_solver = feasible_fallback_solver
                final_status = (
                    cp_model.OPTIMAL if all_stages_optimal else cp_model.FEASIBLE
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
                        disable_presolve=True,
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
                            final_solver = diversity_solver
                            final_status = diversity_status
                            owner = None
            if owner is not None:
                result = replace(result, equivalent_to_strategy_id=owner)
            else:
                solution_owners[result.solution_hash] = strategy.id
            fairness_key = (
                int(result.metrics.get("ROLE_LOAD_FAIRNESS_SCORE", 0)),
                int(result.metrics.get("LOAD_UTILIZATION_SPREAD_BPS", 0)),
                int(result.metrics.get("NOMINAL_DEVIATION_MINUTES", 0)),
            )
            if best_fairness_key is None or fairness_key < best_fairness_key:
                best_fairness_key = fairness_key
                best_fairness_seed_solver = final_solver
                best_fairness_bounds = {
                    "ROLE_LOAD_FAIRNESS_SCORE": fairness_key[0],
                    "LOAD_UTILIZATION_SPREAD_BPS": fairness_key[1],
                    "NOMINAL_DEVIATION_MINUTES": fairness_key[2],
                }
            result_cost = int(result.metrics.get("TOTAL_COST", 0))
            if best_cost_value is None or result_cost < best_cost_value:
                best_cost_value = result_cost
                best_cost_seed_solver = final_solver
            results.append(result)
            if self._result_callback is not None:
                # Persist progress for worker lease recovery. A later global
                # comparison audit can still fail the run; incomplete runs are
                # never presented as ready variants.
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
        # A card is a business promise, not merely the last incumbent produced
        # before a timer expired.  In the strict mathematical-audit mode an
        # objectively dominated strategy is therefore still a hard failure.
        # Ordinary planning is intentionally different: the leader must receive
        # every technically valid incumbent that was found, even when a time-
        # limited strategy did not beat another card on its own active goals.
        # Rejecting the whole run here made a usable BAR schedule disappear and
        # blocked the operational workflow.  The UI can compare the persisted
        # metrics; only an explicitly requested proof mode may reject them.
        strategies_by_id = {
            strategy.id: strategy for strategy in ordered_strategies
        }
        for result in results:
            strategy = strategies_by_id[result.strategy_id]
            for candidate in results:
                if candidate.strategy_id == result.strategy_id:
                    continue
                if (
                    snapshot.settings.require_optimal
                    and self._dominates_for_strategy(candidate, result, strategy)
                ):
                    candidate_strategy = strategies_by_id[candidate.strategy_id]
                    raise OptimizationIncomplete(
                        "STRATEGY_RESULT_DOMINATED: wariant "
                        f"{strategy.code} jest gorszy we wszystkich swoich "
                        "aktywnych celach od wariantu "
                        f"{candidate_strategy.code}. Silnik nie opublikuje "
                        "mylącego porównania."
                    )
        return tuple(results)

    @staticmethod
    def _dominates_for_strategy(
        candidate: VariantResult,
        incumbent: VariantResult,
        strategy: Any,
    ) -> bool:
        strictly_better = False
        comparable = False
        for term in strategy.objective_terms:
            if term.weight == 0:
                continue
            metric_name = METRIC_ALIASES.get(term.metric, term.metric)
            if (
                metric_name not in candidate.metrics
                or metric_name not in incumbent.metrics
            ):
                return False
            candidate_value = int(candidate.metrics[metric_name])
            incumbent_value = int(incumbent.metrics[metric_name])
            target = term.parameters.get("targetValue")
            if target is not None:
                candidate_value = abs(candidate_value - int(target))
                incumbent_value = abs(incumbent_value - int(target))
            comparable = True
            if term.direction == "MIN":
                if candidate_value > incumbent_value:
                    return False
                strictly_better |= candidate_value < incumbent_value
            else:
                if candidate_value < incumbent_value:
                    return False
                strictly_better |= candidate_value > incumbent_value
        return comparable and strictly_better

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
        disable_presolve: bool = False,
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
        if fix_hints or disable_presolve:
            # A verified full-model assignment is already fixed or supplied as
            # a feasible hint. Presolving the whole dynamic pay model can take
            # far longer than evaluating/searching from that assignment and is
            # not bounded reliably by CP-SAT's timer on large monthly instances.
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
        disable_presolve: bool = False,
    ) -> tuple[Any, Any]:
        if self._cancel_event.is_set():
            raise OptimizationCancelled("Optimization was cancelled")
        validation_error = model.validate()
        if validation_error:
            raise OptimizationError(
                f"Invalid CP-SAT model at {stage_name}: {validation_error}"
            )
        solver = self._new_solver(
            snapshot,
            strategy,
            time_limit_seconds,
            fix_hints=fix_hints,
            disable_presolve=disable_presolve,
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
            # The company configuration is the single source of truth for the
            # daily assignment capacity.  Overlap and rest remain independent
            # hard constraints when the configured value is greater than one.
            if (
                daily_count[(employee.id, slot.date)]
                >= employee.maximum_shifts_per_day
            ):
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
                        # A role grant marked BACKUP is an emergency fallback,
                        # not a fairness tool.  Prefer the employee whose role
                        # is STANDARD before considering workload balancing in
                        # the warm start.  The CP-SAT stage above still proves
                        # the global minimum and can use BACKUP when hard rules
                        # make it necessary.
                        employee.role_assignment_penalty(slot.role_id, slot.date),
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

        employees_by_id = {employee.id: employee for employee in snapshot.employees}
        role_backup_penalty_terms = [
            variable
            * employees_by_id[employee_id].role_assignment_penalty(
                slots_by_id[slot_id].role_id, slots_by_id[slot_id].date
            )
            for (employee_id, slot_id), variable in x.items()
        ]
        role_backup_penalty_expression = _sum(role_backup_penalty_terms)
        role_backup_penalty_bound = sum(
            employees_by_id[employee_id].role_assignment_penalty(
                slots_by_id[slot_id].role_id, slots_by_id[slot_id].date
            )
            for employee_id, slot_id in x
        )

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

        # Capacity-based target used by every strategy.  Count only occurrences
        # that the employee can actually cover after role, duty, location,
        # employment, availability, hard-block and external-rest checks.  Daily
        # and weekly limits then cap that compatible capacity before the
        # employee's monthly target/maximum is applied.  External work belongs
        # to the same monthly utilization numerator and target.
        achievable_target_minutes: dict[str, int] = {}
        for employee in snapshot.employees:
            external = external_by_employee.get(employee.id, [])
            external_daily_count: dict[date, int] = defaultdict(int)
            external_daily_minutes: dict[date, int] = defaultdict(int)
            for item in external:
                local_day = item.start.astimezone(timezone).date()
                duration = int((item.end.timestamp() - item.start.timestamp()) // 60)
                external_daily_count[local_day] += 1
                external_daily_minutes[local_day] += duration

            compatible_occurrences: dict[str, Slot] = {}
            for slot in slots:
                if eligibility.evaluate(employee, slot).allowed:
                    compatible_occurrences.setdefault(slot.occurrence_id, slot)
            compatible_by_day: dict[date, list[int]] = defaultdict(list)
            for occurrence in compatible_occurrences.values():
                compatible_by_day[occurrence.date].append(
                    occurrence.duration_minutes
                )

            compatible_by_week: dict[tuple[int, int], int] = defaultdict(int)
            for day, durations in compatible_by_day.items():
                remaining_shifts = max(
                    0,
                    employee.maximum_shifts_per_day
                    - external_daily_count.get(day, 0),
                )
                if remaining_shifts:
                    week_key = (day.isocalendar().year, day.isocalendar().week)
                    compatible_by_week[week_key] += sum(
                        sorted(durations, reverse=True)[:remaining_shifts]
                    )

            compatible_minutes = 0
            for week_key, candidate_minutes in compatible_by_week.items():
                if employee.maximum_weekly_minutes is not None:
                    external_week = sum(
                        duration
                        for day, duration in external_daily_minutes.items()
                        if (day.isocalendar().year, day.isocalendar().week)
                        == week_key
                    )
                    candidate_minutes = min(
                        candidate_minutes,
                        max(0, employee.maximum_weekly_minutes - external_week),
                    )
                compatible_minutes += candidate_minutes

            external_month_total = sum(
                minutes
                for day, minutes in external_daily_minutes.items()
                if snapshot.period_start <= day <= snapshot.period_end
            )
            attainable = external_month_total + compatible_minutes
            if employee.maximum_monthly_minutes is not None:
                attainable = min(attainable, employee.maximum_monthly_minutes)
            if employee.nominal_monthly_minutes is not None:
                attainable = min(attainable, employee.nominal_monthly_minutes)
            achievable_target_minutes[employee.id] = max(0, attainable)

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
            # Overtime is never an accidental side-effect of a cheaper base
            # rate. NEVER and APPROVAL_REQUIRED both stay inside the nominal
            # during automatic generation. The latter is surfaced as a leader
            # decision from the remaining shortage workflow.
            if (
                employee.nominal_monthly_minutes is not None
                and employee.overtime_policy != "ALLOWED"
            ):
                model.add(total <= employee.nominal_monthly_minutes)

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

        # Build the max-min target metric before the coverage-only fast paths
        # return.  The monthly coverage model already contains every hard
        # availability, rest and hours constraint, while deliberately omitting
        # the large soft-cost surface.  It is therefore the right place to
        # create a fair, hard-feasible roster seed: first prove/fix coverage and
        # dedicated-role use, then maximize the least realized attainable
        # target.  Previously this metric existed only in the full strategy
        # model, so a coverage-optimal but extremely uneven roster (for example
        # 10 h versus 180 h) became the shared fixed warm start.
        achievable_utilization_vars: list[Any] = []
        for employee in snapshot.employees:
            achievable_target = achievable_target_minutes[employee.id]
            if achievable_target <= 0:
                continue
            capped_minutes = model.new_int_var(
                0,
                achievable_target,
                f"achievable_capped_minutes|{employee.id}",
            )
            model.add_min_equality(
                capped_minutes, [total_minutes[employee.id], achievable_target]
            )
            achievable_utilization = model.new_int_var(
                0,
                1000,
                f"achievable_utilization_bps|{employee.id}",
            )
            model.add_division_equality(
                achievable_utilization,
                capped_minutes * 1000,
                achievable_target,
            )
            achievable_utilization_vars.append(achievable_utilization)
        if achievable_utilization_vars:
            minimum_achievable_utilization = model.new_int_var(
                0, 1000, "minimum_achievable_utilization_bps"
            )
            maximum_achievable_utilization = model.new_int_var(
                0, 1000, "maximum_achievable_utilization_bps"
            )
            model.add_min_equality(
                minimum_achievable_utilization, achievable_utilization_vars
            )
            model.add_max_equality(
                maximum_achievable_utilization, achievable_utilization_vars
            )
            achievable_utilization_deficit = 1000 - minimum_achievable_utilization
            achievable_utilization_spread = (
                maximum_achievable_utilization - minimum_achievable_utilization
            )
        else:
            minimum_achievable_utilization = 0
            maximum_achievable_utilization = 0
            achievable_utilization_deficit = 0
            achievable_utilization_spread = 0

        # Stand-by is a post-publication, best-effort operational layer.  It is
        # intentionally not a hard CP-SAT constraint: a cross-trained person
        # can be needed by another role, so reserving capacity here could still
        # create a vacancy elsewhere.  Publication selects available reserve
        # candidates only after the globally best roster has been chosen.

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
                metrics={
                    "UNFILLED": _sum(unfilled.values()),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_expression,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_achievable_utilization,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": achievable_utilization_deficit,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": achievable_utilization_spread,
                },
                metric_bounds={
                    "UNFILLED": len(slots),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_bound,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": 1000,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": 1000,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": 1000,
                },
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
        def static_cost_for_basis(key: tuple[str, str], cost_basis: str) -> int:
            return sum(
                component.cost_units
                for component in static_quotes[key].components
                if cost_basis == "FULL_EMPLOYER_COST"
                or component.cost_category != "EMPLOYER_ONCOST"
            )

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
                (
                    eligible_upper_by_slot[slot.id]
                    if budget.metric_type in {"COST", "LABOR_PERCENT"}
                    else slot.duration_minutes
                )
                for slot in slots
                if budget.matches(slot)
            )
            > (
                budget.amount_minor * COST_SCALE
                if budget.metric_type in {"COST", "LABOR_PERCENT"}
                else int(budget.limit_minutes or 0)
            )
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
                metrics={
                    "UNFILLED": _sum(unfilled.values()),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_expression,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_achievable_utilization,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": achievable_utilization_deficit,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": achievable_utilization_spread,
                },
                metric_bounds={
                    "UNFILLED": len(slots),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_bound,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": 1000,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": 1000,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": 1000,
                },
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
                threshold_source = str(rule.values.get("thresholdSource", rule.values.get("threshold_source", "FIXED"))).upper()
                threshold = employee.nominal_monthly_minutes if threshold_source == "EMPLOYEE_NOMINAL" else int(threshold_raw)
                if threshold is None:
                    raise SnapshotError("Employee nominal is required by an overtime pay rule")
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
        wage_cost_expression = _sum(
            variable * static_cost_for_basis(key, "WAGES")
            for key, variable in x.items()
        ) + _sum(dynamic_total_terms)

        for budget in snapshot.budgets:
            if budget.hard and budget.metric_type in {"COST", "LABOR_PERCENT"} and not budget.scope():
                budget_expression = (
                    total_cost_expression
                    if budget.cost_basis == "FULL_EMPLOYER_COST"
                    else wage_cost_expression
                )
                model.add(budget_expression <= budget.amount_minor * COST_SCALE)

        scoped_budgets = [
            budget for budget in snapshot.budgets
            if budget.enforcement in {"HARD", "TARGET"}
            and budget.metric_type in {"COST", "LABOR_PERCENT"}
            and budget.scope()
        ]
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

        scoped_cost_expressions: dict[str, Any] = {}
        for budget in scoped_budgets:
            scoped_cost = _sum(
                x[key] * static_cost_for_basis(key, budget.cost_basis)
                + _sum(dynamic_cost_by_assignment[key])
                for key in x
                if budget.matches(slots_by_id[key[1]])
            )
            scoped_cost_expressions[budget.id] = scoped_cost
            if budget.hard:
                model.add(scoped_cost <= budget.amount_minor * COST_SCALE)

        target_excess_terms: list[Any] = []
        target_excess_bound = 0
        for budget in snapshot.budgets:
            if budget.enforcement == "MONITORING":
                continue
            if budget.metric_type == "HOURS":
                scoped_minutes = _sum(
                    x[key] * slots_by_id[key[1]].duration_minutes
                    for key in x
                    if budget.matches(slots_by_id[key[1]])
                )
                limit_minutes = int(budget.limit_minutes or 0)
                if budget.hard:
                    model.add(scoped_minutes <= limit_minutes)
                elif budget.enforcement == "TARGET":
                    bound = sum(slot.duration_minutes for slot in slots if budget.matches(slot))
                    excess = model.new_int_var(0, max(bound - limit_minutes, 0), f"budget_target_hours|{budget.id}")
                    model.add_max_equality(excess, [scoped_minutes - limit_minutes, 0])
                    target_excess_terms.append(excess * COST_SCALE)
                    target_excess_bound += max(bound - limit_minutes, 0) * COST_SCALE
            elif budget.enforcement == "TARGET":
                expression = (
                    (total_cost_expression if budget.cost_basis == "FULL_EMPLOYER_COST" else wage_cost_expression)
                    if not budget.scope() else scoped_cost_expressions[budget.id]
                )
                limit_units = budget.amount_minor * COST_SCALE
                bound = sum(eligible_upper_by_slot[slot.id] for slot in slots if budget.matches(slot))
                excess = model.new_int_var(0, max(bound - limit_units, 0), f"budget_target_cost|{budget.id}")
                model.add_max_equality(excess, [expression - limit_units, 0])
                target_excess_terms.append(excess)
                target_excess_bound += max(bound - limit_units, 0)

        budget_target_excess_expression = _sum(target_excess_terms)

        if coverage_only:
            return _Artifacts(
                model=model,
                x=x,
                unfilled=unfilled,
                work=work,
                day_work=day_work,
                total_minutes=total_minutes,
                metrics={
                    "UNFILLED": _sum(unfilled.values()),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_expression,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_achievable_utilization,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": achievable_utilization_deficit,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": achievable_utilization_spread,
                },
                metric_bounds={
                    "UNFILLED": len(slots),
                    "ROLE_BACKUP_PENALTY": role_backup_penalty_bound,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": 1000,
                    "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": 1000,
                    "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": 1000,
                },
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
                + int(
                    eligibility.violates_preferred_work_pattern(employee.id, slot)
                )
            )
            for employee in snapshot.employees
            for slot in slots
            if (variable := x.get((employee.id, slot.id))) is not None
        )
        # All standard-allowed locations consume the same ordinary contract
        # limit. The former "home location" marker is no longer an objective.
        home_expression = 0

        role_dates: dict[str, set[date]] = defaultdict(set)
        pool_dates: dict[tuple[str, str], set[date]] = defaultdict(set)
        for slot in slots:
            role_dates[slot.role_id].add(slot.date)
            pool_dates[(slot.role_id, slot.location_id)].add(slot.date)

        def standard_role_allowed_on(
            employee: Any, role_id: str, day: date
        ) -> bool:
            if employee.role_grants is None:
                return role_id in employee.role_ids
            return any(
                grant.role_id == role_id
                and grant.assignment_mode == "STANDARD"
                and grant.active_on(day)
                for grant in employee.role_grants
            )

        def standard_role_member(employee: Any, role_id: str) -> bool:
            return any(
                standard_role_allowed_on(employee, role_id, day)
                for day in role_dates[role_id]
            )

        deviation_vars: list[Any] = []
        overtime_vars: list[Any] = []
        weekend_vars: list[Any] = []
        zero_target_vars: list[Any] = []
        zero_primary_role_vars: list[Any] = []
        under_target_vars: list[Any] = []
        under_target_bound_total = 0
        deviation_bound_total = 0
        overtime_bound_total = 0
        for employee in snapshot.employees:
            total = total_minutes[employee.id]
            achievable_target = achievable_target_minutes[employee.id]
            if employee.nominal_monthly_minutes is not None:
                nominal = employee.nominal_monthly_minutes
                deviation = model.new_int_var(
                    0, max_total_bound + nominal, f"deviation|{employee.id}"
                )
                model.add_abs_equality(deviation, total - nominal)
                deviation_vars.append(deviation)
                deviation_bound_total += max_total_bound + nominal
                under_target = model.new_int_var(
                    0, nominal, f"under_target|{employee.id}"
                )
                model.add_max_equality(under_target, [nominal - total, 0])
                under_target_vars.append(under_target)
                under_target_bound_total += nominal
                overtime = model.new_int_var(
                    0, max_total_bound, f"overtime|{employee.id}"
                )
                model.add_max_equality(overtime, [total - nominal, 0])
                overtime_vars.append(overtime)
                overtime_bound_total += max_total_bound
                # Common product guard: an eligible employee with a positive
                # monthly target may not be silently dropped merely because a
                # strategy values cost or preferences more highly. First
                # minimize the number of zero-hour target employees, then the
                # category-wide spread of target realization. Availability and
                # every hard rule are already reflected in the x variables.
                if nominal > 0 and achievable_target_minutes[employee.id] > 0:
                    has_minutes = model.new_bool_var(
                        f"has_target_minutes|{employee.id}"
                    )
                    model.add(total >= 1).only_enforce_if(has_minutes)
                    model.add(total == 0).only_enforce_if(has_minutes.Not())
                    zero_target_vars.append(1 - has_minutes)
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

        zero_target_count = _sum(zero_target_vars)

        # Product contract: every active primary/ordinary (STANDARD) role in
        # the generated category gets its own zero-assignment indicator.
        # Counting the employee's global minutes here was incorrect: a HOST
        # shift obtained through a BACKUP grant could make a primary KELNER
        # appear non-zero even though the employee received no KELNER shift.
        # Only eligible assignments in the exact STANDARD role and on a date
        # where that grant is active can satisfy this indicator.
        for employee in snapshot.employees:
            if achievable_target_minutes[employee.id] <= 0:
                continue
            for role_id in sorted(role_dates):
                if not standard_role_member(employee, role_id):
                    continue
                role_assignment_vars = [
                    x[(employee.id, slot.id)]
                    for slot in slots
                    if slot.role_id == role_id
                    and standard_role_allowed_on(employee, role_id, slot.date)
                    and (employee.id, slot.id) in x
                ]
                if not role_assignment_vars:
                    continue
                has_primary_role_assignment = model.new_bool_var(
                    f"has_primary_role_assignment|{employee.id}|{role_id}"
                )
                role_assignment_count = _sum(role_assignment_vars)
                model.add(role_assignment_count >= 1).only_enforce_if(
                    has_primary_role_assignment
                )
                model.add(role_assignment_count == 0).only_enforce_if(
                    has_primary_role_assignment.Not()
                )
                zero_primary_role_vars.append(1 - has_primary_role_assignment)

        zero_primary_role_count = _sum(zero_primary_role_vars)

        # Comparable sets are formed per STANDARD role and location, so an
        # unrelated role cannot define both ends of one spread.  Inside each
        # such set, however, the accepted company rule deliberately compares a
        # person's total monthly minutes across every role.  Do not replace the
        # numerator with role-only minutes: hours worked through an additional
        # role still count toward that person's overall fair share.  A
        # BACKUP-only grant does not make somebody ordinary capacity in that
        # role and therefore does not add them to its comparison set.
        role_utilization_spreads: list[Any] = []
        role_weekend_spreads: list[Any] = []
        utilization_participants: set[str] = set()
        explicit_utilization_participants: set[str] = set()
        fallback_utilization_participants: set[str] = set()
        utilization_bound = 0
        weekend_bound = len(occurrences)

        for role_id, location_id in sorted(pool_dates):
            members = [
                employee
                for employee in snapshot.employees
                if standard_role_member(employee, role_id)
                and achievable_target_minutes[employee.id] > 0
                and any(
                    employee_id == employee.id
                    and slots_by_id[slot_id].role_id == role_id
                    and slots_by_id[slot_id].location_id == location_id
                    for employee_id, slot_id in x
                )
            ]
            if len(members) < 2:
                continue
            role_utilizations: list[Any] = []
            role_weekends: list[Any] = []
            for employee in members:
                utilization_participants.add(employee.id)
                basis = achievable_target_minutes[employee.id]
                if employee.nominal_monthly_minutes is not None:
                    explicit_utilization_participants.add(employee.id)
                else:
                    fallback_utilization_participants.add(employee.id)
                # Achievable target is an upper bound on minutes this employee
                # can receive in the snapshot, so utilization is naturally
                # capped at 1000 (100%).  The fixed bound also keeps the
                # lexicographic score safely inside CP-SAT int64 arithmetic.
                bound = 1000
                utilization = model.new_int_var(
                    0,
                    bound,
                    f"pool_utilization_bps|{role_id}|{location_id}|{employee.id}",
                )
                model.add_division_equality(
                    utilization, total_minutes[employee.id] * 1000, basis
                )
                role_utilizations.append(utilization)
                utilization_bound = max(utilization_bound, bound)

                role_weekend = model.new_int_var(
                    0,
                    weekend_bound,
                    f"pool_weekends|{role_id}|{location_id}|{employee.id}",
                )
                model.add(
                    role_weekend
                    == _sum(
                        variable
                        for (employee_id, occurrence_id), variable in work.items()
                        if employee_id == employee.id
                        and occurrences[occurrence_id].role_id == role_id
                        and occurrences[occurrence_id].location_id == location_id
                        and occurrences[occurrence_id].date.isoweekday() in {6, 7}
                    )
                )
                role_weekends.append(role_weekend)

            role_max = model.new_int_var(
                0, utilization_bound, f"pool_max_utilization|{role_id}|{location_id}"
            )
            role_min = model.new_int_var(
                0, utilization_bound, f"pool_min_utilization|{role_id}|{location_id}"
            )
            model.add_max_equality(role_max, role_utilizations)
            model.add_min_equality(role_min, role_utilizations)
            role_utilization_spreads.append(role_max - role_min)

            role_max_weekend = model.new_int_var(
                0, weekend_bound, f"pool_max_weekend|{role_id}|{location_id}"
            )
            role_min_weekend = model.new_int_var(
                0, weekend_bound, f"pool_min_weekend|{role_id}|{location_id}"
            )
            model.add_max_equality(role_max_weekend, role_weekends)
            model.add_min_equality(role_min_weekend, role_weekends)
            role_weekend_spreads.append(role_max_weekend - role_min_weekend)

        if role_utilization_spreads:
            role_count = len(role_utilization_spreads)
            role_sum_bound = utilization_bound * role_count
            role_load_sum = _sum(role_utilization_spreads)
            role_load_max = model.new_int_var(
                0, utilization_bound, "role_load_max_spread_bps"
            )
            model.add_max_equality(role_load_max, role_utilization_spreads)
            role_load_fairness_score: Any = (
                role_load_max * (role_sum_bound + 1) + role_load_sum
            )
            role_load_score_bound = (
                utilization_bound * (role_sum_bound + 1) + role_sum_bound
            )
        else:
            role_load_max = 0
            role_load_sum = 0
            role_load_fairness_score = 0
            role_load_score_bound = 0

        # Product-wide lexicographic gate shared by all strategies: eliminate
        # unjustified zero-hour outcomes first, maximize the least-realized
        # achievable target (capped at 100%), then minimize the worst and total
        # proportional spread inside comparable role-location pools.
        common_fairness_guard_score = (
            zero_target_count * (1001 * (role_load_score_bound + 1))
            + achievable_utilization_deficit * (role_load_score_bound + 1)
            + role_load_fairness_score
        )
        common_fairness_guard_bound = (
            len(zero_target_vars) * (1001 * (role_load_score_bound + 1))
            + 1000 * (role_load_score_bound + 1)
            + role_load_score_bound
        )

        if role_weekend_spreads:
            weekend_role_count = len(role_weekend_spreads)
            weekend_sum_bound = weekend_bound * weekend_role_count
            role_weekend_sum = _sum(role_weekend_spreads)
            role_weekend_max = model.new_int_var(
                0, weekend_bound, "role_weekend_max_spread"
            )
            model.add_max_equality(role_weekend_max, role_weekend_spreads)
            role_weekend_fairness_score: Any = (
                role_weekend_max * (weekend_sum_bound + 1) + role_weekend_sum
            )
            role_weekend_score_bound = (
                weekend_bound * (weekend_sum_bound + 1) + weekend_sum_bound
            )
        else:
            role_weekend_max = 0
            role_weekend_sum = 0
            role_weekend_fairness_score = 0
            role_weekend_score_bound = 0

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
            "ROLE_BACKUP_PENALTY": role_backup_penalty_expression,
            "TOTAL_COST": total_cost_expression,
            "WAGE_COST": wage_cost_expression,
            "EMPLOYER_ONCOST": total_cost_expression - wage_cost_expression,
            "BUDGET_TARGET_EXCESS": budget_target_excess_expression,
            "PREFERENCE_VIOLATIONS": preference_expression,
            "HOME_LOCATION_VIOLATIONS": home_expression,
            "NOMINAL_DEVIATION_MINUTES": _sum(deviation_vars),
            "UNDER_TARGET_MINUTES": _sum(under_target_vars),
            "NOMINAL_TARGET_EMPLOYEE_COUNT": len(deviation_vars),
            "OVERTIME_MINUTES": _sum(overtime_vars),
            "ZERO_TARGET_EMPLOYEE_COUNT": zero_target_count,
            "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT": zero_primary_role_count,
            "PRIMARY_ROLE_GUARD_PAIR_COUNT": len(zero_primary_role_vars),
            "ACHIEVABLE_TARGET_MINUTES_TOTAL": sum(achievable_target_minutes.values()),
            "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_achievable_utilization,
            "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": achievable_utilization_deficit,
            "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": achievable_utilization_spread,
            "COMMON_FAIRNESS_GUARD_SCORE": common_fairness_guard_score,
            "ROLE_LOAD_FAIRNESS_SCORE": role_load_fairness_score,
            "LOAD_UTILIZATION_SPREAD_BPS": role_load_max,
            "ROLE_LOAD_SPREAD_SUM_BPS": role_load_sum,
            "ROLE_LOAD_FAIRNESS_ROLE_COUNT": len(role_utilization_spreads),
            "ROLE_LOCATION_FAIRNESS_POOL_COUNT": len(role_utilization_spreads),
            "LOAD_UTILIZATION_TARGET_COUNT": len(utilization_participants),
            "LOAD_UTILIZATION_EXPLICIT_TARGET_COUNT": len(explicit_utilization_participants),
            "LOAD_UTILIZATION_FALLBACK_COUNT": len(fallback_utilization_participants),
            "ROLE_WEEKEND_FAIRNESS_SCORE": role_weekend_fairness_score,
            "WEEKEND_SPREAD": role_weekend_max,
            "ROLE_WEEKEND_SPREAD_SUM": role_weekend_sum,
            "BASELINE_CHANGES": _sum(baseline_terms),
        }
        metric_bounds = {
            "UNFILLED": len(slots),
            "ROLE_BACKUP_PENALTY": role_backup_penalty_bound,
            "TOTAL_COST": total_cost_upper,
            "WAGE_COST": total_cost_upper,
            "EMPLOYER_ONCOST": total_cost_upper,
            "BUDGET_TARGET_EXCESS": target_excess_bound,
            "PREFERENCE_VIOLATIONS": 5 * len(slots),
            "HOME_LOCATION_VIOLATIONS": 0,
            "NOMINAL_DEVIATION_MINUTES": deviation_bound_total,
            "UNDER_TARGET_MINUTES": under_target_bound_total,
            "NOMINAL_TARGET_EMPLOYEE_COUNT": len(snapshot.employees),
            "OVERTIME_MINUTES": overtime_bound_total,
            "ZERO_TARGET_EMPLOYEE_COUNT": len(zero_target_vars),
            "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT": len(zero_primary_role_vars),
            "PRIMARY_ROLE_GUARD_PAIR_COUNT": len(zero_primary_role_vars),
            "ACHIEVABLE_TARGET_MINUTES_TOTAL": sum(achievable_target_minutes.values()),
            "MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS": 1000,
            "MIN_ACHIEVABLE_TARGET_UTILIZATION_DEFICIT_BPS": 1000,
            "ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": 1000,
            "COMMON_FAIRNESS_GUARD_SCORE": common_fairness_guard_bound,
            "ROLE_LOAD_FAIRNESS_SCORE": role_load_score_bound,
            "LOAD_UTILIZATION_SPREAD_BPS": utilization_bound,
            "ROLE_LOAD_SPREAD_SUM_BPS": utilization_bound * len(role_utilization_spreads),
            "ROLE_LOAD_FAIRNESS_ROLE_COUNT": len(role_utilization_spreads),
            "ROLE_LOCATION_FAIRNESS_POOL_COUNT": len(role_utilization_spreads),
            "LOAD_UTILIZATION_TARGET_COUNT": len(snapshot.employees),
            "LOAD_UTILIZATION_EXPLICIT_TARGET_COUNT": len(snapshot.employees),
            "LOAD_UTILIZATION_FALLBACK_COUNT": len(snapshot.employees),
            "ROLE_WEEKEND_FAIRNESS_SCORE": role_weekend_score_bound,
            "WEEKEND_SPREAD": weekend_bound,
            "ROLE_WEEKEND_SPREAD_SUM": weekend_bound * len(role_weekend_spreads),
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
