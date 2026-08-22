from __future__ import annotations

import sys
import unittest
from collections import Counter
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.canonical import sha256_hex
from grafik_solver.cp_sat_engine import (
    CpSatScheduleEngine,
    month_employee_rotation_priority,
)
from grafik_solver.eligibility import EligibilityIndex
from grafik_solver.models import Assignment, Snapshot, VariantResult
from grafik_solver.pay_rules import quote_selected_assignments
from grafik_solver.slots import generate_slots
from grafik_solver.validator import validate_variant


def symmetric_remainder_raw(
    *,
    month: str = "2026-08",
    reverse_employees: bool = False,
    random_seed: int = 1,
    employee_count: int = 20,
    days_in_month: int = 31,
    employee_specific_pay_rule: bool = False,
) -> dict[str, object]:
    dates = [f"{month}-{day:02d}" for day in range(1, days_in_month + 1)]
    employees = [
        {
            "id": f"employee-{index:03d}",
            "roleIds": ["role-a"],
            "dutyIds": ["duty-a"],
            "locationIds": ["location-a"],
            "baseHourlyRateMinor": 0,
            "contractCode": "UOP",
            "overtimePolicy": "ALLOWED",
            "nominalMonthlyMinutes": 240,
            "maximumMonthlyMinutes": 240,
            "maximumWeeklyMinutes": 10_000,
            "maximumShiftsPerDay": 1,
            "maximumConsecutiveDays": 31,
            "minimumRestMinutes": 0,
        }
        for index in range(employee_count)
    ]
    if reverse_employees:
        employees.reverse()
    return {
        "schemaVersion": 2,
        "runId": f"b4f167-{month}-{random_seed}",
        "matrixVersionId": "b4f167-matrix",
        "scenarioId": "b4f167-scenario",
        "periodStart": dates[0],
        "periodEnd": dates[-1],
        "currency": "PLN",
        "settings": {
            "timezone": "Europe/Warsaw",
            "missingAvailabilityMeansAvailable": True,
            "defaultMinimumRestMinutes": 0,
            "requireOptimal": True,
            "randomSeed": random_seed,
        },
        "strategies": [
            {
                "id": "strategy-preferences",
                "code": "PREFERENCES",
                "label": "Preferencje i rowny podzial",
                "sortOrder": 0,
                "timeLimitSeconds": 60,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "PREFERENCE_VIOLATIONS",
                        "weight": 1,
                        "direction": "MIN",
                    }
                ],
            }
        ],
        "roles": [{"id": "role-a", "code": "A"}],
        "duties": [{"id": "duty-a", "code": "A"}],
        "locations": [{"id": "location-a", "code": "A"}],
        "shiftTemplates": [
            {
                "id": "shift-a",
                "locationId": "location-a",
                "startTime": "08:00",
                "endTime": "09:00",
                "weekdays": [1, 2, 3, 4, 5, 6, 7],
            }
        ],
        "demand": [
            {
                "id": "demand-a",
                "shiftTemplateId": "shift-a",
                "roleId": "role-a",
                "dutyIds": ["duty-a"],
                "requiredCount": 2,
                "dates": dates,
            }
        ],
        "employees": employees,
        "availabilityWindows": [],
        "workPatterns": [],
        "hardBlocks": [],
        "externalAssignments": [],
        "lockedAssignments": [],
        "baselineAssignments": [],
        "payRules": (
            [
                {
                    "id": "employee-specific",
                    "calculationType": "FIXED_PER_SHIFT",
                    "values": {"amountMinor": 100},
                    "conditions": [
                        {
                            "field": "employee_id",
                            "operator": "EQ",
                            "value": "employee-000",
                        }
                    ],
                    "stackingGroup": "employee-specific",
                    "stackingMode": "STACK",
                    "priority": 0,
                    "active": True,
                }
            ]
            if employee_specific_pay_rule
            else []
        ),
        "budgets": [],
    }


