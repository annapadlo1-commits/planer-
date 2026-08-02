from __future__ import annotations

import argparse
import sys
from datetime import date, datetime, time, timedelta
from pathlib import Path
from time import perf_counter
from typing import Any
from zoneinfo import ZoneInfo

SOLVER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SOLVER_ROOT / "src"))

from grafik_solver.cp_sat_engine import (
    CpSatScheduleEngine,
    OptimizationError,
)
from grafik_solver.models import Snapshot
from grafik_solver.slots import Slot, generate_slots
from grafik_solver.validator import validate_variant

EMPLOYEE_COUNT = 76
SLOT_COUNT = 1425
STRATEGY_COUNT = 3
TIMEZONE = ZoneInfo("Europe/Warsaw")
PROFILES = (
    ("morning", time(6, 0), time(14, 0), False),
    ("middle", time(14, 0), time(22, 0), False),
    ("night", time(22, 0), time(6, 0), True),
)


def _dates() -> list[date]:
    return [date(2026, 8, day) for day in range(1, 32)]


def _timestamp(day: date, clock: time, day_offset: int = 0) -> str:
    return datetime.combine(
        day + timedelta(days=day_offset), clock, TIMEZONE
    ).isoformat()


def _slot_payload(slot: Slot) -> dict[str, Any]:
    return {
        "slotId": slot.id,
        "demandId": slot.demand_id,
        "occurrenceId": slot.occurrence_id,
        "seatIndex": slot.seat_index + 1,
        "date": slot.date.isoformat(),
        "shiftTemplateId": slot.shift_template_id,
        "locationId": slot.location_id,
        "roleId": slot.role_id,
        "dutyIds": list(slot.duty_ids),
        "start": slot.start.isoformat(),
        "end": slot.end.isoformat(),
        "durationMinutes": slot.duration_minutes,
    }


