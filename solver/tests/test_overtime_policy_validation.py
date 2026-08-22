from __future__ import annotations

from dataclasses import replace
import unittest

from grafik_solver.cp_sat_engine import CpSatScheduleEngine
from grafik_solver.models import Snapshot
from grafik_solver.validator import validate_variant


def overtime_snapshot_raw() -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "runId": "b4f164-run",
        "matrixVersionId": "b4f164-matrix",
        "scenarioId": "b4f164-scenario",
        "periodStart": "2026-08-01",
        "periodEnd": "2026-08-01",
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
                "weekdays": [6],
            }
        ],
        "demand": [
            {
                "id": "demand-a",
                "shiftTemplateId": "shift-a",
                "roleId": "role-a",
                "dutyIds": ["duty-a"],
                "requiredCount": 1,
                "dates": ["2026-08-01"],
            }
        ],
        "employees": [
            {
                "id": "employee-a",
                "roleIds": ["role-a"],
                "dutyIds": ["duty-a"],
                "locationIds": ["location-a"],
                "baseHourlyRateMinor": 1_000,
                "contractCode": "UOP",
                "overtimePolicy": "ALLOWED",
                "nominalMonthlyMinutes": 60,
                "maximumMonthlyMinutes": 180,
                "maximumWeeklyMinutes": 1_000,
                "maximumShiftsPerDay": 2,
                "maximumConsecutiveDays": 7,
                "minimumRestMinutes": 0,
            }
        ],
        "availabilityWindows": [],
        "workPatterns": [],
        "hardBlocks": [],
        "externalAssignments": [
            {
                "employeeId": "employee-a",
                "start": "2026-08-01T06:00:00+02:00",
                "end": "2026-08-01T07:00:00+02:00",
            }
        ],
        "lockedAssignments": [],
        "baselineAssignments": [],
        "payRules": [],
        "budgets": [],
    }


class OvertimePolicyValidationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.allowed_snapshot = Snapshot.from_dict(overtime_snapshot_raw())
        cls.variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(cls.allowed_snapshot)[0]

    def snapshot_with_policy(self, policy: str) -> Snapshot:
        employee = replace(
            self.allowed_snapshot.employees[0], overtime_policy=policy
        )
        return replace(self.allowed_snapshot, employees=(employee,))

    def test_allowed_accepts_internal_plus_external_overtime(self) -> None:
        report = validate_variant(self.allowed_snapshot, self.variant)
        self.assertTrue(report.valid, report.errors)
        self.assertEqual(self.variant.metrics["OVERTIME_MINUTES"], 60)

    def test_never_rejects_one_minute_above_nominal_without_override(self) -> None:
        report = validate_variant(self.snapshot_with_policy("NEVER"), self.variant)
        self.assertIn(
            "OVERTIME_POLICY_LIMIT:employee-a:NEVER:120:60",
            report.errors,
        )

    def test_approval_required_is_not_itself_an_approval(self) -> None:
        report = validate_variant(
            self.snapshot_with_policy("APPROVAL_REQUIRED"), self.variant
        )
        self.assertIn(
            "OVERTIME_POLICY_LIMIT:employee-a:APPROVAL_REQUIRED:120:60",
            report.errors,
        )


if __name__ == "__main__":
    unittest.main()
