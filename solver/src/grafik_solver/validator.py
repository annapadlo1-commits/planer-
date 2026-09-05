from __future__ import annotations

from collections import defaultdict
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import date, timedelta
from zoneinfo import ZoneInfo

from .canonical import sha256_hex
from .eligibility import EligibilityIndex, violates_rest
from .models import Assignment, Snapshot, VariantResult
from .pay_rules import (
    COST_SCALE,
    quote_selected_assignments,
    validate_pay_rules,
)
from .slots import (
    Slot,
    consecutive_shift_sequence,
    generate_slots,
    shift_sequence_boundaries,
)


class VariantValidationError(ValueError):
    pass


@dataclass(frozen=True)
class BudgetValidationResult:
    budget_id: str
    currency: str
    hard: bool
    scope: Mapping[str, str]
    spent_units: int
    limit_units: int
    exceeded: bool

    def to_dict(self) -> dict[str, object]:
        return {
            "budgetId": self.budget_id,
            "currency": self.currency,
            "hard": self.hard,
            "scope": dict(self.scope),
            "spentUnits": self.spent_units,
            "limitUnits": self.limit_units,
            "exceeded": self.exceeded,
        }


@dataclass(frozen=True)
class ValidationReport:
    errors: tuple[str, ...]
    assignment_count: int
    unfilled_count: int
    total_cost_units: int
    budget_results: tuple[BudgetValidationResult, ...] = ()

    @property
    def valid(self) -> bool:
        return not self.errors

    def raise_for_errors(self) -> None:
        if self.errors:
            raise VariantValidationError("; ".join(self.errors))


def _append_once(errors: list[str], message: str) -> None:
    if message not in errors:
        errors.append(message)