def generate_synthetic_snapshot() -> dict[str, Any]:
    """Build a deterministic full-scale snapshot containing no production data."""
    days = _dates()
    roles = [
        {"id": f"synthetic-role-{index}", "code": f"ROLE_{index}"} for index in range(5)
    ]
    duties = [{"id": "synthetic-duty-common", "code": "COMMON"}] + [
        {"id": f"synthetic-duty-{index}", "code": f"DUTY_{index}"} for index in range(5)
    ]
    locations = [
        {
            "id": f"synthetic-location-{index}",
            "code": f"LOCATION_{index}",
            "timezone": "Europe/Warsaw",
        }
        for index in range(5)
    ]

    shift_templates: list[dict[str, Any]] = []
    demand: list[dict[str, Any]] = []
    group: dict[tuple[int, int], tuple[str, str, list[str]]] = {}
    for location_index in range(5):
        for profile_index, (profile, starts_at, ends_at, ends_next_day) in enumerate(
            PROFILES
        ):
            role_index = (location_index * len(PROFILES) + profile_index) % len(roles)
            template_id = f"synthetic-shift-{location_index}-{profile}"
            role_id = f"synthetic-role-{role_index}"
            duty_ids = ["synthetic-duty-common", f"synthetic-duty-{role_index}"]
            shift_templates.append(
                {
                    "id": template_id,
                    "locationId": f"synthetic-location-{location_index}",
                    "startTime": starts_at.isoformat(timespec="minutes"),
                    "endTime": ends_at.isoformat(timespec="minutes"),
                    "endsNextDay": ends_next_day,
                    "weekdays": [1, 2, 3, 4, 5, 6, 7],
                }
            )
            demand.append(
                {
                    "id": f"synthetic-demand-{location_index}-{profile}",
                    "shiftTemplateId": template_id,
                    "roleId": role_id,
                    "dutyIds": duty_ids,
                    "requiredCount": 3,
                    "dates": [day.isoformat() for day in days],
                }
            )
            group[(location_index, profile_index)] = (
                template_id,
                role_id,
                duty_ids,
            )

    extra_template, extra_role, extra_duties = group[(0, 0)]
    demand.append(
        {
            "id": "synthetic-demand-seasonal-extra",
            "shiftTemplateId": extra_template,
            "roleId": extra_role,
            "dutyIds": extra_duties,
            "requiredCount": 1,
            "dates": [day.isoformat() for day in days[:30]],
        }
    )

    employees: list[dict[str, Any]] = []
    availability: list[dict[str, Any]] = []
    employee_profiles: dict[str, int] = {}
    for location_index in range(5):
        for profile_index, (profile, _start, _end, _overnight) in enumerate(PROFILES):
            template_id, role_id, duty_ids = group[(location_index, profile_index)]
            for member_index in range(5):
                employee_id = (
                    f"synthetic-employee-{location_index}-{profile}-{member_index}"
                )
                base_rate = 2200 + member_index * 90 + profile_index * 120
                contract_code = ("UOP", "B2B", "UZ")[member_index % 3]
                employee_profiles[employee_id] = profile_index
                employees.append(
                    {
                        "id": employee_id,
                        "roleIds": [role_id],
                        "roleGrants": [{"roleId": role_id}],
                        "dutyIds": duty_ids,
                        "dutyGrants": [
                            {
                                "dutyId": duty_id,
                                "roleId": role_id,
                                "locationId": f"synthetic-location-{location_index}",
                            }
                            for duty_id in duty_ids
                        ],
                        "locationIds": [f"synthetic-location-{location_index}"],
                        "locationGrants": [
                            {
                                "locationId": f"synthetic-location-{location_index}",
                                "standardAllowed": True,
                                "overtimeAllowed": False,
                            }
                        ],
                        "homeLocationIds": [f"synthetic-location-{location_index}"],
                        "baseHourlyRateMinor": base_rate,
                        "contractCode": contract_code,
                        "payRatePeriods": [
                            {
                                "validFrom": days[0].isoformat(),
                                "baseRateMinor": base_rate,
                                "contractCode": contract_code,
                            }
                        ],
                        "nominalMonthlyMinutes": 18 * 480,
                        "maximumMonthlyMinutes": 21 * 480,
                        "maximumWeeklyMinutes": 6 * 480,
                        "maximumShiftsPerDay": 1,
                        "maximumConsecutiveDays": 6,
                        "minimumRestMinutes": 660,
                        "preferredShiftTemplateIds": [template_id],
                        "preferredLocationIds": [
                            f"synthetic-location-{location_index}"
                        ],
                        "softDayOffDates": [
                            days[(member_index * 5 + profile_index) % 31].isoformat(),
                            days[
                                (member_index * 7 + location_index + 11) % 31
                            ].isoformat(),
                        ],
                    }
                )

    flex_id = "synthetic-employee-flex-75"
    employee_profiles[flex_id] = 0
    employees.append(
        {
            "id": flex_id,
            "roleIds": [extra_role],
            "roleGrants": [{"roleId": extra_role}],
            "dutyIds": extra_duties,
            "dutyGrants": [
                {
                    "dutyId": duty_id,
                    "roleId": extra_role,
                    "locationId": "synthetic-location-0",
                }
                for duty_id in extra_duties
            ],
            "locationIds": ["synthetic-location-0"],
            "locationGrants": [
                {
                    "locationId": "synthetic-location-0",
                    "standardAllowed": True,
                    "overtimeAllowed": False,
                }
            ],
            "homeLocationIds": ["synthetic-location-0"],
            "baseHourlyRateMinor": 3100,
            "contractCode": "FLEX",
            "payRatePeriods": [
                {
                    "validFrom": days[0].isoformat(),
                    "baseRateMinor": 3100,
                    "contractCode": "FLEX",
                }
            ],
            "nominalMonthlyMinutes": 10 * 480,
            "maximumMonthlyMinutes": 21 * 480,
            "maximumWeeklyMinutes": 6 * 480,
            "maximumShiftsPerDay": 1,
            "maximumConsecutiveDays": 6,
            "minimumRestMinutes": 660,
            "preferredShiftTemplateIds": [extra_template],
            "preferredLocationIds": ["synthetic-location-0"],
            "softDayOffDates": [],
        }
    )

    for employee in employees:
        profile_index = employee_profiles[employee["id"]]
        for day in days:
            if profile_index == 0:
                windows = (
                    (time(5, 30), time(14, 30), 0),
                    (time(18, 0), time(19, 0), 0),
                )
            elif profile_index == 1:
                windows = (
                    (time(2, 0), time(3, 0), 0),
                    (time(13, 30), time(22, 30), 0),
                )
            else:
                windows = (
                    (time(12, 0), time(13, 0), 0),
                    (time(21, 30), time(6, 30), 1),
                )
            for window_start, window_end, end_offset in windows:
                availability.append(
                    {
                        "employeeId": employee["id"],
                        "start": _timestamp(day, window_start),
                        "end": _timestamp(day, window_end, end_offset),
                    }
                )

    night_templates = [
        template["id"]
        for template in shift_templates
        if template["id"].endswith("-night")
    ]
    raw: dict[str, Any] = {
        "schemaVersion": 2,
        "runId": "synthetic-run-full-scale",
        "matrixVersionId": "synthetic-matrix-full-scale",
        "scenarioId": "synthetic-scenario-seasonal",
        "periodStart": days[0].isoformat(),
        "periodEnd": days[-1].isoformat(),
        "currency": "PLN",
        "settings": {
            "timezone": "Europe/Warsaw",
            "missingAvailabilityMeansAvailable": False,
            "defaultMinimumRestMinutes": 660,
            "requireOptimal": True,
            "randomSeed": 20260801,
        },
        "strategies": [
            {
                "id": "synthetic-strategy-cost",
                "code": "COST",
                "label": "Synthetic cost",
                "sortOrder": 0,
                "timeLimitSeconds": 25,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "TOTAL_COST",
                        "weight": 1,
                        "direction": "MIN",
                    }
                ],
            },
            {
                "id": "synthetic-strategy-balanced",
                "code": "BALANCED",
                "label": "Synthetic balanced",
                "sortOrder": 1,
                "timeLimitSeconds": 25,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "OVERTIME_MINUTES",
                        "weight": 1,
                        "direction": "MIN",
                    },
                    {
                        "tier": 2,
                        "metric": "LOAD_SPREAD_MINUTES",
                        "weight": 1,
                        "direction": "MIN",
                    },
                    {
                        "tier": 3,
                        "metric": "TOTAL_COST",
                        "weight": 1,
                        "direction": "MIN",
                    },
                ],
            },
            {
                "id": "synthetic-strategy-preference",
                "code": "PREFERENCE",
                "label": "Synthetic preference",
                "sortOrder": 2,
                "timeLimitSeconds": 25,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "PREFERENCE_VIOLATIONS",
                        "weight": 1,
                        "direction": "MIN",
                    },
                    {
                        "tier": 2,
                        "metric": "TOTAL_COST",
                        "weight": 1,
                        "direction": "MIN",
                    },
                ],
            },
        ],
        "roles": roles,
        "duties": duties,
        "locations": locations,
        "shiftTemplates": shift_templates,
        "demand": demand,
        "employees": employees,
        "availabilityWindows": availability,
        "hardBlocks": [],
        "externalAssignments": [],
        "lockedAssignments": [],
        "baselineAssignments": [],
        "payRules": [
            {
                "id": "synthetic-pay-weekend",
                "calculationType": "PERCENT_BASE",
                "values": {"percentBasisPoints": 2000},
                "conditions": [],
                "dayMask": [6, 7],
                "stackingGroup": "weekend",
                "stackingMode": "STACK",
                "priority": 10,
                "active": True,
            },
            {
                "id": "synthetic-pay-night",
                "calculationType": "PER_HOUR",
                "values": {"rateMinorPerHour": 500},
                "conditions": [
                    {
                        "field": "shift_template_id",
                        "operator": "IN",
                        "value": night_templates,
                    }
                ],
                "stackingGroup": "night",
                "stackingMode": "STACK",
                "priority": 20,
                "active": True,
            },
            {
                "id": "synthetic-pay-monthly-threshold",
                "calculationType": "MONTHLY_THRESHOLD_PER_HOUR",
                "values": {"thresholdMinutes": 7200, "rateMinorPerHour": 300},
                "conditions": [],
                "stackingGroup": "monthly-threshold",
                "stackingMode": "STACK",
                "priority": 30,
                "active": True,
            },
        ],
        "budgets": [
            {
                "id": "synthetic-budget-global",
                "amountMinor": 40000000,
                "hard": True,
            },
            {
                "id": "synthetic-budget-location-0",
                "amountMinor": 10000000,
                "hard": True,
                "locationId": "synthetic-location-0",
            },
            {
                "id": "synthetic-budget-role-0",
                "amountMinor": 12000000,
                "hard": True,
                "roleId": "synthetic-role-0",
            },
            {
                "id": "synthetic-budget-duty-0",
                "amountMinor": 12000000,
                "hard": True,
                "dutyId": "synthetic-duty-0",
            },
        ],
    }
    initial = Snapshot.from_dict(raw)
    slots = generate_slots(initial)
    if len(employees) != EMPLOYEE_COUNT or len(slots) != SLOT_COUNT:
        raise AssertionError(
            f"Synthetic scale drift: employees={len(employees)}, slots={len(slots)}"
        )
    raw["slots"] = [_slot_payload(slot) for slot in slots]
    return raw


