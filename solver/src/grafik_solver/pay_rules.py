from __future__ import annotations

from collections import defaultdict
from collections.abc import Iterable, Mapping
from dataclasses import dataclass
from datetime import datetime, time, timedelta
from decimal import ROUND_HALF_UP, Decimal
from typing import Any
from zoneinfo import ZoneInfo

from .models import Employee, PayCondition, PayRule, Snapshot, SnapshotError
from .slots import Slot

COST_SCALE = 60
STATIC_CALCULATION_TYPES = {
    "FIXED_PER_SHIFT",
    "PER_HOUR",
    "PERCENT_BASE",
    "MULTIPLIER",
    "SHIFT_DURATION_THRESHOLD_PER_HOUR",
}
BASE_OVERRIDE_CALCULATION_TYPE = "BASE_RATE_OVERRIDE"
DYNAMIC_CALCULATION_TYPES = {"MONTHLY_THRESHOLD_PER_HOUR"}
SUPPORTED_CALCULATION_TYPES = STATIC_CALCULATION_TYPES | DYNAMIC_CALCULATION_TYPES | {BASE_OVERRIDE_CALCULATION_TYPE}
SUPPORTED_OPERATORS = {
    "EQ",
    "NE",
    "IN",
    "NOT_IN",
    "CONTAINS",
    "CONTAINS_ANY",
    "CONTAINS_ALL",
    "GTE",
    "LTE",
    "OVERLAPS_TIME",
}


@dataclass(frozen=True)
class PayComponent:
    rule_id: str
    calculation_type: str
    cost_units: int
    cost_category: str = "WAGE"

    def to_dict(self) -> dict[str, Any]:
        return {
            "ruleId": self.rule_id,
            "calculationType": self.calculation_type,
            "costUnits": self.cost_units,
            "costCategory": self.cost_category,
        }


@dataclass(frozen=True)
class PayQuote:
    cost_units: int
    components: tuple[PayComponent, ...]


def units_to_minor(cost_units: int) -> int:
    return int(
        (Decimal(cost_units) / Decimal(COST_SCALE)).quantize(
            Decimal(1), rounding=ROUND_HALF_UP
        )
    )


def _value(
    values: Mapping[str, Any], camel: str, snake: str, *, default: Any = None
) -> Any:
    if camel in values:
        return values[camel]
    if snake in values:
        return values[snake]
    return default


def _integer(
    values: Mapping[str, Any], camel: str, snake: str, *, minimum: int = 0
) -> int:
    raw = _value(values, camel, snake)
    try:
        parsed = int(raw)
    except (TypeError, ValueError) as exc:
        raise SnapshotError(f"Pay rule value {camel} must be an integer") from exc
    if parsed < minimum:
        raise SnapshotError(f"Pay rule value {camel} must be at least {minimum}")
    return parsed


def _minute(value: Any) -> int:
    parsed = time.fromisoformat(str(value))
    return parsed.hour * 60 + parsed.minute