def rotate_remainder_fixture(**kwargs: object):
    snapshot = Snapshot.from_dict(symmetric_remainder_raw(**kwargs))
    slots = generate_slots(snapshot)
    employee_ids = sorted(employee.id for employee in snapshot.employees)
    employees = {employee.id: employee for employee in snapshot.employees}
    selected_employee_ids = {
        slot.id: employee_ids[index % len(employee_ids)]
        for index, slot in enumerate(slots)
    }
    quotes = quote_selected_assignments(
        snapshot,
        [
            (employees[selected_employee_ids[slot.id]], slot)
            for slot in slots
        ],
    )
    assignments = tuple(
        Assignment(
            slot_id=slot.id,
            employee_id=selected_employee_ids[slot.id],
            cost_units=quotes[(selected_employee_ids[slot.id], slot.id)].cost_units,
            cost_components=tuple(
                component.to_dict()
                for component in quotes[
                    (selected_employee_ids[slot.id], slot.id)
                ].components
            ),
        )
        for slot in slots
    )
    selected_map = {slot.id: None for slot in slots}
    selected_map.update(
        {assignment.slot_id: assignment.employee_id for assignment in assignments}
    )
    metrics = {
        "UNFILLED": 0,
        "ROLE_BACKUP_PENALTY": 0,
        "OVERTIME_MINUTES": 0,
        "ZERO_TARGET_EMPLOYEE_COUNT": 0,
        "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT": 0,
        "COMMON_FAIRNESS_GUARD_SCORE": 0,
        "ROLE_LOAD_FAIRNESS_SCORE": 0,
        "LOAD_UTILIZATION_SPREAD_BPS": 0,
        "PREFERENCE_VIOLATIONS": 0,
        "TOTAL_COST": sum(assignment.cost_units for assignment in assignments),
    }
    before = VariantResult(
        strategy_id="strategy-preferences",
        strategy_code="PREFERENCES",
        label="Preferencje i rowny podzial",
        sort_order=0,
        assignments=assignments,
        unfilled_slot_ids=(),
        metrics=metrics,
        stage_objectives=(
            {
                "tier": 1,
                "name": "TIER_1",
                "value": 0,
                "status": "OPTIMAL",
                "tolerance": 0,
                "frozenUpperBound": 0,
                "timeBudgetSeconds": 0.0,
                "elapsedSeconds": 0.0,
                "usedFallback": False,
            },
        ),
        optimal=True,
        solution_hash=sha256_hex(selected_map),
    )
    engine = CpSatScheduleEngine(
        max_total_seconds=30,
        finalization_reserve_seconds=1,
    )
    artifacts = engine._build_model(
        snapshot,
        slots,
        EligibilityIndex(snapshot),
    )
    after = engine._apply_month_rotation_tie_break(
        snapshot,
        slots,
        artifacts,
        before,
    )
    return snapshot, before, after, Counter(
        assignment.employee_id for assignment in after.assignments
    )


