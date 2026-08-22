from __future__ import annotations

import unittest

from grafik_solver.cp_sat_engine import CpSatScheduleEngine
from grafik_solver.models import Snapshot
from grafik_solver.validator import validate_variant


def allowed_overtime_fairness_raw() -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "runId": "b4f162-run",
        "matrixVersionId": "b4f162-matrix",
        "scenarioId": "b4f162-scenario",
        "periodStart": "2026-08-01",
        "periodEnd": "2026-08-03",
        "currency": "PLN",
        "settings": {
            "timezone": "Europe/Warsaw",
            "missingAvailabilityMeansAvailable": True,
            "defaultMinimumRestMinutes": 0,
            "requireOptimal": True,
            "randomSeed": 1,
        },
        "strategies": [
            {
                "id": "strategy-preferences",
                "code": "PREFERENCES",
                "label": "Preferencje i rowny podzial",
                "sortOrder": 0,
                "timeLimitSeconds": 20,
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
                "weekdays": [6, 7, 1],
            }
        ],
        "demand": [
            {
                "id": "demand-a",
                "shiftTemplateId": "shift-a",
                "roleId": "role-a",
                "dutyIds": ["duty-a"],
                "requiredCount": 1,
                "dates": ["2026-08-01", "2026-08-02", "2026-08-03"],
            }
        ],
        "employees": [
            {
                "id": "employee-allowed",
                "roleIds": ["role-a"],
                "dutyIds": ["duty-a"],
                "locationIds": ["location-a"],
                "baseHourlyRateMinor": 1_000,
                "contractCode": "UOP",
                "overtimePolicy": "ALLOWED",
                "nominalMonthlyMinutes": 60,
                "maximumMonthlyMinutes": 180,
                "maximumWeeklyMinutes": 1_000,
                "maximumShiftsPerDay": 1,
                "maximumConsecutiveDays": 7,
                "minimumRestMinutes": 0,
            },
            {
                "id": "employee-never",
                "roleIds": ["role-a"],
                "dutyIds": ["duty-a"],
                "locationIds": ["location-a"],
                "baseHourlyRateMinor": 1_001,
                "contractCode": "UOP",
                "overtimePolicy": "NEVER",
                "nominalMonthlyMinutes": 60,
                "maximumMonthlyMinutes": 60,
                "maximumWeeklyMinutes": 1_000,
                "maximumShiftsPerDay": 1,
                "maximumConsecutiveDays": 7,
                "minimumRestMinutes": 0,
            },
        ],
        "availabilityWindows": [],
        "workPatterns": [],
        "hardBlocks": [],
        "externalAssignments": [],
        "lockedAssignments": [],
        "baselineAssignments": [],
        "payRules": [],
        "budgets": [],
    }


class AllowedOvertimeFairnessTests(unittest.TestCase):
    def test_full_coverage_remains_feasible_above_fairness_target(self) -> None:
        """B4F-162: overtime above 100% cannot contradict fairness domains."""
        snapshot = Snapshot.from_dict(allowed_overtime_fairness_raw())
        variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)[0]

        assignment_counts = {employee.id: 0 for employee in snapshot.employees}
        for assignment in variant.assignments:
            assignment_counts[assignment.employee_id] += 1

        self.assertEqual(len(variant.assignments), 3)
        self.assertEqual(variant.metrics["UNFILLED"], 0)
        self.assertEqual(variant.metrics["OVERTIME_MINUTES"], 60)
        self.assertEqual(assignment_counts["employee-allowed"], 2)
        self.assertEqual(assignment_counts["employee-never"], 1)
        self.assertEqual(
            variant.metrics["MIN_ACHIEVABLE_TARGET_UTILIZATION_BPS"], 1000
        )
        self.assertTrue(validate_variant(snapshot, variant).valid)


if __name__ == "__main__":
    unittest.main()