class _ProgressTimer:
    def __init__(self, started_at: float):
        self.started_at = started_at
        self.strategy_started: dict[str, float] = {}
        self.strategy_elapsed: dict[str, float] = {}
        self.minimum_unfilled: int | None = None

    def __call__(self, progress: dict[str, Any]) -> None:
        if "minimumUnfilled" in progress:
            self.minimum_unfilled = int(progress["minimumUnfilled"])
        strategy_id = progress.get("strategyId")
        if not strategy_id:
            return
        now = perf_counter()
        self.strategy_started.setdefault(str(strategy_id), now)
        if progress.get("strategyProgress") == 100:
            self.strategy_elapsed[str(strategy_id)] = (
                now - self.strategy_started[str(strategy_id)]
            )


def run_benchmark(total_seconds: int, finalization_reserve_seconds: int) -> int:
    raw = generate_synthetic_snapshot()
    snapshot = Snapshot.from_dict(raw)
    slots = generate_slots(snapshot)
    started = perf_counter()
    progress = _ProgressTimer(started)
    completed_variants = []
    engine = CpSatScheduleEngine(
        max_total_seconds=total_seconds,
        finalization_reserve_seconds=finalization_reserve_seconds,
        progress_callback=progress,
        result_callback=completed_variants.append,
    )
    print(
        "SYNTHETIC_INPUT",
        f"employees={len(snapshot.employees)}",
        f"slots={len(slots)}",
        f"strategies={len(snapshot.strategies)}",
        f"availability_windows={len(snapshot.availability_windows)}",
        f"pay_rules={len(snapshot.pay_rules)}",
        f"budgets={len(snapshot.budgets)}",
        f"currency={snapshot.currency}",
        f"total_budget_seconds={total_seconds}",
        f"finalization_reserve_seconds={finalization_reserve_seconds}",
        flush=True,
    )
    try:
        variants = engine.solve(snapshot)
    except OptimizationError as exc:
        _print_results(snapshot, slots, completed_variants, progress)
        print(
            "SYNTHETIC_INCOMPLETE",
            f"elapsed_seconds={perf_counter() - started:.3f}",
            f"status={type(exc).__name__}",
            f"completed_strategies={len(completed_variants)}",
            f"proven_minimum_unfilled={progress.minimum_unfilled}",
            "hard_violations=not_accepted",
            "assignments=not_materialized",
            f"message={exc}",
            flush=True,
        )
        return 2

    total_elapsed = perf_counter() - started
    _print_results(snapshot, slots, variants, progress)
    print("SYNTHETIC_TOTAL", f"elapsed_seconds={total_elapsed:.3f}", flush=True)
    return 0


