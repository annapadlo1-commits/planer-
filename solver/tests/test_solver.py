from __future__ import annotations

import copy
import json
import sys
import unittest
from dataclasses import replace
from datetime import datetime
from pathlib import Path
from unittest.mock import patch

from ortools.sat.python import cp_model

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.canonical import sha256_hex
from grafik_solver.config import WorkerConfig
from grafik_solver.cp_sat_engine import (
    CpSatScheduleEngine,
    OptimizationError,
    OptimizationIncomplete,
    SolverUnavailable,
)
from grafik_solver.eligibility import EligibilityIndex
from grafik_solver.lifecycle import WorkerRuntime
from grafik_solver.models import Assignment, Snapshot, SnapshotError
from grafik_solver.pay_rules import quote_assignment
from grafik_solver.rpc import Claim, Heartbeat, SnapshotEnvelope
from grafik_solver.slots import generate_slots
from grafik_solver.validator import validate_variant

FIXTURE_PATH = ROOT / "tests" / "fixtures" / "small_snapshot.json"
RUN_ID = "11111111-1111-4111-8111-111111111111"


def load_raw() -> dict:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


def boundary_snapshot_raw(
    external_assignments: list[dict],
    *,
    maximum_weekly_minutes: int,
    maximum_consecutive_days: int,
) -> dict:
    raw = load_raw()
    raw.pop("slots")
    raw["periodEnd"] = "2026-08-01"
    raw["strategies"] = [raw["strategies"][0]]
    raw["demand"] = [
        {
            **raw["demand"][0],
            "dates": ["2026-08-01"],
            "requiredCount": 1,
        }
    ]
    alice = next(
        employee for employee in raw["employees"] if employee["id"] == "employee-alice"
    )
    alice["nominalMonthlyMinutes"] = 240
    alice["maximumMonthlyMinutes"] = 240
    alice["maximumWeeklyMinutes"] = maximum_weekly_minutes
    alice["maximumShiftsPerDay"] = 1
    alice["maximumConsecutiveDays"] = maximum_consecutive_days
    raw["employees"] = [alice]
    raw["availabilityWindows"] = [
        window
        for window in raw["availabilityWindows"]
        if window["employeeId"] == "employee-alice"
        and window["start"].startswith("2026-08-01")
    ]
    raw["payRules"] = []
    raw["budget"] = {"amountMinor": None, "hard": False}
    raw["externalAssignments"] = external_assignments
    raw["lockedAssignments"] = [
        {
            "slotId": (
                "2026-08-01|shift-morning|role-sommelier|duty-service|demand-morning|1"
            ),
            "employeeId": "employee-alice",
        }
    ]
    return raw


