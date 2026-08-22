from __future__ import annotations

import unittest

from grafik_solver.cp_sat_engine import CpSatScheduleEngine
from grafik_solver.models import Snapshot
from grafik_solver.validator import validate_variant


def estimated_target_raw() -> dict[str, object]:
    return {
        "schemaVersion": 2,
        "runId": "b4f163-run",
        "matrixVersionId": "b4f163-matrix",
        "scenarioId": "b4f163-scenario",
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
                "id": "employee-a",
                "roleIds": ["role-a"],
                "dutyIds": ["duty-a"],
                "locationIds": ["location-a"],
                "baseHourlyRateMinor": 1_000,
                "contractCode": "UOP",
                "overtimePolicy": "NEVER",
                "nominalMonthlyMinutes": 180,
                "maximumMonthlyMinutes": 180,
                "maximumWeeklyMinutes": 1_000,
                "maximumShiftsPerDay": 1,
                "maximumConsecutiveDays": 7,
                "minimumRestMinutes": 0,
            }
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


class EstimatedAchievableTargetTests(unittest.TestCase):
    def solve(self, raw: dict[str, object]):
        snapshot = Snapshot.from_dict(raw)
        variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)[0]
        self.assertEqual(
            variant.metrics["ESTIMATED_ACHIEVABLE_TARGET_METHOD_VERSION"], 2
        )
        self.assertTrue(validate_variant(snapshot, variant).valid)
        return variant

    def test_internal_overlap_is_not_double_counted(self) -> None:
        """B4F-163: two simultaneous eligible shifts provide one hour, not two."""
        raw = estimated_target_raw()
        raw["periodEnd"] = "2026-08-01"
        raw["demand"] = [
            {
                **raw["demand"][0],
                "id": demand_id,
                "dates": ["2026-08-01"],
            }
            for demand_id in ("demand-a", "demand-b")
        ]
        employee = raw["employees"][0]
        employee["maximumShiftsPerDay"] = 2
        employee["nominalMonthlyMinutes"] = 120
        employee["maximumMonthlyMinutes"] = 120

        variant = self.solve(raw)

        self.assertEqual(
            variant.metrics["ESTIMATED_ACHIEVABLE_TARGET_MINUTES_TOTAL"], 60
        )
        self.assertEqual(len(variant.assignments), 1)
        self.assertEqual(variant.metrics["UNFILLED"], 1)

    def test_maximum_consecutive_days_caps_the_month_estimate(self) -> None:
        """B4F-163: three available days with max consecutive one yield two."""
        raw = estimated_target_raw()
        raw["employees"][0]["maximumConsecutiveDays"] = 1

        variant = self.solve(raw)

        self.assertEqual(
            variant.metrics["ESTIMATED_ACHIEVABLE_TARGET_MINUTES_TOTAL"], 120
        )
        self.assertEqual(len(variant.assignments), 2)
        self.assertEqual(variant.metrics["UNFILLED"], 1)

    def test_obvious_cross_day_rest_pair_caps_the_estimate(self) -> None:
        """B4F-163: an all-conflicting late/early pair contributes one shift."""
        raw = estimated_target_raw()
        raw["periodEnd"] = "2026-08-02"
        raw["shiftTemplates"] = [
            {
                "id": "shift-late",
                "locationId": "location-a",
                "startTime": "22:00",
                "endTime": "23:00",
                "weekdays": [6],
            },
            {
                "id": "shift-early",
                "locationId": "location-a",
                "startTime": "08:00",
                "endTime": "09:00",
                "weekdays": [7],
            },
        ]
        demand = raw["demand"][0]
        raw["demand"] = [
            {
                **demand,
                "id": "demand-late",
                "shiftTemplateId": "shift-late",
                "dates": ["2026-08-01"],
            },
            {
                **demand,
                "id": "demand-early",
                "shiftTemplateId": "shift-early",
                "dates": ["2026-08-02"],
            },
        ]
        employee = raw["employees"][0]
        employee["minimumRestMinutes"] = 600
        employee["nominalMonthlyMinutes"] = 120
        employee["maximumMonthlyMinutes"] = 120

        variant = self.solve(raw)

        self.assertEqual(
            variant.metrics["ESTIMATED_ACHIEVABLE_TARGET_MINUTES_TOTAL"], 60
        )
        self.assertEqual(len(variant.assignments), 1)
        self.assertEqual(variant.metrics["UNFILLED"], 1)


if __name__ == "__main__":
    unittest.main()