def _print_results(
    snapshot: Snapshot,
    slots: tuple[Slot, ...],
    variants: list[Any] | tuple[Any, ...],
    progress: _ProgressTimer,
) -> None:
    for variant in variants:
        report = validate_variant(snapshot, variant, slots)
        elapsed = progress.strategy_elapsed.get(variant.strategy_id, 0.0)
        print(
            "SYNTHETIC_RESULT",
            f"strategy={variant.strategy_code}",
            f"elapsed_seconds={elapsed:.3f}",
            f"optimal={variant.optimal}",
            f"hard_violations={len(report.errors)}",
            f"assignments={report.assignment_count}",
            f"unfilled={report.unfilled_count}",
            f"total_cost_units={report.total_cost_units}",
            f"exceeded_budgets={sum(item.exceeded for item in report.budget_results)}",
            flush=True,
        )
        report.raise_for_errors()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--total-seconds",
        type=int,
        default=120,
        help="Hard wall-clock budget for the whole engine call (default: 120).",
    )
    parser.add_argument(
        "--finalization-reserve-seconds",
        type=int,
        default=5,
        help="Part of the total budget reserved after CP-SAT (default: 5).",
    )
    args = parser.parse_args()
    if args.total_seconds <= 0:
        parser.error("--total-seconds must be positive")
    if not 0 <= args.finalization_reserve_seconds < args.total_seconds:
        parser.error("finalization reserve must be nonnegative and below total seconds")
    return run_benchmark(args.total_seconds, args.finalization_reserve_seconds)


if __name__ == "__main__":
    raise SystemExit(main())