def scoped_budget_snapshot_raw() -> dict:
    first_slot = "2026-08-01|shift-a|role-a|duty-a|demand-a|1"
    second_slot = "2026-08-02|shift-b|role-b|duty-b|demand-b|1"
    return {
        "schemaVersion": 2,
        "runId": "run-scoped-budget",
        "matrixVersionId": "matrix-scoped-budget",
        "scenarioId": "scenario-scoped-budget",
        "periodStart": "2026-08-01",
        "periodEnd": "2026-08-02",
        "currency": "PLN",
        "settings": {
            "timezone": "Europe/Warsaw",
            "missingAvailabilityMeansAvailable": False,
            "defaultMinimumRestMinutes": 660,
            "requireOptimal": True,
            "randomSeed": 11,
        },
        "strategies": [
            {
                "id": "strategy-cost",
                "code": "COST",
                "label": "Cost",
                "sortOrder": 0,
                "timeLimitSeconds": 10,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "TOTAL_COST",
                        "weight": 1,
                        "direction": "MIN",
                    }
                ],
            }
        ],
        "roles": [
            {"id": "role-a", "code": "A"},
            {"id": "role-b", "code": "B"},
        ],
        "duties": [
            {"id": "duty-a", "code": "A"},
            {"id": "duty-b", "code": "B"},
        ],
        "locations": [
            {"id": "location-a", "code": "A"},
            {"id": "location-b", "code": "B"},
        ],
        "shiftTemplates": [
            {
                "id": "shift-a",
                "locationId": "location-a",
                "startTime": "08:00",
                "endTime": "12:00",
                "weekdays": [6],
            },
            {
                "id": "shift-b",
                "locationId": "location-b",
                "startTime": "08:00",
                "endTime": "12:00",
                "weekdays": [7],
            },
        ],
        "demand": [
            {
                "id": "demand-a",
                "shiftTemplateId": "shift-a",
                "roleId": "role-a",
                "dutyIds": ["duty-a"],
                "requiredCount": 1,
                "dates": ["2026-08-01"],
            },
            {
                "id": "demand-b",
                "shiftTemplateId": "shift-b",
                "roleId": "role-b",
                "dutyIds": ["duty-b"],
                "requiredCount": 1,
                "dates": ["2026-08-02"],
            },
        ],
        "employees": [
            {
                "id": "employee-both",
                "roleIds": ["role-a", "role-b"],
                "roleGrants": [
                    {"roleId": "role-a"},
                    {"roleId": "role-b"},
                ],
                "dutyIds": ["duty-a", "duty-b"],
                "dutyGrants": [
                    {
                        "dutyId": "duty-a",
                        "roleId": "role-a",
                        "locationId": "location-a",
                    },
                    {
                        "dutyId": "duty-b",
                        "roleId": "role-b",
                        "locationId": "location-b",
                    },
                ],
                "locationIds": ["location-a", "location-b"],
                "locationGrants": [
                    {
                        "locationId": "location-a",
                        "standardAllowed": True,
                        "overtimeAllowed": False,
                    },
                    {
                        "locationId": "location-b",
                        "standardAllowed": True,
                        "overtimeAllowed": False,
                    },
                ],
                "baseHourlyRateMinor": 0,
                "maximumMonthlyMinutes": 480,
                "maximumWeeklyMinutes": 480,
                "maximumShiftsPerDay": 1,
                "maximumConsecutiveDays": 2,
                "minimumRestMinutes": 660,
            }
        ],
        "availabilityWindows": [
            {
                "employeeId": "employee-both",
                "start": "2026-08-01T07:30:00+02:00",
                "end": "2026-08-01T12:30:00+02:00",
            },
            {
                "employeeId": "employee-both",
                "start": "2026-08-02T07:30:00+02:00",
                "end": "2026-08-02T12:30:00+02:00",
            },
        ],
        "hardBlocks": [],
        "externalAssignments": [],
        "lockedAssignments": [
            {"slotId": first_slot, "employeeId": "employee-both"},
            {"slotId": second_slot, "employeeId": "employee-both"},
        ],
        "baselineAssignments": [],
        "payRules": [
            {
                "id": "monthly-threshold",
                "calculationType": "MONTHLY_THRESHOLD_PER_HOUR",
                "values": {"thresholdMinutes": 240, "rateMinorPerHour": 100},
                "conditions": [],
                "stackingGroup": "monthly-threshold",
                "stackingMode": "STACK",
                "priority": 0,
                "active": True,
            }
        ],
        "budgets": [
            {"id": "budget-global", "amountMinor": 400, "hard": True},
            {
                "id": "budget-location-a",
                "amountMinor": 0,
                "hard": True,
                "locationId": "location-a",
            },
            {
                "id": "budget-location-b",
                "amountMinor": 400,
                "hard": True,
                "locationId": "location-b",
            },
            {
                "id": "budget-role-b",
                "amountMinor": 400,
                "hard": True,
                "roleId": "role-b",
            },
            {
                "id": "budget-duty-b",
                "amountMinor": 400,
                "hard": True,
                "dutyId": "duty-b",
            },
            {
                "id": "budget-combined-b",
                "amountMinor": 400,
                "hard": True,
                "locationId": "location-b",
                "roleId": "role-b",
                "dutyId": "duty-b",
            },
        ],
    }


class _FakeClock:
    def __init__(self) -> None:
        self.value = 0.0

    def __call__(self) -> float:
        return self.value

    def advance(self, seconds: float) -> None:
        self.value += seconds