class MonthRotationTieBreakTests(unittest.TestCase):
    def test_symmetric_remainder_rotates_by_month_not_id_or_seed(self) -> None:
        august_snapshot, august_before, august, august_counts = (
            rotate_remainder_fixture()
        )
        reversed_snapshot, reversed_before, reversed_august, reversed_counts = (
            rotate_remainder_fixture(
            reverse_employees=True,
            random_seed=7,
            )
        )
        october_snapshot, october_before, october, october_counts = (
            rotate_remainder_fixture(
            month="2026-10",
            random_seed=7,
            )
        )

        august_extra = {
            employee_id for employee_id, count in august_counts.items() if count == 4
        }
        reversed_extra = {
            employee_id for employee_id, count in reversed_counts.items() if count == 4
        }
        october_extra = {
            employee_id for employee_id, count in october_counts.items() if count == 4
        }
        august_before_extra = {
            employee_id
            for employee_id, count in Counter(
                assignment.employee_id for assignment in august_before.assignments
            ).items()
            if count == 4
        }

        self.assertEqual(len(august.assignments), 62)
        self.assertEqual(set(august_counts.values()), {3, 4})
        self.assertEqual(len(august_extra), 2)
        self.assertEqual(august_before_extra, {"employee-000", "employee-001"})
        self.assertNotEqual(august_extra, august_before_extra)
        self.assertEqual(august_extra, reversed_extra)
        self.assertEqual(august.solution_hash, reversed_august.solution_hash)
        self.assertEqual(
            august.stage_objectives[-1]["rotationOrderHash"],
            reversed_august.stage_objectives[-1]["rotationOrderHash"],
        )
        self.assertEqual(
            august.stage_objectives[-1]["value"],
            reversed_august.stage_objectives[-1]["value"],
        )
        self.assertNotEqual(august_extra, october_extra)
        self.assertEqual(
            august_extra,
            set(
                month_employee_rotation_priority(
                    august_counts,
                    august_snapshot.period_start,
                )[:2]
            ),
        )
        self.assertEqual(
            october_extra,
            set(
                month_employee_rotation_priority(
                    october_counts,
                    october_snapshot.period_start,
                )[:2]
            ),
        )

        protected_metrics = (
            "UNFILLED",
            "ROLE_BACKUP_PENALTY",
            "OVERTIME_MINUTES",
            "ZERO_TARGET_EMPLOYEE_COUNT",
            "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT",
            "COMMON_FAIRNESS_GUARD_SCORE",
            "ROLE_LOAD_FAIRNESS_SCORE",
            "LOAD_UTILIZATION_SPREAD_BPS",
            "PREFERENCE_VIOLATIONS",
            "TOTAL_COST",
        )
        for metric in protected_metrics:
            self.assertEqual(august_before.metrics[metric], august.metrics[metric])
            self.assertEqual(
                reversed_before.metrics[metric], reversed_august.metrics[metric]
            )
            self.assertEqual(october_before.metrics[metric], october.metrics[metric])
            self.assertEqual(august.metrics[metric], reversed_august.metrics[metric])
            self.assertEqual(august.metrics[metric], october.metrics[metric])
        self.assertEqual(august.metrics["UNFILLED"], 0)
        self.assertEqual(august.metrics["ROLE_BACKUP_PENALTY"], 0)
        self.assertEqual(august.metrics["OVERTIME_MINUTES"], 0)
        self.assertEqual(august.metrics["ZERO_TARGET_EMPLOYEE_COUNT"], 0)
        self.assertEqual(august.metrics["ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"], 0)
        self.assertEqual(august.metrics["PREFERENCE_VIOLATIONS"], 0)

        for snapshot, variant in (
            (august_snapshot, august),
            (reversed_snapshot, reversed_august),
            (october_snapshot, october),
        ):
            report = validate_variant(snapshot, variant)
            self.assertTrue(report.valid, report.errors)
            self.assertFalse(any(stage["usedFallback"] for stage in variant.stage_objectives))
            rotation = variant.stage_objectives[-1]
            self.assertEqual(rotation["name"], "ROTATION_TIE_BREAK")
            self.assertEqual(rotation["status"], "OPTIMAL")
            self.assertEqual(rotation["rotationKeyVersion"], "MONTH_EMPLOYEE_SHA256_V1")
            self.assertTrue(rotation["businessMetricVectorPreserved"])
            self.assertEqual(rotation["interchangeableGroupCount"], 1)
            self.assertEqual(rotation["rotatedEmployeeCount"], 20)

    def test_solver_appends_rotation_after_protected_business_stages(self) -> None:
        snapshot = Snapshot.from_dict(
            symmetric_remainder_raw(employee_count=4, days_in_month=3)
        )
        variant = CpSatScheduleEngine(
            max_total_seconds=30,
            finalization_reserve_seconds=1,
        ).solve(snapshot)[0]

        rotation = variant.stage_objectives[-1]
        self.assertEqual(rotation["name"], "ROTATION_TIE_BREAK")
        self.assertTrue(rotation["businessMetricVectorPreserved"])
        self.assertGreater(
            rotation["tier"],
            max(stage["tier"] for stage in variant.stage_objectives[:-1]),
        )
        self.assertFalse(any(stage["usedFallback"] for stage in variant.stage_objectives))
        self.assertEqual(variant.metrics["UNFILLED"], 0)
        self.assertEqual(variant.metrics["ROLE_BACKUP_PENALTY"], 0)
        self.assertEqual(variant.metrics["OVERTIME_MINUTES"], 0)
        self.assertEqual(variant.metrics["ZERO_TARGET_EMPLOYEE_COUNT"], 0)
        self.assertEqual(variant.metrics["ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"], 0)
        self.assertEqual(variant.metrics["PREFERENCE_VIOLATIONS"], 0)
        self.assertTrue(validate_variant(snapshot, variant).valid)

    def test_employee_specific_pay_rule_disables_rotation(self) -> None:
        _snapshot, before, after, _counts = rotate_remainder_fixture(
            employee_count=4,
            days_in_month=3,
            employee_specific_pay_rule=True,
        )

        rotation = after.stage_objectives[-1]
        self.assertFalse(rotation["applied"])
        self.assertEqual(rotation["interchangeableGroupCount"], 0)
        self.assertEqual(rotation["changedAssignmentCount"], 0)
        self.assertEqual(after.assignments, before.assignments)
        self.assertEqual(after.metrics, before.metrics)
        self.assertEqual(after.solution_hash, before.solution_hash)


if __name__ == "__main__":
    unittest.main()
