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
            # merely a fourth variant.  Give it half of the remaining…22586 tokens truncated…ot in matching_slots)
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
                metrics={"UNFILLED": _sum(unfilled.values()), "ROLE_BACKUP_PENALTY": role_backup_penalty_expression},
                metric_bounds={"UNFILLED": len(slots), "ROLE_BACKUP_PENALTY": role_backup_penalty_bound},
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

        # Fairness must be evaluated inside each role, not once across the whole
        # category.  A single category-wide min/max allowed a heavily loaded
        # BARMAN to define the global maximum and an underloaded BARBACK to
        # define the minimum; moving work between two BARBACK employees then
        # changed neither end and had no value to the optimizer.  Build a
        # utilization range for every role and optimize the worst range first,
        # followed by the sum of all role ranges.  BACKUP-only grants are not
        # regular staffing capacity and therefore do not dilute fair sharing.
        role_dates: dict[str, set[date]] = defaultdict(set)
        role_slot_minutes: dict[str, int] = defaultdict(int)
        for slot in slots:
            role_dates[slot.role_id].add(slot.date)
            role_slot_minutes[slot.role_id] += slot.duration_minutes

        def standard_role_member(employee: Any, role_id: str) -> bool:
            if employee.role_grants is None:
                return role_id in employee.role_ids
            return any(
                grant.role_id == role_id
                and grant.assignment_mode == "STANDARD"
                and any(grant.active_on(day) for day in role_dates[role_id])
                for grant in employee.role_grants
            )

        role_utilization_spreads: list[Any] = []
        role_weekend_spreads: list[Any] = []
        utilization_participants: set[str] = set()
        explicit_utilization_participants: set[str] = set()
        fallback_utilization_participants: set[str] = set()
        utilization_bound = 0
        weekend_bound = len(occurrences)

        for role_id in sorted(role_dates):
            members = [
                employee
                for employee in snapshot.employees
                if standard_role_member(employee, role_id)
            ]
            if len(members) < 2:
                continue
            role_fallback_basis = max(
                1,
                math.ceil(role_slot_minutes[role_id] / len(members)),
            )
            role_utilizations: list[Any] = []
            role_weekends: list[Any] = []
            for employee in members:
                utilization_participants.add(employee.id)
                basis = employee.nominal_monthly_minutes
                if basis is None or basis <= 0:
                    basis = employee.maximum_monthly_minutes
                if basis is None or basis <= 0:
                    basis = role_fallback_basis
                    fallback_utilization_participants.add(employee.id)
                else:
                    explicit_utilization_participants.add(employee.id)

                role_minutes = model.new_int_var(
                    0,
                    max_total_bound,
                    f"role_minutes|{role_id}|{employee.id}",
                )
                model.add(
                    role_minutes
                    == _sum(
                        variable * slots_by_id[slot_id].duration_minutes
                        for (employee_id, slot_id), variable in x.items()
                        if employee_id == employee.id
                        and slots_by_id[slot_id].role_id == role_id
                    )
                )
                bound = math.ceil(max_total_bound * 1000 / basis)
                utilization = model.new_int_var(
                    0,
                    bound,
                    f"role_utilization_bps|{role_id}|{employee.id}",
                )
                model.add_division_equality(utilization, role_minutes * 1000, basis)
                role_utilizations.append(utilization)
                utilization_bound = max(utilization_bound, bound)

                role_weekend = model.new_int_var(
                    0,
                    weekend_bound,
                    f"role_weekends|{role_id}|{employee.id}",
                )
                model.add(
                    role_weekend
                    == _sum(
                        variable
                        for (employee_id, occurrence_id), variable in work.items()
                        if employee_id == employee.id
                        and occurrences[occurrence_id].role_id == role_id
                        and occurrences[occurrence_id].date.isoweekday() in {6, 7}
                    )
                )
                role_weekends.append(role_weekend)

            role_max = model.new_int_var(
                0, utilization_bound, f"role_max_utilization|{role_id}"
            )
            role_min = model.new_int_var(
                0, utilization_bound, f"role_min_utilization|{role_id}"
            )
            model.add_max_equality(role_max, role_utilizations)
            model.add_min_equality(role_min, role_utilizations)
            role_utilization_spreads.append(role_max - role_min)

            role_max_weekend = model.new_int_var(
                0, weekend_bound, f"role_max_weekend|{role_id}"
            )
            role_min_weekend = model.new_int_var(
                0, weekend_bound, f"role_min_weekend|{role_id}"
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
            "PREFERENCE_VIOLATIONS": preference_expression,
            "HOME_LOCATION_VIOLATIONS": home_expression,
            "NOMINAL_DEVIATION_MINUTES": _sum(deviation_vars),
            "NOMINAL_TARGET_EMPLOYEE_COUNT": len(deviation_vars),
            "OVERTIME_MINUTES": _sum(overtime_vars),
            "ROLE_LOAD_FAIRNESS_SCORE": role_load_fairness_score,
            "LOAD_UTILIZATION_SPREAD_BPS": role_load_max,
            "ROLE_LOAD_SPREAD_SUM_BPS": role_load_sum,
            "ROLE_LOAD_FAIRNESS_ROLE_COUNT": len(role_utilization_spreads),
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
            "PREFERENCE_VIOLATIONS": 4 * len(slots),
            "HOME_LOCATION_VIOLATIONS": 0,
            "NOMINAL_DEVIATION_MINUTES": deviation_bound_total,
            "NOMINAL_TARGET_EMPLOYEE_COUNT": len(snapshot.employees),
            "OVERTIME_MINUTES": overtime_bound_total,
            "ROLE_LOAD_FAIRNESS_SCORE": role_load_score_bound,
            "LOAD_UTILIZATION_SPREAD_BPS": utilization_bound,
            "ROLE_LOAD_SPREAD_SUM_BPS": utilization_bound * len(role_utilization_spreads),
            "ROLE_LOAD_FAIRNESS_ROLE_COUNT": len(role_utilization_spreads),
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