class SnapshotTests(unittest.TestCase):
    def test_canonical_hash_is_key_order_independent_and_ignores_embedded_hash(
        self,
    ) -> None:
        first = {"b": 2, "a": {"y": 4, "x": 3}, "snapshotHash": "old"}
        second = {"snapshotHash": "new", "a": {"x": 3, "y": 4}, "b": 2}
        self.assertEqual(
            sha256_hex(first, exclude_snapshot_hash=True),
            sha256_hex(second, exclude_snapshot_hash=True),
        )

    def test_resolved_slots_match_deterministic_generation(self) -> None:
        snapshot = Snapshot.from_dict(load_raw())
        slots = generate_slots(snapshot)
        self.assertEqual(len(slots), 4)
        self.assertEqual(
            slots[0].id,
            "2026-08-01|shift-morning|role-sommelier|duty-service|demand-morning|1",
        )
        self.assertEqual(slots[1].duty_ids, ("duty-close", "duty-service"))

    def test_empty_duty_slot_uses_canonical_dash_sentinel(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodEnd"] = "2026-08-01"
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dutyIds": [],
                "dates": ["2026-08-01"],
                "requiredCount": 1,
            }
        ]

        slots = generate_slots(Snapshot.from_dict(raw))

        self.assertEqual(len(slots), 1)
        self.assertEqual(
            slots[0].id,
            "2026-08-01|shift-morning|role-sommelier|-|demand-morning|1",
        )
        self.assertEqual(slots[0].duty_ids, ())

    def test_resolved_slot_timestamp_is_authoritative_during_dst_fold(self) -> None:
        raw = load_raw()
        raw["periodStart"] = "2026-10-25"
        raw["periodEnd"] = "2026-10-25"
        raw["shiftTemplates"] = [
            {
                "id": "shift-morning",
                "locationId": "location-rooftop",
                "startTime": "02:30",
                "endTime": "04:00",
                "weekdays": [7],
                "endsNextDay": False,
            }
        ]
        raw["demand"] = [
            {
                "id": "demand-morning",
                "shiftTemplateId": "shift-morning",
                "roleId": "role-sommelier",
                "dutyIds": ["duty-service"],
                "requiredCount": 1,
            }
        ]
        raw["slots"] = [
            {
                "slotId": (
                    "2026-10-25|shift-morning|role-sommelier|"
                    "duty-service|demand-morning|1"
                ),
                "demandId": "demand-morning",
                "occurrenceId": "2026-10-25|shift-morning",
                "seatIndex": 1,
                "date": "2026-10-25",
                "shiftTemplateId": "shift-morning",
                "locationId": "location-rooftop",
                "roleId": "role-sommelier",
                "dutyIds": ["duty-service"],
                # PostgreSQL resolves the ambiguous 02:30 to standard time.
                "start": "2026-10-25T02:30:00+01:00",
                "end": "2026-10-25T04:00:00+01:00",
                "durationMinutes": 90,
            }
        ]
        slot = generate_slots(Snapshot.from_dict(raw))[0]
        self.assertEqual(slot.start.isoformat(), "2026-10-25T02:30:00+01:00")
        self.assertEqual(slot.duration_minutes, 90)

    def test_resolved_overnight_slot_keeps_iana_zone_across_dst_change(self) -> None:
        raw = load_raw()
        raw["periodStart"] = "2026-10-24"
        raw["periodEnd"] = "2026-10-24"
        raw["shiftTemplates"] = [
            {
                "id": "shift-night",
                "locationId": "location-rooftop",
                "startTime": "22:00",
                "endTime": "06:00",
                "weekdays": [6],
                "endsNextDay": True,
            }
        ]
        raw["demand"] = [
            {
                "id": "demand-night",
                "shiftTemplateId": "shift-night",
                "roleId": "role-sommelier",
                "dutyIds": ["duty-service"],
                "requiredCount": 1,
            }
        ]
        raw["slots"] = [
            {
                "slotId": (
                    "2026-10-24|shift-night|role-sommelier|duty-service|demand-night|1"
                ),
                "demandId": "demand-night",
                "occurrenceId": "2026-10-24|shift-night",
                "seatIndex": 1,
                "date": "2026-10-24",
                "shiftTemplateId": "shift-night",
                "locationId": "location-rooftop",
                "roleId": "role-sommelier",
                "dutyIds": ["duty-service"],
                "start": "2026-10-24T22:00:00+02:00",
                "end": "2026-10-25T06:00:00+01:00",
                "durationMinutes": 540,
            }
        ]
        slot = generate_slots(Snapshot.from_dict(raw))[0]
        self.assertEqual(slot.start.tzinfo.key, "Europe/Warsaw")
        self.assertEqual(slot.end.tzinfo.key, "Europe/Warsaw")
        self.assertEqual(slot.start.isoformat(), "2026-10-24T22:00:00+02:00")
        self.assertEqual(slot.end.isoformat(), "2026-10-25T06:00:00+01:00")
        self.assertEqual(slot.duration_minutes, 540)

    def test_multiple_availability_windows_do_not_bridge_the_gap(self) -> None:
        snapshot = Snapshot.from_dict(load_raw())
        slots = generate_slots(snapshot)
        employee = next(
            item for item in snapshot.employees if item.id == "employee-charlie"
        )
        index = EligibilityIndex(snapshot)
        self.assertTrue(index.evaluate(employee, slots[0]).allowed)
        spanning = replace(
            slots[0],
            start=datetime.fromisoformat("2026-08-01T11:00:00+02:00"),
            end=datetime.fromisoformat("2026-08-01T17:00:00+02:00"),
        )
        result = index.evaluate(employee, spanning)
        self.assertFalse(result.allowed)
        self.assertIn("AVAILABILITY_WINDOW", result.reasons)

    def test_shift_period_and_employee_period_rules_are_parsed(self) -> None:
        raw = load_raw()
        raw["shiftTemplates"][0]["shiftPeriod"] = "MORNING"
        raw["shiftTemplates"][1]["shiftPeriod"] = "EVENING"
        raw["employees"][0]["preferredShiftTemplateIds"] = ["shift-morning"]
        raw["employees"][0]["avoidedShiftTemplateIds"] = ["shift-evening"]
        raw["employees"][0]["blockedShiftTemplateIds"] = []
        snapshot = Snapshot.from_dict(raw)
        self.assertEqual(snapshot.shift_templates[0].shift_period, "MORNING")
        self.assertEqual(snapshot.shift_templates[1].shift_period, "EVENING")
        self.assertEqual(
            snapshot.employees[0].preferred_shift_template_ids,
            ("shift-morning",),
        )
        self.assertEqual(
            snapshot.employees[0].avoided_shift_template_ids,
            ("shift-evening",),
        )

    def test_invalid_shift_period_is_rejected(self) -> None:
        raw = load_raw()
        raw["shiftTemplates"][0]["shiftPeriod"] = "LUNCH"
        with self.assertRaisesRegex(SnapshotError, "shiftPeriod"):
            Snapshot.from_dict(raw)

    def test_manager_blocked_period_is_a_hard_eligibility_rule(self) -> None:
        raw = load_raw()
        raw["employees"][0]["blockedShiftTemplateIds"] = ["shift-morning"]
        snapshot = Snapshot.from_dict(raw)
        employee = next(
            item for item in snapshot.employees if item.id == "employee-alice"
        )
        slot = next(
            item
            for item in generate_slots(snapshot)
            if item.shift_template_id == "shift-morning"
        )
        eligibility = EligibilityIndex(snapshot).evaluate(employee, slot)
        self.assertFalse(eligibility.allowed)
        self.assertIn("SHIFT_PERIOD_BLOCKED", eligibility.reasons)

    def test_pay_quote_is_data_driven(self) -> None:
        snapshot = Snapshot.from_dict(load_raw())
        evening = generate_slots(snapshot)[1]
        employee = next(
            item for item in snapshot.employees if item.id == "employee-bob"
        )
        quote = quote_assignment(snapshot, employee, evening)
        components = {
            component.rule_id: component.cost_units for component in quote.components
        }
        self.assertEqual(components["BASE"], 2500 * 240)
        self.assertEqual(components["pay-close-duty"], 1000 * 60)
        self.assertEqual(components["pay-weekend"], 120000)

    def test_hourly_pay_windows_charge_only_intersection_minutes(self) -> None:
        expectations = {
            "PER_HOUR": ({"rateMinorPerHour": 1000}, 1000 * 60),
            "PERCENT_BASE": ({"percentBasisPoints": 2000}, 2500 * 60 * 20 // 100),
            "MULTIPLIER": (
                {"multiplierBasisPoints": 15000},
                2500 * 60 * 50 // 100,
            ),
        }
        for calculation, (values, expected) in expectations.items():
            with self.subTest(calculation=calculation):
                raw = load_raw()
                for template in raw["shiftTemplates"]:
                    if template["id"] == "shift-evening":
                        template["endTime"] = "23:00"
                for slot in raw["slots"]:
                    if slot["shiftTemplateId"] == "shift-evening":
                        slot["end"] = slot["end"].replace("T20:00:00", "T23:00:00")
                        slot["durationMinutes"] = 420
                raw["payRules"] = [
                    {