def validate_variant(
    snapshot: Snapshot,
    variant: VariantResult,
    slots: tuple[Slot, ...] | None = None,
) -> ValidationReport:
    validate_pay_rules(snapshot)
    slots = slots or generate_slots(snapshot)
    slots_by_id = {slot.id: slot for slot in slots}
    employees = {employee.id: employee for employee in snapshot.employees}
    strategies = {strategy.id for strategy in snapshot.strategies}
    errors: list[str] = []
    if variant.strategy_id not in strategies:
        errors.append(f"UNKNOWN_STRATEGY:{variant.strategy_id}")

    assignment_by_slot: dict[str, Assignment] = {}
    for assignment in variant.assignments:
        if assignment.slot_id in assignment_by_slot:
            errors.append(f"DUPLICATE_SLOT_ASSIGNMENT:{assignment.slot_id}")
        assignment_by_slot[assignment.slot_id] = assignment
        if assignment.slot_id not in slots_by_id:
            errors.append(f"UNKNOWN_SLOT:{assignment.slot_id}")
        if assignment.employee_id not in employees:
            errors.append(f"UNKNOWN_EMPLOYEE:{assignment.employee_id}")

    unfilled = set(variant.unfilled_slot_ids)
    if len(unfilled) != len(variant.unfilled_slot_ids):
        errors.append("DUPLICATE_UNFILLED_SLOT")
    for slot_id in unfilled:
        if slot_id not in slots_by_id:
            errors.append(f"UNKNOWN_UNFILLED_SLOT:{slot_id}")
        if slot_id in assignment_by_slot:
            errors.append(f"ASSIGNED_AND_UNFILLED:{slot_id}")
    accounted = set(assignment_by_slot) | unfilled
    missing = set(slots_by_id) - accounted
    if missing:
        errors.append(f"UNACCOUNTED_SLOTS:{','.join(sorted(missing))}")

    eligibility = EligibilityIndex(snapshot)
    selected: list[tuple[Assignment, object, Slot]] = []
    for assignment in variant.assignments:
        employee = employees.get(assignment.employee_id)
        slot = slots_by_id.get(assignment.slot_id)
        if employee is None or slot is None:
            continue
        result = eligibility.evaluate(employee, slot)
        if not result.allowed:
            errors.append(
                f"INELIGIBLE:{employee.id}:{slot.id}:{','.join(result.reasons)}"
            )
        selected.append((assignment, employee, slot))

    complete_quotes = quote_selected_assignments(
        snapshot, ((employee, slot) for _assignment, employee, slot in selected)
    )
    for assignment, employee, slot in selected:
        quote = complete_quotes[(employee.id, slot.id)]
        if assignment.cost_units != quote.cost_units:
            errors.append(
                f"ASSIGNMENT_COST_MISMATCH:{slot.id}:{assignment.cost_units}:{quote.cost_units}"
            )
        expected_components = [component.to_dict() for component in quote.components]
        actual_components = [
            dict(component) for component in assignment.cost_components
        ]
        if actual_components != expected_components:
            errors.append(f"COST_COMPONENT_MISMATCH:{slot.id}")

    selected_by_employee: dict[str, list[Slot]] = defaultdict(list)
    seen_occurrence: set[tuple[str, str]] = set()
    for _assignment, employee, slot in selected:
        key = (employee.id, slot.occurrence_id)
        if key in seen_occurrence:
            errors.append(
                f"MULTIPLE_SEATS_SAME_SHIFT:{employee.id}:{slot.occurrence_id}"
            )
        seen_occurrence.add(key)
        selected_by_employee[employee.id].append(slot)

    timezone = ZoneInfo(snapshot.settings.timezone)
    external_by_employee: dict[str, list[object]] = defaultdict(list)
    for external in snapshot.external_assignments:
        external_by_employee[external.employee_id].append(external)

    sequence_boundaries = shift_sequence_boundaries(snapshot)

    for employee_id, employee in employees.items():
        employee_slots = sorted(
            selected_by_employee.get(employee_id, []), key=lambda slot: slot.start
        )
        rest_minutes = eligibility.minimum_rest(employee)
        for index, first in enumerate(employee_slots):
            for second in employee_slots[index + 1 :]:
                if violates_rest(
                    first.start,
                    first.end,
                    second.start,
                    second.end,
                    rest_minutes,
                ):
                    errors.append(
                        f"OVERLAP_OR_REST:{employee_id}:{first.id}:{second.id}"
                    )
                if consecutive_shift_sequence(sequence_boundaries, first, second):
                    errors.append(
                        f"CONSECUTIVE_SHIFT_SEQUENCE:{employee_id}:{first.id}:{second.id}"
                    )

        daily_count: dict[date, int] = defaultdict(int)
        daily_minutes: dict[date, int] = defaultdict(int)
        for slot in employee_slots:
            daily_count[slot.date] += 1
            daily_minutes[slot.date] += slot.duration_minutes
        for external in external_by_employee.get(employee_id, []):
            local_day = external.start.astimezone(timezone).date()
            daily_count[local_day] += 1
            daily_minutes[local_day] += int(
                (external.end.timestamp() - external.start.timestamp()) // 60
            )
        for day, count in daily_count.items():
            if (
                snapshot.period_start <= day <= snapshot.period_end
                and count > employee.maximum_shifts_per_day
            ):
                errors.append(
                    f"DAILY_SHIFT_LIMIT:{employee_id}:{day.isoformat()}:{count}"
                )
        total_minutes = sum(
            minutes
            for day, minutes in daily_minutes.items()
            if snapshot.period_start <= day <= snapshot.period_end
        )
        if (
            employee.nominal_monthly_minutes is not None
            and employee.overtime_policy != "ALLOWED"
            and total_minutes > employee.nominal_monthly_minutes
        ):
            errors.append(
                "OVERTIME_POLICY_LIMIT:"
                f"{employee_id}:{employee.overtime_policy}:{total_minutes}:"
                f"{employee.nominal_monthly_minutes}"
            )
        if (
            employee.maximum_monthly_minutes is not None
            and total_minutes > employee.maximum_monthly_minutes
        ):
            errors.append(f"MONTHLY_MINUTE_LIMIT:{employee_id}:{total_minutes}")
        if employee.maximum_weekly_minutes is not None:
            weekly: dict[tuple[int, int], int] = defaultdict(int)
            for day, minutes in daily_minutes.items():
                calendar = day.isocalendar()
                weekly[(calendar.year, calendar.week)] += minutes
            period_weeks = {
                (day.isocalendar().year, day.isocalendar().week)
                for day in (
                    date.fromordinal(ordinal)
                    for ordinal in range(
                        snapshot.period_start.toordinal(),
                        snapshot.period_end.toordinal() + 1,
                    )
                )
            }
            for week, minutes in weekly.items():
                if week in period_weeks and minutes > employee.maximum_weekly_minutes:
                    errors.append(
                        f"WEEKLY_MINUTE_LIMIT:{employee_id}:{week[0]}-{week[1]}:{minutes}"
                    )
        if employee.maximum_consecutive_days is not None:
            worked = {day for day, count in daily_count.items() if count}
            window_size = employee.maximum_consecutive_days + 1
            first_day = snapshot.period_start - timedelta(
                days=employee.maximum_consecutive_days
            )
            last_day = snapshot.period_end + timedelta(
                days=employee.maximum_consecutive_days
            )
            extended_days = [
                date.fromordinal(ordinal)
                for ordinal in range(first_day.toordinal(), last_day.toordinal() + 1)
            ]
            for index in range(len(extended_days) - window_size + 1):
                window = extended_days[index : index + window_size]
                if not any(
                    snapshot.period_start <= day <= snapshot.period_end
                    for day in window
                ):
                    continue
                if all(day in worked for day in window):
                    errors.append(
                        f"CONSECUTIVE_DAY_LIMIT:{employee_id}:{window[-1].isoformat()}:{window_size}"
                    )
                    break

    locks = {(lock.slot_id, lock.employee_id) for lock in snapshot.locked_assignments}
    actual = {(item.slot_id, item.employee_id) for item in variant.assignments}
    for lock in sorted(locks - actual):
        errors.append(f"LOCK_NOT_PRESERVED:{lock[1]}:{lock[0]}")

    total_cost = sum(
        complete_quotes[(employee.id, slot.id)].cost_units
        for _assignment, employee, slot in selected
    )
    budget_results: list[BudgetValidationResult] = []
    for budget in snapshot.budgets:
        if budget.metric_type == "HOURS":
            spent = sum(slot.duration_minutes for _assignment, _employee, slot in selected if budget.matches(slot))
            limit = int(budget.limit_minutes or 0)
        else:
            spent = sum(
                sum(
                    component.cost_units
                    for component in complete_quotes[(employee.id, slot.id)].components
                    if budget.cost_basis == "FULL_EMPLOYER_COST"
                    or component.cost_category != "EMPLOYER_ONCOST"
                )
                for _assignment, employee, slot in selected
                if budget.matches(slot)
            )
            limit = budget.amount_minor * COST_SCALE
        exceeded = spent > limit
        scope = budget.scope()
        budget_results.append(
            BudgetValidationResult(
                budget_id=budget.id,
                currency=snapshot.currency,
                hard=budget.hard,
                scope=scope,
                spent_units=spent,
                limit_units=limit,
                exceeded=exceeded,
            )
        )
        if budget.hard and exceeded:
            scope_text = (
                ",".join(f"{name}={value}" for name, value in scope.items()) or "GLOBAL"
            )
            errors.append(f"HARD_BUDGET:{budget.id}:{scope_text}:{spent}:{limit}")

    if variant.metrics.get("UNFILLED") != len(unfilled):
        errors.append(
            f"UNFILLED_METRIC_MISMATCH:{variant.metrics.get('UNFILLED')}:{len(unfilled)}"
        )
    if variant.metrics.get("TOTAL_COST") != total_cost:
        errors.append(
            f"TOTAL_COST_METRIC_MISMATCH:{variant.metrics.get('TOTAL_COST')}:{total_cost}"
        )
    selected_map = {
        slot.id: (
            assignment_by_slot[slot.id].employee_id
            if slot.id in assignment_by_slot
            else None
        )
        for slot in slots
    }
    expected_hash = sha256_hex(selected_map)
    if variant.solution_hash != expected_hash:
        errors.append(f"SOLUTION_HASH_MISMATCH:{variant.solution_hash}:{expected_hash}")

    return ValidationReport(
        errors=tuple(errors),
        assignment_count=len(variant.assignments),
        unfilled_count=len(unfilled),
        total_cost_units=total_cost,
        budget_results=tuple(budget_results),
    )