def _postgres_local_timestamp(day: Any, minute: int, timezone: ZoneInfo) -> datetime:
    naive = datetime.combine(day, time(minute // 60, minute % 60))
    # PostgreSQL resolves ambiguous/nonexistent wall times with the standard
    # offset. For both a fold and a gap this is the later UTC candidate.
    candidates = (
        naive.replace(tzinfo=timezone, fold=0),
        naive.replace(tzinfo=timezone, fold=1),
    )
    return max(candidates, key=lambda candidate: candidate.timestamp())


def _time_overlap_minutes(slot: Slot, value: Any, timezone: ZoneInfo) -> int:
    if not isinstance(value, Mapping):
        raise SnapshotError("OVERLAPS_TIME expects {start, end}")
    start_raw = value.get("start")
    end_raw = value.get("end")
    if start_raw is None or end_raw is None:
        raise SnapshotError("OVERLAPS_TIME expects start and end")
    rule_start = _minute(start_raw)
    rule_end = _minute(end_raw)
    if rule_end <= rule_start:
        rule_end += 24 * 60
    local_start = slot.start.astimezone(timezone)
    local_end = slot.end.astimezone(timezone)
    first_day = local_start.date() - timedelta(days=1)
    last_day = local_end.date() + timedelta(days=1)
    total_seconds = 0.0
    day = first_day
    while day <= last_day:
        window_start = _postgres_local_timestamp(day, rule_start, timezone)
        end_day = day + timedelta(days=1) if rule_end >= 24 * 60 else day
        window_end = _postgres_local_timestamp(end_day, rule_end % (24 * 60), timezone)
        overlap_start = max(slot.start, window_start)
        overlap_end = min(slot.end, window_end)
        total_seconds += max(overlap_end.timestamp() - overlap_start.timestamp(), 0.0)
        day += timedelta(days=1)
    return int(total_seconds // 60)


def _time_overlap(slot: Slot, value: Any, timezone: ZoneInfo) -> bool:
    return _time_overlap_minutes(slot, value, timezone) > 0


def _facts(snapshot: Snapshot, employee: Employee, slot: Slot) -> dict[str, Any]:
    _base_rate_minor, contract_code = employee.pay_rate_on(slot.date)
    return {
        "role_id": slot.role_id,
        "duty_ids": frozenset(slot.duty_ids),
        "location_id": slot.location_id,
        "shift_template_id": slot.shift_template_id,
        "weekday": slot.date.isoweekday(),
        "scenario_id": snapshot.scenario_id,
        "employee_id": employee.id,
        "contract_code": contract_code,
        "duration_minutes": slot.duration_minutes,
        "local_time": slot.start,
    }


def _matches_condition(
    condition: PayCondition, facts: Mapping[str, Any], slot: Slot, timezone: ZoneInfo
) -> bool:
    operator = condition.operator
    if operator not in SUPPORTED_OPERATORS:
        raise SnapshotError(f"Unsupported pay condition operator: {operator}")
    if condition.field not in facts:
        raise SnapshotError(f"Unsupported pay condition field: {condition.field}")
    actual = facts[condition.field]
    expected = condition.value
    if operator == "OVERLAPS_TIME":
        return _time_overlap(slot, expected, timezone)
    if operator == "EQ":
        return actual == expected
    if operator == "NE":
        return actual != expected
    if operator == "IN":
        return actual in expected
    if operator == "NOT_IN":
        return actual not in expected
    if operator == "CONTAINS":
        return expected in actual
    if operator == "CONTAINS_ANY":
        return bool(set(actual).intersection(expected))
    if operator == "CONTAINS_ALL":
        return set(expected).issubset(actual)
    if operator == "GTE":
        return actual >= expected
    if operator == "LTE":
        return actual <= expected
    raise AssertionError("operator validated above")


def rule_matches(
    snapshot: Snapshot, rule: PayRule, employee: Employee, slot: Slot
) -> bool:
    if not rule.active:
        return False
    if rule.effective_from and slot.date < rule.effective_from:
        return False
    if rule.effective_to and slot.date > rule.effective_to:
        return False
    timezone = slot.start.tzinfo or ZoneInfo(snapshot.settings.timezone)
    facts = _facts(snapshot, employee, slot)
    return all(
        _matches_condition(condition, facts, slot, timezone)
        for condition in rule.conditions
    )


def _pay_window(rule: PayRule) -> Any | None:
    windows = [
        condition.value
        for condition in rule.conditions
        if condition.field == "local_time" and condition.operator == "OVERLAPS_TIME"
    ]
    if len(windows) > 1:
        raise SnapshotError(f"Pay rule {rule.id} contains multiple local-time windows")
    return windows[0] if windows else None


def _static_cost_units(
    rule: PayRule, employee: Employee, slot: Slot, timezone: ZoneInfo
) -> int:
    values = rule.values
    calculation = rule.calculation_type
    base_rate_minor, _contract_code = employee.pay_rate_on(slot.date)
    window = _pay_window(rule)
    chargeable_minutes = (
        _time_overlap_minutes(slot, window, timezone)
        if window is not None
        else slot.duration_minutes
    )
    base_units = base_rate_minor * chargeable_minutes
    if calculation == "FIXED_PER_SHIFT":
        return _integer(values, "amountMinor", "amount_minor") * COST_SCALE
    if calculation == "PER_HOUR":
        return (
            _integer(values, "rateMinorPerHour", "rate_minor_per_hour")
            * chargeable_minutes
        )
    if calculation == "PERCENT_BASE":
        basis_points = _integer(values, "percentBasisPoints", "percent_basis_points")
        return int(
            (Decimal(base_units) * Decimal(basis_points) / Decimal(10_000)).quantize(
                Decimal(1), rounding=ROUND_HALF_UP
            )
        )
    if calculation == "MULTIPLIER":
        multiplier = _integer(
            values, "multiplierBasisPoints", "multiplier_basis_points"
        )
        if multiplier < 10_000:
            raise SnapshotError("MULTIPLIER cannot reduce the base rate")
        return int(
            (
                Decimal(base_units) * Decimal(multiplier - 10_000) / Decimal(10_000)
            ).quantize(Decimal(1), rounding=ROUND_HALF_UP)
        )
    if calculation == "SHIFT_DURATION_THRESHOLD_PER_HOUR":
        threshold = _integer(values, "thresholdMinutes", "threshold_minutes")
        rate = _integer(values, "rateMinorPerHour", "rate_minor_per_hour")
        return max(chargeable_minutes - threshold, 0) * rate
    raise SnapshotError(f"Unsupported static pay calculation: {calculation}")


def validate_pay_rules(snapshot: Snapshot) -> None:
    group_modes: dict[str, str] = {}
    for rule in snapshot.pay_rules:
        if rule.calculation_type not in SUPPORTED_CALCULATION_TYPES:
            raise SnapshotError(
                f"Unsupported pay calculation type: {rule.calculation_type}"
            )
        if rule.calculation_type == BASE_OVERRIDE_CALCULATION_TYPE:
            _integer(rule.values, "rateMinorPerHour", "rate_minor_per_hour")
        if rule.stacking_mode not in {"STACK", "MAX", "FIRST"}:
            raise SnapshotError(f"Unsupported stacking mode: {rule.stacking_mode}")
        previous_mode = group_modes.setdefault(rule.stacking_group, rule.stacking_mode)
        if previous_mode != rule.stacking_mode:
            raise SnapshotError(
                f"Pay stacking group {rule.stacking_group} has inconsistent modes"
            )
        if rule.calculation_type in DYNAMIC_CALCULATION_TYPES:
            if rule.stacking_mode != "STACK":
                raise SnapshotError(
                    "Monthly threshold rules currently require STACK mode"
                )
            _integer(rule.values, "thresholdMinutes", "threshold_minutes")
            _integer(rule.values, "rateMinorPerHour", "rate_minor_per_hour")
        window = _pay_window(rule)
        if window is not None and rule.calculation_type in {
            "SHIFT_DURATION_THRESHOLD_PER_HOUR",
            "MONTHLY_THRESHOLD_PER_HOUR",
        }:
            raise SnapshotError(
                f"Pay rule {rule.id} cannot combine a threshold with "
                "a local-time window"
            )


def applicable_static_rules(
    snapshot: Snapshot, employee: Employee, slot: Slot
) -> tuple[tuple[PayRule, int], ...]:
    candidates: list[tuple[PayRule, int]] = []
    timezone = (
        slot.start.tzinfo
        if isinstance(slot.start.tzinfo, ZoneInfo)
        else ZoneInfo(snapshot.settings.timezone)
    )
    for rule in snapshot.pay_rules:
        if rule.calculation_type not in STATIC_CALCULATION_TYPES:
            continue
        if rule_matches(snapshot, rule, employee, slot):
            candidates.append(
                (rule, _static_cost_units(rule, employee, slot, timezone))
            )

    groups: dict[str, list[tuple[PayRule, int]]] = defaultdict(list)
    for item in candidates:
        groups[item[0].stacking_group].append(item)
    selected: list[tuple[PayRule, int]] = []
    for group in sorted(groups):
        items = sorted(groups[group], key=lambda item: (item[0].priority, item[0].id))
        mode = items[0][0].stacking_mode
        if mode == "STACK":
            selected.extend(items)
        elif mode == "FIRST":
            selected.append(items[0])
        elif mode == "MAX":
            selected.append(
                max(items, key=lambda item: (item[1], -item[0].priority, item[0].id))
            )
    return tuple(selected)


def quote_assignment(snapshot: Snapshot, employee: Employee, slot: Slot) -> PayQuote:
    base_rate_minor, _contract_code = employee.pay_rate_on(slot.date)
    overrides = sorted(
        (
            rule for rule in snapshot.pay_rules
            if rule.calculation_type == BASE_OVERRIDE_CALCULATION_TYPE
            and rule_matches(snapshot, rule, employee, slot)
        ),
        key=lambda rule: (rule.priority, rule.id),
    )
    if len(overrides) > 1:
        raise SnapshotError(
            f"Multiple approved base-rate overrides match {employee.id}/{slot.id}"
        )
    if overrides:
        base_rate_minor = _integer(
            overrides[0].values, "rateMinorPerHour", "rate_minor_per_hour"
        )
    base_units = base_rate_minor * slot.duration_minutes
    components = [
        PayComponent(
            rule_id=(overrides[0].id if overrides else "BASE"),
            calculation_type=(BASE_OVERRIDE_CALCULATION_TYPE if overrides else "BASE_HOURLY"),
            cost_units=base_units,
        )
    ]
    for rule, cost_units in applicable_static_rules(snapshot, employee, slot):
        components.append(
            PayComponent(
                rule_id=rule.id,
                calculation_type=rule.calculation_type,
                cost_units=cost_units,
                cost_category=rule.cost_category,
            )
        )
    return PayQuote(
        cost_units=sum(component.cost_units for component in components),
        components=tuple(components),
    )


def matching_monthly_rules(
    snapshot: Snapshot, employee: Employee, slot: Slot
) -> tuple[PayRule, ...]:
    return tuple(
        rule
        for rule in snapshot.pay_rules
        if rule.calculation_type == "MONTHLY_THRESHOLD_PER_HOUR"
        and rule_matches(snapshot, rule, employee, slot)
    )


def monthly_threshold_cost_units(
    rule: PayRule, selected_minutes: int, employee: Employee | None = None
) -> tuple[int, PayComponent]:
    threshold_source = str(rule.values.get("thresholdSource", rule.values.get("threshold_source", "FIXED"))).upper()
    threshold = (
        employee.nominal_monthly_minutes
        if threshold_source == "EMPLOYEE_NOMINAL" and employee is not None
        else _integer(rule.values, "thresholdMinutes", "threshold_minutes")
    )
    if threshold is None:
        raise SnapshotError("Employee nominal is required by an overtime pay rule")
    rate = _integer(rule.values, "rateMinorPerHour", "rate_minor_per_hour")
    cost_units = max(selected_minutes - threshold, 0) * rate
    return cost_units, PayComponent(
        rule_id=rule.id,
        calculation_type=rule.calculation_type,
        cost_units=cost_units,
        cost_category=rule.cost_category,
    )


def quote_variant_dynamic_components(
    snapshot: Snapshot,
    selected: Iterable[tuple[Employee, Slot]],
) -> tuple[PayComponent, ...]:
    minutes_by_rule_employee: dict[tuple[str, str], int] = defaultdict(int)
    rules = {rule.id: rule for rule in snapshot.pay_rules}
    for employee, slot in selected:
        for rule in matching_monthly_rules(snapshot, employee, slot):
            minutes_by_rule_employee[(rule.id, employee.id)] += slot.duration_minutes
    components: list[PayComponent] = []
    employees = {employee.id: employee for employee in snapshot.employees}
    for (rule_id, employee_id), minutes in sorted(minutes_by_rule_employee.items()):
        cost_units, component = monthly_threshold_cost_units(rules[rule_id], minutes, employees[employee_id])
        if cost_units:
            components.append(component)
    return tuple(components)


def quote_selected_assignments(
    snapshot: Snapshot,
    selected: Iterable[tuple[Employee, Slot]],
) -> dict[tuple[str, str], PayQuote]:
    """Quote assignments and allocate aggregate additions deterministically."""
    selected_items = sorted(
        selected, key=lambda item: (item[0].id, item[1].start, item[1].id)
    )
    components_by_key: dict[tuple[str, str], list[PayComponent]] = {}
    for employee, slot in selected_items:
        quote = quote_assignment(snapshot, employee, slot)
        components_by_key[(employee.id, slot.id)] = list(quote.components)

    rules = {
        rule.id: rule
        for rule in snapshot.pay_rules
        if rule.calculation_type == "MONTHLY_THRESHOLD_PER_HOUR"
    }
    for employee_id in sorted({employee.id for employee, _slot in selected_items}):
        employee_items = [
            (employee, slot)
            for employee, slot in selected_items
            if employee.id == employee_id
        ]
        for rule_id, rule in sorted(rules.items()):
            matching = [
                (employee, slot)
                for employee, slot in employee_items
                if rule_matches(snapshot, rule, employee, slot)
            ]
            threshold_source = str(rule.values.get("thresholdSource", rule.values.get("threshold_source", "FIXED"))).upper()
            threshold = employee_items[0][0].nominal_monthly_minutes if threshold_source == "EMPLOYEE_NOMINAL" else _integer(rule.values, "thresholdMinutes", "threshold_minutes")
            if threshold is None:
                raise SnapshotError("Employee nominal is required by an overtime pay rule")
            rate = _integer(rule.values, "rateMinorPerHour", "rate_minor_per_hour")
            cumulative = 0
            for employee, slot in matching:
                before = max(cumulative - threshold, 0)
                cumulative += slot.duration_minutes
                after = max(cumulative - threshold, 0)
                chargeable_minutes = after - before
                if chargeable_minutes:
                    components_by_key[(employee.id, slot.id)].append(
                        PayComponent(
                            rule_id=rule_id,
                            calculation_type=rule.calculation_type,
                            cost_units=chargeable_minutes * rate,
                            cost_category=rule.cost_category,
                        )
                    )

    return {
        key: PayQuote(
            cost_units=sum(component.cost_units for component in components),
            components=tuple(components),
        )
        for key, components in components_by_key.items()
    }
