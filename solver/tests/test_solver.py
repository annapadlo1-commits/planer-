from __future__ import annotations

import copy
import json
import sys
import unittest
from collections import Counter
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
    coverage_minimum_is_proven,
)
from grafik_solver.eligibility import EligibilityIndex
from grafik_solver.lifecycle import WorkerRuntime
from grafik_solver.models import Assignment, Snapshot, SnapshotError
from grafik_solver.pay_rules import quote_assignment
from grafik_solver.rpc import Claim, Heartbeat, RpcError, SnapshotEnvelope
from grafik_solver.slots import generate_slots
from grafik_solver.validator import validate_variant

FIXTURE_PATH = ROOT / "tests" / "fixtures" / "small_snapshot.json"
RUN_ID = "11111111-1111-4111-8111-111111111111"


class CoveragePublicationGuardTests(unittest.TestCase):
    def test_unproven_nonzero_shortage_is_not_publishable(self) -> None:
        self.assertFalse(
            coverage_minimum_is_proven(3, 0, cp_model.FEASIBLE)
        )

    def test_complete_or_bound_matching_roster_is_publishable(self) -> None:
        self.assertTrue(coverage_minimum_is_proven(0, 0, cp_model.FEASIBLE))
        self.assertTrue(coverage_minimum_is_proven(3, 3, cp_model.FEASIBLE))
        self.assertTrue(coverage_minimum_is_proven(3, 0, cp_model.OPTIMAL))


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


def decomposed_certificate_snapshot_raw(*, required_count: int = 1) -> dict:
    raw = load_raw()
    raw.pop("slots")
    raw["periodStart"] = "2026-08-02"
    raw["periodEnd"] = "2026-08-03"
    raw["settings"]["missingAvailabilityMeansAvailable"] = True
    raw["strategies"] = [raw["strategies"][0]]
    morning = next(
        item for item in raw["shiftTemplates"] if item["id"] == "shift-morning"
    )
    evening = next(
        item for item in raw["shiftTemplates"] if item["id"] == "shift-evening"
    )
    morning["weekdays"] = [1]
    evening["weekdays"] = [7]
    evening["endTime"] = "23:00"
    raw["demand"] = [
        {
            **raw["demand"][0],
            "dates": ["2026-08-03"],
            "requiredCount": required_count,
        },
        {
            **raw["demand"][1],
            "dates": ["2026-08-02"],
            "requiredCount": required_count,
        },
    ]
    bob = next(
        employee for employee in raw["employees"] if employee["id"] == "employee-bob"
    )
    bob["nominalMonthlyMinutes"] = 660
    bob["workTimePolicy"] = "CUSTOM"
    bob["maximumMonthlyMinutes"] = 2_000
    bob["maximumWeeklyMinutes"] = 2_000
    bob["minimumRestMinutes"] = 660
    raw["employees"] = [bob]
    raw["availabilityWindows"] = []
    raw["payRules"] = []
    raw["budget"] = {"amountMinor": None, "hard": False}
    raw["externalAssignments"] = []
    raw["lockedAssignments"] = [
        {
            "slotId": (
                "2026-08-03|shift-morning|role-sommelier|duty-service|demand-morning|1"
            ),
            "employeeId": "employee-bob",
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
    def test_zlecenie_respects_explicit_employee_limits(self) -> None:
        raw = load_raw()
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        employee_raw = raw["employees"][0]
        employee_raw.update(
            {
                "contractCode": "ZLECENIE",
                "nominalMonthlyMinutes": 9600,
                "maximumMonthlyMinutes": 9600,
                "maximumWeeklyMinutes": 2400,
                "maximumConsecutiveDays": 5,
                "minimumRestMinutes": 660,
            }
        )
        raw["employees"] = [employee_raw]
        raw["availabilityWindows"] = []

        snapshot = Snapshot.from_dict(raw)
        employee = snapshot.employees[0]

        self.assertEqual(employee.nominal_monthly_minutes, 9600)
        self.assertEqual(employee.maximum_monthly_minutes, 9600)
        self.assertEqual(employee.maximum_weekly_minutes, 2400)
        self.assertEqual(employee.maximum_consecutive_days, 5)
        self.assertEqual(employee.minimum_rest_minutes, 660)
        self.assertIsNone(employee.missing_availability_means_available)

        slot = next(
            slot
            for slot in generate_slots(snapshot)
            if slot.role_id in employee.role_ids
            and slot.location_id in employee.location_ids
        )
        eligibility = EligibilityIndex(snapshot).evaluate(employee, slot)
        self.assertTrue(eligibility.allowed)
        self.assertNotIn("MISSING_AVAILABILITY", eligibility.reasons)

    def test_zlecenie_can_explicitly_require_declared_availability(self) -> None:
        raw = load_raw()
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        employee_raw = raw["employees"][0]
        employee_raw.update(
            {
                "contractCode": "ZLECENIE",
                "missingAvailabilityMeansAvailable": False,
            }
        )
        raw["employees"] = [employee_raw]
        raw["availabilityWindows"] = []

        snapshot = Snapshot.from_dict(raw)
        employee = snapshot.employees[0]
        slot = next(
            slot
            for slot in generate_slots(snapshot)
            if slot.role_id in employee.role_ids
            and slot.location_id in employee.location_ids
        )

        eligibility = EligibilityIndex(snapshot).evaluate(employee, slot)

        self.assertFalse(eligibility.allowed)
        self.assertIn("MISSING_AVAILABILITY", eligibility.reasons)

    def test_zlecenie_custom_policy_keeps_agreed_limits(self) -> None:
        raw = load_raw()
        employee_raw = raw["employees"][0]
        employee_raw.update(
            {
                "contractCode": "ZLECENIE",
                "workTimePolicy": "CUSTOM",
                "maximumMonthlyMinutes": 7200,
                "maximumWeeklyMinutes": 1800,
                "maximumConsecutiveDays": 4,
                "minimumRestMinutes": 480,
            }
        )
        raw["employees"] = [employee_raw]

        employee = Snapshot.from_dict(raw).employees[0]

        self.assertEqual(employee.maximum_monthly_minutes, 7200)
        self.assertEqual(employee.maximum_weekly_minutes, 1800)
        self.assertEqual(employee.maximum_consecutive_days, 4)
        self.assertEqual(employee.minimum_rest_minutes, 480)

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

    def test_partial_day_hard_absence_blocks_only_overlapping_shift(self) -> None:
        raw = load_raw()
        raw["hardBlocks"] = [
            {
                "employeeId": "employee-alice",
                "start": "2026-08-01T12:00:00+02:00",
                "end": "2026-08-01T14:00:00+02:00",
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        employee = next(item for item in snapshot.employees if item.id == "employee-alice")
        morning = next(
            item
            for item in generate_slots(snapshot)
            if item.shift_template_id == "shift-morning"
            and item.date.isoformat() == "2026-08-01"
        )
        self.assertTrue(EligibilityIndex(snapshot).evaluate(employee, morning).allowed)

        raw["hardBlocks"][0].update(
            start="2026-08-01T10:00:00+02:00",
            end="2026-08-01T11:00:00+02:00",
        )
        blocked_snapshot = Snapshot.from_dict(raw)
        blocked_employee = next(
            item for item in blocked_snapshot.employees if item.id == "employee-alice"
        )
        blocked_morning = next(
            item
            for item in generate_slots(blocked_snapshot)
            if item.shift_template_id == "shift-morning"
            and item.date.isoformat() == "2026-08-01"
        )
        result = EligibilityIndex(blocked_snapshot).evaluate(
            blocked_employee, blocked_morning
        )
        self.assertFalse(result.allowed)
        self.assertIn("HARD_BLOCK", result.reasons)

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

    def test_employer_oncost_is_explicit_and_separately_classified(self) -> None:
        raw = load_raw()
        raw["payRules"] = [{
            "id": "employer-zus-entered-by-owner",
            "calculationType": "PERCENT_BASE",
            "values": {"percentBasisPoints": 2000},
            "conditions": [],
            "stackingGroup": "employer-zus",
            "stackingMode": "STACK",
            "priority": 0,
            "active": True,
            "costCategory": "EMPLOYER_ONCOST",
        }]
        snapshot = Snapshot.from_dict(raw)
        employee = next(item for item in snapshot.employees if item.id == "employee-bob")
        quote = quote_assignment(snapshot, employee, generate_slots(snapshot)[1])
        oncost = next(component for component in quote.components if component.rule_id != "BASE")
        self.assertEqual(oncost.cost_category, "EMPLOYER_ONCOST")
        self.assertEqual(oncost.cost_units, 2500 * 240 * 20 // 100)

    def test_incident_rate_is_ignored_until_approved_rule_reaches_snapshot(self) -> None:
        raw = load_raw()
        raw["payRules"] = []
        snapshot = Snapshot.from_dict(raw)
        employee = next(item for item in snapshot.employees if item.id == "employee-bob")
        slot = generate_slots(snapshot)[1]
        self.assertEqual(quote_assignment(snapshot, employee, slot).components[0].rule_id, "BASE")

        raw["payRules"] = [{
            "id": "incident-rate:approved",
            "calculationType": "BASE_RATE_OVERRIDE",
            "values": {"rateMinorPerHour": 4000},
            "conditions": [{"field": "employee_id", "operator": "EQ", "value": "employee-bob"}],
            "stackingGroup": "incident-rate:employee-bob",
            "stackingMode": "FIRST",
            "priority": 0,
            "active": True,
            "effectiveFrom": slot.date.isoformat(),
            "effectiveTo": slot.date.isoformat(),
        }]
        approved = Snapshot.from_dict(raw)
        approved_quote = quote_assignment(approved, employee, generate_slots(approved)[1])
        self.assertEqual(approved_quote.components[0].rule_id, "incident-rate:approved")
        self.assertEqual(approved_quote.components[0].cost_units, 4000 * 240)

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
                        "id": f"pay-window-{calculation.lower()}",
                        "calculationType": calculation,
                        "values": values,
                        "localStart": "22:00",
                        "localEnd": "06:00",
                        "conditions": [],
                        "stackingGroup": "night-window",
                        "stackingMode": "STACK",
                        "priority": 0,
                        "active": True,
                    }
                ]
                snapshot = Snapshot.from_dict(raw)
                employee = next(
                    item for item in snapshot.employees if item.id == "employee-bob"
                )
                evening = generate_slots(snapshot)[1]
                quote = quote_assignment(snapshot, employee, evening)
                addition = next(
                    component
                    for component in quote.components
                    if component.rule_id != "BASE"
                )
                self.assertEqual(addition.cost_units, expected)

    def test_pay_window_intersection_is_dst_safe(self) -> None:
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
        raw["payRules"] = [
            {
                "id": "pay-dst-window",
                "calculationType": "PER_HOUR",
                "values": {"rateMinorPerHour": 100},
                "localStart": "01:00",
                "localEnd": "04:00",
                "conditions": [],
                "stackingGroup": "dst-window",
                "stackingMode": "STACK",
                "priority": 0,
                "active": True,
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        employee = next(
            item for item in snapshot.employees if item.id == "employee-bob"
        )
        quote = quote_assignment(snapshot, employee, generate_slots(snapshot)[0])
        addition = next(
            component for component in quote.components if component.rule_id != "BASE"
        )
        self.assertEqual(addition.cost_units, 100 * 240)

    def test_currency_is_required_and_must_be_iso_4217_uppercase(self) -> None:
        missing = load_raw()
        missing.pop("currency")
        invalid_lowercase = load_raw()
        invalid_lowercase["currency"] = "pln"
        invalid_unknown = load_raw()
        invalid_unknown["currency"] = "ZZZ"
        for raw in (missing, invalid_lowercase, invalid_unknown):
            with (
                self.subTest(currency=raw.get("currency")),
                self.assertRaises(SnapshotError),
            ):
                Snapshot.from_dict(raw)

    def test_legacy_global_budget_is_preserved_as_fallback(self) -> None:
        snapshot = Snapshot.from_dict(load_raw())
        self.assertEqual(snapshot.currency, "PLN")
        self.assertEqual(len(snapshot.budgets), 1)
        self.assertEqual(snapshot.budgets[0].id, "legacy-global-budget")
        self.assertEqual(snapshot.budgets[0].scope(), {})

    def test_cumulative_budget_contract_supports_enforcement_and_hours(self) -> None:
        raw = load_raw()
        raw.pop("budget")
        raw["budgets"] = [
            {"id": "company-hard", "metricType": "COST", "enforcement": "HARD", "amountMinor": 999999},
            {"id": "role-hours", "metricType": "HOURS", "enforcement": "TARGET", "limitMinutes": 120, "roleIds": [raw["roles"][0]["id"]]},
            {"id": "monitor", "metricType": "COST", "enforcement": "MONITORING", "amountMinor": 1},
        ]
        snapshot = Snapshot.from_dict(raw)
        self.assertEqual([item.enforcement for item in snapshot.budgets], ["HARD", "TARGET", "MONITORING"])
        self.assertEqual(snapshot.budgets[1].metric_type, "HOURS")
        self.assertEqual(snapshot.budgets[1].limit_minutes, 120)
        self.assertFalse(snapshot.budgets[2].hard)

    def test_pay_condition_values_are_typed_before_solving(self) -> None:
        invalid_conditions = (
            {"field": "duty_ids", "operator": "CONTAINS", "value": {}},
            {
                "field": "duty_ids",
                "operator": "CONTAINS_ANY",
                "value": ["duty-close", {"nested": True}],
            },
            {"field": "role_id", "operator": "IN", "value": [123]},
            {"field": "duration_minutes", "operator": "GTE", "value": 1.5},
            {"field": "weekday", "operator": "EQ", "value": 8},
        )
        for condition in invalid_conditions:
            raw = load_raw()
            raw["payRules"][0]["conditions"] = [condition]
            with (
                self.subTest(condition=condition),
                self.assertRaisesRegex(SnapshotError, "pay condition contract"),
            ):
                Snapshot.from_dict(raw)

    def test_locked_assignment_cannot_reference_employee_outside_snapshot(self) -> None:
        raw = load_raw()
        raw["lockedAssignments"] = [
            {
                "slotId": raw["slots"][0]["slotId"],
                "employeeId": "employee-not-in-snapshot",
            }
        ]
        with self.assertRaisesRegex(SnapshotError, "Lock references missing employee"):
            CpSatScheduleEngine._validate_snapshot_references(Snapshot.from_dict(raw))

    def test_objective_tolerance_and_target_parameters_are_not_silent(self) -> None:
        raw = load_raw()
        term = raw["strategies"][0]["objectiveTerms"][0]
        term["weight"] = 2
        term["tolerance"] = 125
        term["parameters"] = {"targetValue": 1000}
        snapshot = Snapshot.from_dict(raw)
        parsed = snapshot.strategies[0].objective_terms[0]
        self.assertEqual(parsed.tolerance, 125)
        self.assertEqual(parsed.parameters, {"targetValue": 1000})

        unsupported = load_raw()
        unsupported["strategies"][0]["objectiveTerms"][0]["parameters"] = {
            "ignoredMagic": 1
        }
        with self.assertRaisesRegex(SnapshotError, "Unsupported objective"):
            Snapshot.from_dict(unsupported)

    def test_pull_worker_configuration_is_provider_neutral(self) -> None:
        with patch.dict(
            "os.environ",
            {
                "SOLVER_GATEWAY_URL": (
                    "https://example.supabase.co/functions/v1/solver-gateway"
                ),
                "SOLVER_GATEWAY_TOKEN": "g" * 64,
                "WORKER_ID": "free-host-worker-test",
                "SOLVER_VERSION": "ORTOOLS_V2_2026_08_02",
                "WORKER_TASK_ATTEMPT": "2",
                "POLL_INTERVAL_SECONDS": "7",
                "MAX_RUNS": "3",
                "IDLE_EXIT_SECONDS": "60",
            },
            clear=True,
        ):
            config = WorkerConfig.from_env()
        self.assertEqual(config.worker_id.split(":", 1)[0], "free-host-worker-test")
        self.assertEqual(config.task_attempt, 2)
        self.assertEqual(config.poll_interval_seconds, 7)
        self.assertEqual(config.max_runs, 3)
        self.assertEqual(config.idle_exit_seconds, 60)


    def test_permanent_weekly_work_pattern_limits_real_eligibility(self) -> None:
        raw = scoped_budget_snapshot_raw()
        raw["workPatterns"] = [
            {
                "id": "dominika-saturday-morning",
                "employeeId": "employee-both",
                "weekday": 6,
                "localStart": "07:00",
                "localEnd": "13:00",
                "roleId": "role-a",
                "locationId": "location-a",
                "enforcement": "HARD",
                "validFrom": "2026-08-01",
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        eligibility = EligibilityIndex(snapshot)

        saturday = eligibility.evaluate(snapshot.employees[0], slots[0])
        sunday = eligibility.evaluate(snapshot.employees[0], slots[1])

        self.assertTrue(saturday.allowed, saturday.reasons)
        self.assertFalse(sunday.allowed)
        self.assertIn("PERMANENT_WORK_PATTERN", sunday.reasons)

    def test_preferred_weekly_work_pattern_is_soft(self) -> None:
        raw = scoped_budget_snapshot_raw()
        raw["workPatterns"] = [
            {
                "id": "preferred-sunday",
                "employeeId": "employee-both",
                "weekday": 7,
                "localStart": "07:00",
                "localEnd": "13:00",
                "enforcement": "PREFERENCE",
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        eligibility = EligibilityIndex(snapshot)

        self.assertTrue(eligibility.evaluate(snapshot.employees[0], slots[0]).allowed)
        self.assertTrue(
            eligibility.violates_preferred_work_pattern(
                snapshot.employees[0].id, slots[0]
            )
        )
        self.assertFalse(
            eligibility.violates_preferred_work_pattern(
                snapshot.employees[0].id, slots[1]
            )
        )


class SolverTests(unittest.TestCase):
    def test_fill_remaining_preserves_every_locked_leader_assignment(self) -> None:
        raw = load_raw()
        raw["strategies"] = [raw["strategies"][0]]
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        locked_slot_id = raw["slots"][0]["slotId"]
        raw["lockedAssignments"] = [
            {"slotId": locked_slot_id, "employeeId": "employee-alice"}
        ]

        variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(
            Snapshot.from_dict(raw)
        )[0]
        assignments = {
            assignment.slot_id: assignment.employee_id
            for assignment in variant.assignments
        }

        self.assertEqual(assignments[locked_slot_id], "employee-alice")
        self.assertEqual(len(assignments), len(raw["slots"]))
        self.assertEqual(variant.unfilled_slot_ids, ())

    def test_fairness_is_role_aware_in_every_category(self) -> None:
        """Every category uses the same per-role fairness contract.

        These names intentionally include all current business categories and
        an employer-defined one.  A regression therefore cannot pass merely by
        special-casing BAR while leaving SALA, KUCHNIA or a future category on
        the old category-wide min/max metric.
        """
        for category_code in (
            "BAR",
            "SALA",
            "PIZZABAR",
            "KUCHNIA",
            "ZMYWAK",
            "KATEGORIA_WLASNA",
        ):
            with self.subTest(category=category_code):
                raw = load_raw()
                raw.pop("slots")
                raw["settings"]["missingAvailabilityMeansAvailable"] = True
                raw["settings"]["requireOptimal"] = True
                raw["periodEnd"] = "2026-08-08"
                primary_role_id = f"role-{category_code.lower()}-primary"
                secondary_role_id = f"role-{category_code.lower()}-secondary"
                raw["roles"] = [
                    {"id": primary_role_id, "code": f"{category_code}_PRIMARY"},
                    {"id": secondary_role_id, "code": f"{category_code}_SECONDARY"},
                ]
                raw["shiftTemplates"][0]["weekdays"] = list(range(1, 8))
                raw["shiftTemplates"][1]["weekdays"] = list(range(1, 8))
                raw["demand"] = [
                    {
                        **raw["demand"][0],
                        "id": f"demand-{category_code.lower()}-primary",
                        "roleId": primary_role_id,
                        "requiredCount": 1,
                    },
                    {
                        **raw["demand"][0],
                        "id": f"demand-{category_code.lower()}-secondary",
                        "roleId": secondary_role_id,
                        "requiredCount": 1,
                    },
                ]
                raw["employees"] = [
                    {
                        **raw["employees"][0],
                        "id": f"{category_code.lower()}-primary-one",
                        "roleIds": [primary_role_id],
                        "nominalMonthlyMinutes": 1_920,
                    },
                    {
                        **raw["employees"][0],
                        "id": f"{category_code.lower()}-primary-two",
                        "roleIds": [primary_role_id],
                        "nominalMonthlyMinutes": 1_920,
                    },
                    {
                        **raw["employees"][0],
                        "id": f"{category_code.lower()}-secondary-one",
                        "roleIds": [secondary_role_id],
                        "nominalMonthlyMinutes": 1_920,
                    },
                    {
                        **raw["employees"][0],
                        "id": f"{category_code.lower()}-secondary-two",
                        "roleIds": [secondary_role_id],
                        "nominalMonthlyMinutes": 1_920,
                    },
                ]
                raw["availabilityWindows"] = []
                raw["strategies"] = [
                    {
                        "id": f"strategy-{category_code.lower()}-fair",
                        "code": f"{category_code}_FAIR",
                        "label": f"{category_code} fair",
                        "sortOrder": 0,
                        "timeLimitSeconds": 30,
                        "objectiveTerms": [
                            {
                                "tier": 1,
                                "metric": "LOAD_SPREAD_MINUTES",
                                "weight": 1,
                                "direction": "MIN",
                            }
                        ],
                    }
                ]
                raw["lockedAssignments"] = []
                raw["baselineAssignments"] = []
                raw["payRules"] = []
                raw["budget"] = {"amountMinor": None, "hard": False}

                snapshot = Snapshot.from_dict(raw)
                variant = CpSatScheduleEngine(max_total_seconds=60).solve(snapshot)[0]
                slots = {slot.id: slot for slot in generate_slots(snapshot)}
                role_counts: dict[str, dict[str, int]] = {}
                for assignment in variant.assignments:
                    role_id = slots[assignment.slot_id].role_id
                    employee_counts = role_counts.setdefault(role_id, {})
                    employee_counts[assignment.employee_id] = (
                        employee_counts.get(assignment.employee_id, 0) + 1
                    )

                self.assertEqual(len(variant.unfilled_slot_ids), 0)
                for employee_counts in role_counts.values():
                    values = list(employee_counts.values())
                    self.assertLessEqual(max(values) - min(values), 1)
                self.assertEqual(
                    variant.metrics["LOAD_UTILIZATION_SPREAD_BPS"], 0
                )
                self.assertEqual(
                    variant.metrics["ROLE_LOAD_FAIRNESS_ROLE_COUNT"], 2
                )

    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = load_raw()
        cls.snapshot = Snapshot.from_dict(cls.raw)
        try:
            cls.engine = CpSatScheduleEngine(
                max_total_seconds=30, finalization_reserve_seconds=1
            )
        except SolverUnavailable as exc:
            raise unittest.SkipTest(str(exc)) from exc
        cls.variants = cls.engine.solve(cls.snapshot)

    def test_dynamic_strategy_count_and_true_hard_validation(self) -> None:
        self.assertEqual(len(self.variants), 2)
        self.assertEqual(
            {variant.strategy_id for variant in self.variants},
            {"strategy-cost", "strategy-preference"},
        )
        for variant in self.variants:
            report = validate_variant(self.snapshot, variant)
            self.assertTrue(report.valid, report.errors)
            self.assertEqual(report.unfilled_count, 0)
            self.assertTrue(variant.optimal)
            self.assertEqual(variant.stage_objectives[0]["name"], "UNFILLED")
            # Explicit employer inputs are authoritative regardless of the
            # contract label.
            self.assertEqual(variant.metrics["LOAD_UTILIZATION_TARGET_COUNT"], 3)
            self.assertEqual(
                variant.metrics["LOAD_UTILIZATION_EXPLICIT_TARGET_COUNT"], 3
            )
            self.assertEqual(variant.metrics["LOAD_UTILIZATION_FALLBACK_COUNT"], 0)
            self.assertIn("LOAD_UTILIZATION_SPREAD_BPS", variant.metrics)
            self.assertNotIn("LOAD_SPREAD_MINUTES", variant.metrics)

    def test_targetless_employee_still_participates_in_fairness(self) -> None:
        raw = load_raw()
        bob = next(employee for employee in raw["employees"] if employee["id"] == "employee-bob")
        bob.pop("nominalMonthlyMinutes", None)
        bob.pop("maximumMonthlyMinutes", None)
        snapshot = Snapshot.from_dict(raw)
        variants = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)
        for variant in variants:
            self.assertEqual(variant.metrics["LOAD_UTILIZATION_TARGET_COUNT"], 3)
            self.assertEqual(
                variant.metrics["LOAD_UTILIZATION_EXPLICIT_TARGET_COUNT"], 2
            )
            self.assertEqual(variant.metrics["LOAD_UTILIZATION_FALLBACK_COUNT"], 1)

    def test_fairness_first_strategy_cannot_regress_prior_verified_incumbent(self) -> None:
        raw = load_raw()
        raw["settings"]["requireOptimal"] = False
        fairness_terms = [
            {
                "tier": 1,
                "metric": "LOAD_UTILIZATION_SPREAD_BPS",
                "weight": 2,
                "direction": "MIN",
            },
            {
                "tier": 1,
                "metric": "NOMINAL_DEVIATION_MINUTES",
                "weight": 1,
                "direction": "MIN",
            },
        ]
        raw["strategies"] = [
            {
                "id": "strategy-fair-baseline",
                "code": "FAIR_BASELINE",
                "label": "Fair baseline",
                "sortOrder": 0,
                "timeLimitSeconds": 10,
                "objectiveTerms": fairness_terms,
            },
            {
                "id": "strategy-fair-business",
                "code": "FAIR_BUSINESS",
                "label": "Fair business",
                "sortOrder": 1,
                "timeLimitSeconds": 10,
                "objectiveTerms": [
                    *fairness_terms,
                    {
                        "tier": 2,
                        "metric": "TOTAL_COST",
                        "weight": 1,
                        "direction": "MIN",
                    },
                ],
            },
        ]
        variants = CpSatScheduleEngine(
            max_total_seconds=30,
            finalization_reserve_seconds=1,
        ).solve(Snapshot.from_dict(raw))
        by_strategy = {variant.strategy_id: variant for variant in variants}
        baseline = by_strategy["strategy-fair-baseline"]
        fair = by_strategy["strategy-fair-business"]
        self.assertLessEqual(
            fair.metrics["LOAD_UTILIZATION_SPREAD_BPS"],
            baseline.metrics["LOAD_UTILIZATION_SPREAD_BPS"],
        )
        self.assertLessEqual(
            fair.metrics["NOMINAL_DEVIATION_MINUTES"],
            baseline.metrics["NOMINAL_DEVIATION_MINUTES"],
        )
        self.assertEqual(
            fair.stage_objectives[0]["fairnessIncumbentGuard"],
            {
                "LOAD_UTILIZATION_SPREAD_BPS": baseline.metrics[
                    "LOAD_UTILIZATION_SPREAD_BPS"
                ],
                "NOMINAL_DEVIATION_MINUTES": baseline.metrics[
                    "NOMINAL_DEVIATION_MINUTES"
                ],
            },
        )

    def test_verified_zero_tier_does_not_consume_later_fairness_budget(self) -> None:
        raw = load_raw()
        raw["settings"]["requireOptimal"] = False
        raw["strategies"] = [
            {
                "id": "strategy-zero-then-fair",
                "code": "ZERO_THEN_FAIR",
                "label": "Zero then fair",
                "sortOrder": 0,
                "timeLimitSeconds": 20,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "PREFERENCE_VIOLATIONS",
                        "weight": 1,
                        "direction": "MIN",
                    },
                    {
                        "tier": 2,
                        "metric": "LOAD_UTILIZATION_SPREAD_BPS",
                        "weight": 1,
                        "direction": "MIN",
                    },
                ],
            }
        ]
        variant = CpSatScheduleEngine(
            max_total_seconds=30,
            finalization_reserve_seconds=1,
        ).solve(Snapshot.from_dict(raw))[0]
        zero_stage = next(
            stage
            for stage in variant.stage_objectives
            if any(
                term.get("metric") == "PREFERENCE_VIOLATIONS"
                for term in stage.get("terms", [])
            )
        )
        self.assertEqual(zero_stage["status"], "OPTIMAL")
        self.assertTrue(
            any(
                stage.get("name") == "TIER_2"
                for stage in variant.stage_objectives
            )
        )

    def test_every_strategy_applies_common_zero_hour_fairness_guard(self) -> None:
        raw = load_raw()
        raw["settings"]["requireOptimal"] = True
        variants = CpSatScheduleEngine(max_total_seconds=60).solve(
            Snapshot.from_dict(raw)
        )
        self.assertGreater(len(variants), 1)
        zero_counts = {
            variant.metrics["ZERO_TARGET_EMPLOYEE_COUNT"] for variant in variants
        }
        self.assertEqual(len(zero_counts), 1)
        for variant in variants:
            zero_hour_stage = next(
                stage
                for stage in variant.stage_objectives
                if any(
                    term.get("metric") == "ZERO_TARGET_EMPLOYEE_COUNT"
                    for term in stage.get("terms", [])
                )
            )
            self.assertEqual(zero_hour_stage["name"], "ZERO_HOUR_GUARD")
            self.assertEqual(zero_hour_stage["status"], "OPTIMAL")
            self.assertEqual(zero_hour_stage["value"], 0)
            self.assertEqual(zero_hour_stage["tier"], 0)
            guard_stage = next(
                stage
                for stage in variant.stage_objectives
                if any(
                    term.get("metric") == "COMMON_FAIRNESS_GUARD_SCORE"
                    for term in stage.get("terms", [])
                )
            )
            guard_term = next(
                term
                for term in guard_stage["terms"]
                if term.get("metric") == "COMMON_FAIRNESS_GUARD_SCORE"
            )
            self.assertEqual(guard_term["parameters"], {})
            self.assertEqual(guard_stage["tolerance"], 0)
            self.assertEqual(guard_stage["tier"], 0)

    def test_backup_role_hours_do_not_satisfy_primary_role_guard(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-04"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = False
        raw["roles"] = [
            {"id": "role-kelner", "code": "KELNER"},
            {"id": "role-host", "code": "HOST"},
        ]
        raw["duties"] = []
        raw["shiftTemplates"] = [
            {
                "id": "shift-kelner",
                "locationId": "location-rooftop",
                "startTime": "08:00",
                "endTime": "12:00",
                "weekdays": [6, 7, 1, 2],
            },
            {
                "id": "shift-host",
                "locationId": "location-rooftop",
                "startTime": "16:00",
                "endTime": "20:00",
                "weekdays": [6],
            },
        ]
        raw["demand"] = [
            {
                "id": "demand-kelner",
                "shiftTemplateId": "shift-kelner",
                "roleId": "role-kelner",
                "dutyIds": [],
                "requiredCount": 1,
                "dates": ["2026-08-02", "2026-08-03", "2026-08-04"],
            },
            {
                "id": "demand-host",
                "shiftTemplateId": "shift-host",
                "roleId": "role-host",
                "dutyIds": [],
                "requiredCount": 1,
                "dates": ["2026-08-01"],
            },
        ]

        employee_template = raw["employees"][0]
        common_employee = {
            **employee_template,
            "roleIds": ["role-kelner"],
            "roleGrants": [
                {
                    "roleId": "role-kelner",
                    "assignmentMode": "STANDARD",
                    "backupPriority": 100,
                }
            ],
            "dutyIds": [],
            "locationIds": ["location-rooftop"],
            "nominalMonthlyMinutes": 480,
            "maximumMonthlyMinutes": 960,
            "maximumWeeklyMinutes": 960,
            "maximumShiftsPerDay": 1,
            "softDayOffDates": [],
        }
        raw["employees"] = [
            {
                **common_employee,
                "id": "employee-tejlor",
                "roleIds": ["role-kelner", "role-host"],
                "roleGrants": [
                    {
                        "roleId": "role-kelner",
                        "assignmentMode": "STANDARD",
                        "backupPriority": 100,
                    },
                    {
                        "roleId": "role-host",
                        "assignmentMode": "BACKUP",
                        "backupPriority": 1,
                    },
                ],
                "baseHourlyRateMinor": 10_000,
                "preferredShiftTemplateIds": ["shift-host"],
            },
            {
                **common_employee,
                "id": "employee-kelner-a",
                "baseHourlyRateMinor": 1_000,
                "preferredShiftTemplateIds": ["shift-kelner"],
            },
            {
                **common_employee,
                "id": "employee-kelner-b",
                "baseHourlyRateMinor": 1_000,
                "preferredShiftTemplateIds": ["shift-kelner"],
            },
        ]
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        # No employee has HOST as STANDARD, so this single BACKUP use is a
        # genuine structural shortage rather than a cheaper replacement for
        # ordinary HOST capacity.
        raw["lockedAssignments"] = []
        raw["baselineAssignments"] = []
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["strategies"] = [
            {
                "id": "strategy-balanced",
                "code": "BALANCED",
                "label": "Zrownowazony",
                "sortOrder": 0,
                "timeLimitSeconds": 30,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "NOMINAL_DEVIATION_MINUTES",
                        "weight": 1,
                        "direction": "MIN",
                    }
                ],
            },
            {
                "id": "strategy-cost",
                "code": "COST",
                "label": "Minimalny koszt",
                "sortOrder": 1,
                "timeLimitSeconds": 30,
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
                "id": "strategy-preference",
                "code": "PREFERENCE",
                "label": "Preferencje i rowny podzial",
                "sortOrder": 2,
                "timeLimitSeconds": 30,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "PREFERENCE_VIOLATIONS",
                        "weight": 1,
                        "direction": "MIN",
                    }
                ],
            },
        ]

        unproven_snapshot = Snapshot.from_dict(raw)
        unproven_engine = CpSatScheduleEngine(max_total_seconds=90)
        original_solve_model = unproven_engine._solve_model

        def downgrade_backup_proof(*args, **kwargs):
            solver, status = original_solve_model(*args, **kwargs)
            if kwargs.get("stage_name") == "UNFILLED":
                return solver, cp_model.FEASIBLE
            return solver, status

        with (
            patch.object(
                unproven_engine,
                "_solve_model",
                side_effect=downgrade_backup_proof,
            ),
            self.assertRaisesRegex(
                OptimizationIncomplete,
                "ROLE_BACKUP_PENALTY_UNPROVEN",
            ),
        ):
            unproven_engine.solve(unproven_snapshot)

        # A positive guard result is a business claim that hard constraints
        # made the missing hours unavoidable.  In relaxed planning it may only
        # be exposed after CP-SAT proves that positive minimum optimal.  The
        # two smaller rosters force respectively one missing STANDARD-role
        # assignment and one globally zero-hour employee.
        for guard_stage, kelner_dates, error_code in [
            (
                "TIER_-2",
                ["2026-08-02", "2026-08-03"],
                "PRIMARY_ROLE_GUARD_UNPROVEN",
            ),
            (
                "TIER_-3",
                ["2026-08-02"],
                "ZERO_HOUR_GUARD_UNPROVEN",
            ),
        ]:
            guard_raw = copy.deepcopy(raw)
            guard_raw["demand"][0]["dates"] = kelner_dates
            guard_snapshot = Snapshot.from_dict(guard_raw)
            guard_engine = CpSatScheduleEngine(max_total_seconds=90)
            original_guard_solve_model = guard_engine._solve_model

            def downgrade_guard_proof(*args, **kwargs):
                solver, status = original_guard_solve_model(*args, **kwargs)
                if kwargs.get("stage_name") == guard_stage:
                    return solver, cp_model.FEASIBLE
                return solver, status

            with (
                self.subTest(guard=error_code),
                patch.object(
                    guard_engine,
                    "_solve_model",
                    side_effect=downgrade_guard_proof,
                ),
                self.assertRaisesRegex(OptimizationIncomplete, error_code),
            ):
                guard_engine.solve(guard_snapshot)

        snapshot = Snapshot.from_dict(raw)
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        variants = CpSatScheduleEngine(max_total_seconds=90).solve(snapshot)

        self.assertEqual(len(variants), 3)
        for variant in variants:
            with self.subTest(strategy=variant.strategy_code):
                tejlor_roles = [
                    slots[assignment.slot_id].role_id
                    for assignment in variant.assignments
                    if assignment.employee_id == "employee-tejlor"
                ]
                self.assertIn("role-host", tejlor_roles)
                self.assertIn("role-kelner", tejlor_roles)
                self.assertEqual(
                    variant.metrics["ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"], 0
                )

                self.assertEqual(variant.metrics["ROLE_BACKUP_PENALTY"], 1)
                primary_guard_stage = next(
                    stage
                    for stage in variant.stage_objectives
                    if any(
                        term.get("metric")
                        == "ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"
                        for term in stage.get("terms", [])
                    )
                )
                self.assertEqual(primary_guard_stage["name"], "PRIMARY_ROLE_GUARD")
                self.assertEqual(primary_guard_stage["value"], 0)
                self.assertEqual(primary_guard_stage["status"], "OPTIMAL")

        standard_capacity_raw = copy.deepcopy(raw)
        standard_capacity_raw["employees"].append(
            {
                **common_employee,
                "id": "employee-host-standard",
                "roleIds": ["role-host"],
                "roleGrants": [
                    {
                        "roleId": "role-host",
                        "assignmentMode": "STANDARD",
                        "backupPriority": 100,
                    }
                ],
                "baseHourlyRateMinor": 20_000,
                "preferredShiftTemplateIds": ["shift-host"],
            }
        )
        standard_snapshot = Snapshot.from_dict(standard_capacity_raw)
        standard_slots = {
            slot.id: slot for slot in generate_slots(standard_snapshot)
        }
        standard_variants = CpSatScheduleEngine(max_total_seconds=90).solve(
            standard_snapshot
        )
        for variant in standard_variants:
            with self.subTest(strategy=variant.strategy_code, host_capacity="STANDARD"):
                tejlor_roles = [
                    standard_slots[assignment.slot_id].role_id
                    for assignment in variant.assignments
                    if assignment.employee_id == "employee-tejlor"
                ]
                self.assertIn("role-kelner", tejlor_roles)
                self.assertNotIn("role-host", tejlor_roles)
                self.assertEqual(variant.metrics["ROLE_BACKUP_PENALTY"], 0)
                self.assertEqual(
                    variant.metrics["ZERO_PRIMARY_ROLE_ASSIGNMENT_COUNT"], 0
                )

    def test_complete_greedy_hint_cannot_freeze_avoidable_backup_role(self) -> None:
        """Regression for the real SALA/HOST Tejlor and Weronika failure.

        The old coverage stage fixed every value from a complete greedy hint.
        An alphabetically earlier BACKUP employee was therefore accepted as an
        "OPTIMAL" HOST assignment even though an idle STANDARD HOST employee
        was fully eligible.  The hint may seed the search, never define it.
        """

        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-01"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = False
        raw["roles"] = [{"id": "role-host", "code": "HOST"}]
        raw["duties"] = []
        raw["shiftTemplates"] = [
            {
                "id": "shift-host-early",
                "locationId": "location-rooftop",
                "startTime": "16:00",
                "endTime": "20:00",
                "weekdays": [6],
            },
            {
                "id": "shift-host-late",
                "locationId": "location-rooftop",
                "startTime": "17:00",
                "endTime": "21:00",
                "weekdays": [6],
            }
        ]
        raw["demand"] = [
            {
                "id": "demand-host-early",
                "shiftTemplateId": "shift-host-early",
                "roleId": "role-host",
                "dutyIds": [],
                "requiredCount": 1,
                "dates": ["2026-08-01"],
            },
            {
                "id": "demand-host-late",
                "shiftTemplateId": "shift-host-late",
                "roleId": "role-host",
                "dutyIds": [],
                "requiredCount": 1,
                "dates": ["2026-08-01"],
            }
        ]
        employee_template = raw["employees"][0]
        common_employee = {
            **employee_template,
            "roleIds": ["role-host"],
            "dutyIds": [],
            "locationIds": ["location-rooftop"],
            "nominalMonthlyMinutes": 10_800,
            "maximumMonthlyMinutes": 13_200,
            "maximumWeeklyMinutes": 3_600,
            "maximumShiftsPerDay": 1,
            "softDayOffDates": [],
            "blockedShiftTemplateIds": [],
        }
        raw["employees"] = [
            {
                **common_employee,
                "id": "a-standard-both",
                "roleGrants": [
                    {
                        "roleId": "role-host",
                        "assignmentMode": "STANDARD",
                        "backupPriority": 100,
                    }
                ],
            },
            {
                **common_employee,
                "id": "b-backup-both",
                "roleGrants": [
                    {
                        "roleId": "role-host",
                        "assignmentMode": "BACKUP",
                        "backupPriority": 100,
                    }
                ],
            },
            {
                **common_employee,
                "id": "c-standard-early",
                "blockedShiftTemplateIds": ["shift-host-late"],
                "roleGrants": [
                    {
                        "roleId": "role-host",
                        "assignmentMode": "STANDARD",
                        "backupPriority": 100,
                    }
                ],
            },
            {
                **common_employee,
                "id": "d-backup-late",
                "blockedShiftTemplateIds": ["shift-host-early"],
                "roleGrants": [
                    {
                        "roleId": "role-host",
                        "assignmentMode": "BACKUP",
                        "backupPriority": 100,
                    }
                ],
            },
        ]
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        raw["lockedAssignments"] = []

        snapshot = Snapshot.from_dict(raw)
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        variants = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)

        for variant in variants:
            with self.subTest(strategy=variant.strategy_code):
                self.assertEqual(variant.metrics["ROLE_BACKUP_PENALTY"], 0)
                self.assertEqual(len(variant.assignments), 2)
                assigned = {
                    slots[assignment.slot_id].shift_template_id: assignment.employee_id
                    for assignment in variant.assignments
                }
                self.assertEqual(assigned["shift-host-early"], "c-standard-early")
                self.assertEqual(assigned["shift-host-late"], "a-standard-both")

    def test_all_strategies_share_work_by_estimated_target_in_role_location_pool(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-10"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        morning = next(
            item for item in raw["shiftTemplates"] if item["id"] == "shift-morning"
        )
        morning["weekdays"] = [1, 2, 3, 4, 5, 6, 7]
        raw["shiftTemplates"] = [morning]
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dates": [f"2026-08-{day:02d}" for day in range(1, 11)],
                "requiredCount": 1,
            }
        ]
        employees = [
            employee
            for employee in raw["employees"]
            if employee["id"] in {"employee-bob", "employee-charlie"}
        ]
        for employee in employees:
            employee["nominalMonthlyMinutes"] = 2_400
            employee["maximumMonthlyMinutes"] = 2_400
            employee["maximumWeeklyMinutes"] = 2_400
            employee["softDayOffDates"] = []
        employees[0]["baseHourlyRateMinor"] = 1_000
        employees[1]["baseHourlyRateMinor"] = 10_000
        raw["employees"] = employees
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        raw["lockedAssignments"] = []
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}

        variants = CpSatScheduleEngine(max_total_seconds=60).solve(
            Snapshot.from_dict(raw)
        )
        self.assertEqual(len(variants), 2)
        for variant in variants:
            counts = {
                employee["id"]: sum(
                    assignment.employee_id == employee["id"]
                    for assignment in variant.assignments
                )
                for employee in employees
            }
            self.assertEqual(counts, {"employee-bob": 5, "employee-charlie": 5})
            self.assertEqual(variant.metrics["ZERO_TARGET_EMPLOYEE_COUNT"], 0)
            self.assertEqual(variant.metrics["LOAD_UTILIZATION_SPREAD_BPS"], 0)
            self.assertEqual(variant.metrics["ROLE_LOCATION_FAIRNESS_POOL_COUNT"], 1)
            self.assertEqual(
                variant.metrics["ESTIMATED_ACHIEVABLE_TARGET_MINUTES_TOTAL"],
                4_320,
            )

    def test_preferences_strategy_fairness_precedes_extreme_preferences(self) -> None:
        """B4F-159: protect the accepted fairness-first product hierarchy."""
        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-19"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        shift = next(item for item in raw["shiftTemplates"] if item["id"] == "shift-morning")
        shift["weekdays"] = [1, 2, 3, 4, 5, 6, 7]
        raw["shiftTemplates"] = [shift]
        raw["demand"] = [{
            **raw["demand"][0],
            "dates": [f"2026-08-{day:02d}" for day in range(1, 20)],
            "requiredCount": 1,
        }]
        employees = [
            employee
            for employee in raw["employees"]
            if employee["id"] in {"employee-bob", "employee-charlie"}
        ]
        for employee in employees:
            employee["nominalMonthlyMinutes"] = 2_400
            employee["maximumMonthlyMinutes"] = 4_800
            employee["maximumWeeklyMinutes"] = 4_800
            employee["softDayOffDates"] = []
        employees[0]["softDayOffDates"] = [
            f"2026-08-{day:02d}" for day in range(1, 20)
        ]
        raw["employees"] = employees
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        raw["lockedAssignments"] = []
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["strategies"] = [{
            "id": "strategy-preferences-fairness",
            "code": "PREFERENCES",
            "label": "Preferencje i rowny podzial",
            "sortOrder": 0,
            "timeLimitSeconds": 30,
            "objectiveTerms": [
                {"tier": 1, "metric": "PREFERENCE_VIOLATIONS", "weight": 250_000, "direction": "MIN"},
                {"tier": 2, "metric": "ROLE_LOAD_FAIRNESS_SCORE", "weight": 1, "direction": "MIN"},
                {"tier": 3, "metric": "NOMINAL_DEVIATION_MINUTES", "weight": 1, "direction": "MIN"},
            ],
        }]

        variant = CpSatScheduleEngine(max_total_seconds=45).solve(
            Snapshot.from_dict(raw)
        )[0]
        counts = Counter(item.employee_id for item in variant.assignments)
        self.assertLessEqual(abs(counts[employees[0]["id"]] - counts[employees[1]["id"]]), 1)
        self.assertLess(
            next(stage["tier"] for stage in variant.stage_objectives if any(term.get("metric") == "ROLE_LOAD_FAIRNESS_SCORE" for term in stage.get("terms", []))),
            next(stage["tier"] for stage in variant.stage_objectives if any(term.get("metric") == "PREFERENCE_VIOLATIONS" for term in stage.get("terms", []))),
        )
        self.assertGreater(variant.metrics["PREFERENCE_VIOLATIONS"], 0)
        stage_names = [stage["name"] for stage in variant.stage_objectives]
        coverage_stage = variant.stage_objectives[0]
        self.assertEqual(coverage_stage["name"], "UNFILLED")
        self.assertIn("roleBackupPenalty", coverage_stage)
        self.assertIn("overtimeMinimum", coverage_stage)
        self.assertLess(
            stage_names.index("ZERO_HOUR_GUARD"),
            stage_names.index("PRIMARY_ROLE_GUARD"),
        )
        self.assertLess(
            stage_names.index("PRIMARY_ROLE_GUARD"),
            stage_names.index("COMMON_FAIRNESS_GUARD"),
        )
        self.assertLess(
            stage_names.index("COMMON_FAIRNESS_GUARD"),
            stage_names.index("ESTIMATED_ACHIEVABLE_TARGET_SPREAD_GUARD"),
        )
        metric_stage = {
            term["metric"]: index
            for index, stage in enumerate(variant.stage_objectives)
            for term in stage.get("terms", [])
        }
        self.assertLess(
            metric_stage[
                "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
            ],
            metric_stage["ROLE_LOAD_FAIRNESS_SCORE"],
        )
        self.assertLess(
            metric_stage["ROLE_LOAD_FAIRNESS_SCORE"],
            metric_stage["NOMINAL_DEVIATION_MINUTES"],
        )
        self.assertLess(
            metric_stage["NOMINAL_DEVIATION_MINUTES"],
            metric_stage["PREFERENCE_VIOLATIONS"],
        )

    def test_preferences_shortage_is_proportional_to_individual_targets(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-09"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        shift = next(item for item in raw["shiftTemplates"] if item["id"] == "shift-morning")
        shift.update({"startTime": "08:00", "endTime": "09:00", "weekdays": [1, 2, 3, 4, 5, 6, 7]})
        raw["shiftTemplates"] = [shift]
        raw["demand"] = [{
            **raw["demand"][0],
            "dates": [f"2026-08-{day:02d}" for day in range(1, 10)],
            "requiredCount": 1,
        }]
        employees = copy.deepcopy(raw["employees"])
        targets = [240, 480, 360]
        for employee, target in zip(employees, targets, strict=True):
            employee["nominalMonthlyMinutes"] = target
            employee["maximumMonthlyMinutes"] = 1_000
            employee["maximumWeeklyMinutes"] = 1_000
            employee["softDayOffDates"] = []
            employee["dutyIds"] = ["duty-service", "duty-close"]
        raw["employees"] = employees
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        raw["lockedAssignments"] = []
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["strategies"] = [{
            "id": "strategy-preferences-proportional",
            "code": "PREFERENCES",
            "label": "Preferencje i rowny podzial",
            "sortOrder": 0,
            "timeLimitSeconds": 30,
            "objectiveTerms": [
                {"tier": 1, "metric": "PREFERENCE_VIOLATIONS", "weight": 1, "direction": "MIN"},
                {"tier": 2, "metric": "ROLE_LOAD_FAIRNESS_SCORE", "weight": 1, "direction": "MIN"},
            ],
        }]
        variant = CpSatScheduleEngine(max_total_seconds=45).solve(Snapshot.from_dict(raw))[0]
        minutes = Counter(item.employee_id for item in variant.assignments)
        fulfillments = [minutes[employee["id"]] * 1000 // target for employee, target in zip(employees, targets, strict=True)]
        self.assertLessEqual(max(fulfillments) - min(fulfillments), 250)
        self.assertEqual(
            variant.metrics[
                "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
            ],
            max(fulfillments) - min(fulfillments),
        )

    def test_preferences_ten_identical_employees_split_month_exactly(self) -> None:
        """B4F-119 A: no preferences means a genuinely equal split, not 10/180 h."""
        raw = load_raw()
        raw.pop("slots")
        raw["periodStart"] = "2026-08-01"
        raw["periodEnd"] = "2026-08-30"
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        shift = next(
            item for item in raw["shiftTemplates"] if item["id"] == "shift-morning"
        )
        shift.update(
            {
                "startTime": "08:00",
                "endTime": "09:00",
                "weekdays": [1, 2, 3, 4, 5, 6, 7],
            }
        )
        raw["shiftTemplates"] = [shift]
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dates": [f"2026-08-{day:02d}" for day in range(1, 31)],
                "requiredCount": 1,
            }
        ]
        template = next(
            employee
            for employee in raw["employees"]
            if employee["id"] == "employee-bob"
        )
        employees = []
        for index in range(10):
            employee = copy.deepcopy(template)
            employee.update(
                {
                    "id": f"employee-fair-{index:02d}",
                    "nominalMonthlyMinutes": 180,
                    "maximumMonthlyMinutes": 600,
                    "maximumWeeklyMinutes": 600,
                    "softDayOffDates": [],
                    "preferredShiftTemplateIds": [],
                    "avoidedShiftTemplateIds": [],
                }
            )
            employees.append(employee)
        raw["employees"] = employees
        raw["availabilityWindows"] = []
        raw["hardBlocks"] = []
        raw["externalAssignments"] = []
        raw["lockedAssignments"] = []
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["strategies"] = [
            {
                "id": "strategy-preferences-ten-equal",
                "code": "PREFERENCES",
                "label": "Preferencje i rowny podzial",
                "sortOrder": 0,
                "timeLimitSeconds": 30,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "PREFERENCE_VIOLATIONS",
                        "weight": 1,
                        "direction": "MIN",
                    },
                    {
                        "tier": 2,
                        "metric": "ROLE_LOAD_FAIRNESS_SCORE",
                        "weight": 1,
                        "direction": "MIN",
                    },
                ],
            }
        ]

        variant = CpSatScheduleEngine(max_total_seconds=60).solve(
            Snapshot.from_dict(raw)
        )[0]
        counts = Counter(item.employee_id for item in variant.assignments)
        self.assertEqual(sorted(counts.values()), [3] * 10)
        self.assertEqual(variant.metrics["PREFERENCE_VIOLATIONS"], 0)
        self.assertEqual(
            variant.metrics[
                "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS"
            ],
            0,
        )

    def test_daily_standby_reserve_never_creates_vacancies(self) -> None:
        raw = load_raw()
        raw["settings"]["standbyTiersPerRoleDay"] = 2
        snapshot = Snapshot.from_dict(raw)
        variants = CpSatScheduleEngine(
            max_total_seconds=30,
            finalization_reserve_seconds=1,
        ).solve(snapshot)
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        for variant in variants:
            assignments_by_employee_day: dict[tuple[str, str], int] = {}
            for assignment in variant.assignments:
                day = slots[assignment.slot_id].date.isoformat()
                key = (assignment.employee_id, day)
                assignments_by_employee_day[key] = (
                    assignments_by_employee_day.get(key, 0) + 1
                )
            self.assertTrue(
                all(count <= 1 for count in assignments_by_employee_day.values())
            )
            self.assertEqual(len(variant.unfilled_slot_ids), 0)

    def _flexible_single_employee_sequence_snapshot(
        self, locked_slot_ids: list[str], maximum_shifts_per_day: int = 1
    ) -> Snapshot:
        raw = load_raw()
        raw.pop("slots")
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = False
        raw["strategies"] = [raw["strategies"][0]]
        raw["shiftTemplates"][0]["sequenceOrder"] = 1
        raw["shiftTemplates"][1]["sequenceOrder"] = 2
        employee = next(
            item for item in raw["employees"] if item["id"] == "employee-bob"
        )
        employee.update(
            {
                "contractCode": "ZLECENIE",
                "workTimePolicy": "CONTRACT_DEFAULT",
                "maximumShiftsPerDay": maximum_shifts_per_day,
                "minimumRestMinutes": 0,
            }
        )
        raw["employees"] = [employee]
        raw["availabilityWindows"] = []
        raw["lockedAssignments"] = [
            {"slotId": slot_id, "employeeId": employee["id"]}
            for slot_id in locked_slot_ids
        ]
        return Snapshot.from_dict(raw)

    def test_daily_limit_one_rejects_two_employee_shifts_per_day(
        self,
    ) -> None:
        snapshot = self._flexible_single_employee_sequence_snapshot(
            [
                (
                    "2026-08-01|shift-morning|role-sommelier|duty-service|"
                    "demand-morning|1"
                ),
                (
                    "2026-08-01|shift-evening|role-sommelier|"
                    "duty-close,duty-service|demand-evening|1"
                ),
            ]
        )
        with self.assertRaises(OptimizationError):
            self.engine.solve(snapshot)

    def test_daily_limit_two_allows_two_non_overlapping_shifts_per_day(
        self,
    ) -> None:
        snapshot = self._flexible_single_employee_sequence_snapshot(
            [
                (
                    "2026-08-01|shift-morning|role-sommelier|duty-service|"
                    "demand-morning|1"
                ),
                (
                    "2026-08-01|shift-evening|role-sommelier|"
                    "duty-close,duty-service|demand-evening|1"
                ),
            ],
            maximum_shifts_per_day=2,
        )
        variant = self.engine.solve(snapshot)[0]
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        assignments_on_test_day = [
            assignment
            for assignment in variant.assignments
            if slots[assignment.slot_id].date.isoformat() == "2026-08-01"
        ]
        self.assertEqual(len(assignments_on_test_day), 2)
        report = validate_variant(snapshot, variant)
        self.assertTrue(report.valid, report.errors)

    def test_last_shift_cannot_be_followed_by_first_shift_next_day(self) -> None:
        snapshot = self._flexible_single_employee_sequence_snapshot(
            [
                (
                    "2026-08-01|shift-evening|role-sommelier|"
                    "duty-close,duty-service|demand-evening|1"
                ),
                (
                    "2026-08-02|shift-morning|role-sommelier|duty-service|"
                    "demand-morning|1"
                ),
            ]
        )
        with self.assertRaises(OptimizationError):
            self.engine.solve(snapshot)

    def test_morning_can_be_followed_by_evening_on_the_next_day(self) -> None:
        snapshot = self._flexible_single_employee_sequence_snapshot(
            [
                (
                    "2026-08-01|shift-morning|role-sommelier|duty-service|"
                    "demand-morning|1"
                ),
                (
                    "2026-08-02|shift-evening|role-sommelier|"
                    "duty-close,duty-service|demand-evening|1"
                ),
            ]
        )
        variant = self.engine.solve(snapshot)[0]
        self.assertEqual(len(variant.assignments), 2)
        report = validate_variant(snapshot, variant)
        self.assertTrue(report.valid, report.errors)

    def test_independent_validator_rejects_daily_and_sequence_invariants(
        self,
    ) -> None:
        snapshot = self._flexible_single_employee_sequence_snapshot(
            [
                (
                    "2026-08-01|shift-morning|role-sommelier|duty-service|"
                    "demand-morning|1"
                ),
                (
                    "2026-08-02|shift-evening|role-sommelier|"
                    "duty-close,duty-service|demand-evening|1"
                ),
            ]
        )
        valid = self.engine.solve(snapshot)[0]
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        morning_day_one = next(
            assignment
            for assignment in valid.assignments
            if slots[assignment.slot_id].date.isoformat() == "2026-08-01"
        )
        evening_day_two = next(
            assignment
            for assignment in valid.assignments
            if slots[assignment.slot_id].date.isoformat() == "2026-08-02"
        )

        same_day = replace(
            valid,
            assignments=(
                morning_day_one,
                replace(
                    evening_day_two,
                    slot_id=(
                        "2026-08-01|shift-evening|role-sommelier|"
                        "duty-close,duty-service|demand-evening|1"
                    ),
                ),
            ),
        )
        same_day_report = validate_variant(snapshot, same_day)
        self.assertTrue(
            any(
                error.startswith("DAILY_SHIFT_LIMIT:")
                for error in same_day_report.errors
            )
        )

        last_then_first = replace(
            valid,
            assignments=(
                replace(
                    morning_day_one,
                    slot_id=(
                        "2026-08-01|shift-evening|role-sommelier|"
                        "duty-close,duty-service|demand-evening|1"
                    ),
                ),
                replace(
                    evening_day_two,
                    slot_id=(
                        "2026-08-02|shift-morning|role-sommelier|duty-service|"
                        "demand-morning|1"
                    ),
                ),
            ),
        )
        sequence_report = validate_variant(snapshot, last_then_first)
        self.assertTrue(
            any(
                error.startswith("CONSECUTIVE_SHIFT_SEQUENCE:")
                for error in sequence_report.errors
            )
        )

    def test_strategy_reuses_coverage_solution_and_skips_fixed_tier(self) -> None:
        raw = load_raw()
        for strategy in raw["strategies"]:
            for term in strategy["objectiveTerms"]:
                term["tier"] += 1
            strategy["objectiveTerms"].insert(
                0,
                {
                    "tier": 1,
                    "metric": "UNFILLED",
                    "weight": 1_000,
                    "direction": "MIN",
                    "tolerance": 0,
                    "parameters": {},
                },
            )
        snapshot = Snapshot.from_dict(raw)
        engine = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        )
        original_solve_model = engine._solve_model
        strategy_stages: list[str] = []
        initial_hint_counts: list[int] = []

        def observe_stages(*args, **kwargs):
            strategy = kwargs.get("strategy")
            stage_name = kwargs["stage_name"]
            if strategy is not None:
                strategy_stages.append(stage_name)
                if stage_name == "TIER_2":
                    model = args[0]
                    initial_hint_counts.append(len(model.proto.solution_hint.vars))
            return original_solve_model(*args, **kwargs)

        with patch.object(engine, "_solve_model", side_effect=observe_stages):
            variants = engine.solve(snapshot)

        self.assertEqual(len(variants), 2)
        self.assertNotIn("TIER_1", strategy_stages)
        self.assertTrue(initial_hint_counts)
        self.assertTrue(all(count > 0 for count in initial_hint_counts))
        for variant in variants:
            fixed_tier = next(
                stage for stage in variant.stage_objectives
                if stage.get("name") == "TIER_1"
            )
            self.assertEqual(fixed_tier["name"], "TIER_1")
            self.assertEqual(fixed_tier["status"], "OPTIMAL")

    def test_relaxed_strategy_completes_full_model_hint_before_tiers(self) -> None:
        snapshot = replace(
            self.snapshot,
            settings=replace(self.snapshot.settings, require_optimal=False),
        )
        engine = CpSatScheduleEngine(
            max_total_seconds=120,
            finalization_reserve_seconds=5,
        )
        original_solve_model = engine._solve_model
        warm_start_limits: list[float] = []
        full_hint_counts: list[tuple[int, int]] = []
        tier_presolve_flags: list[bool] = []
        strategies_with_checked_hint: set[str] = set()

        def observe_stages(*args, **kwargs):
            model = args[0]
            strategy = kwargs.get("strategy")
            stage_name = kwargs["stage_name"]
            if (
                strategy is not None
                and stage_name.startswith("TIER_")
                and strategy.id not in strategies_with_checked_hint
            ):
                full_hint_counts.append(
                    (
                        len(model.proto.solution_hint.vars),
                        len(model.proto.variables),
                    )
                )
                strategies_with_checked_hint.add(strategy.id)
            if strategy is not None and stage_name.startswith("TIER_"):
                tier_presolve_flags.append(kwargs.get("disable_presolve", False))
            result = original_solve_model(*args, **kwargs)
            if stage_name == "WARM_START":
                self.assertTrue(kwargs.get("fix_hints", False))
                self.assertIsNone(strategy)
                warm_start_limits.append(kwargs["time_limit_seconds"])
            return result

        with patch.object(engine, "_solve_model", side_effect=observe_stages):
            variants = engine.solve(snapshot)

        self.assertEqual(len(warm_start_limits), 1)
        self.assertTrue(all(limit <= 15.0 for limit in warm_start_limits))
        self.assertEqual(len(full_hint_counts), len(snapshot.strategies))
        self.assertTrue(tier_presolve_flags)
        self.assertTrue(all(tier_presolve_flags))
        self.assertTrue(
            all(
                0 < hint_count < variable_count
                for hint_count, variable_count in full_hint_counts
            )
        )
        for variant in variants:
            report = validate_variant(snapshot, variant)
            self.assertTrue(report.valid, report.errors)

    def test_fixed_warm_start_skips_redundant_full_model_presolve(self) -> None:
        fixed = self.engine._new_solver(
            self.snapshot,
            self.snapshot.strategies[0],
            1.0,
            fix_hints=True,
        )
        regular = self.engine._new_solver(
            self.snapshot,
            self.snapshot.strategies[0],
            1.0,
        )
        bounded = self.engine._new_solver(
            self.snapshot,
            self.snapshot.strategies[0],
            1.0,
            disable_presolve=True,
        )

        self.assertFalse(fixed.parameters.cp_model_presolve)
        self.assertFalse(bounded.parameters.cp_model_presolve)
        self.assertTrue(regular.parameters.cp_model_presolve)

    def test_relaxed_strategy_keeps_valid_dominated_fallback_comparison(self) -> None:
        snapshot = replace(
            self.snapshot,
            settings=replace(self.snapshot.settings, require_optimal=False),
        )
        engine = CpSatScheduleEngine(
            max_total_seconds=120,
            finalization_reserve_seconds=5,
        )
        original_solve_model = engine._solve_model
        forced_unknown_stages: list[str] = []

        def force_unknown(*args, **kwargs):
            stage_name = kwargs["stage_name"]
            if stage_name.startswith("TIER_"):
                forced_unknown_stages.append(stage_name)
                return object(), cp_model.UNKNOWN
            return original_solve_model(*args, **kwargs)

        with patch.object(engine, "_solve_model", side_effect=force_unknown):
            results = engine.solve(snapshot)

        self.assertTrue(forced_unknown_stages)
        self.assertEqual(len(snapshot.strategies), len(results))

    def test_require_optimal_name_matches_feasible_status_semantics(self) -> None:
        class FeasibleSolver:
            @staticmethod
            def status_name(_status):
                return "FEASIBLE"

        relaxed = replace(
            self.snapshot,
            settings=replace(self.snapshot.settings, require_optimal=False),
        )
        self.assertFalse(
            self.engine._require_optimal(
                FeasibleSolver(), cp_model.FEASIBLE, relaxed, "TEST"
            )
        )
        with self.assertRaises(OptimizationIncomplete):
            self.engine._require_optimal(
                FeasibleSolver(), cp_model.FEASIBLE, self.snapshot, "TEST"
            )

    def test_incomplete_status_reports_solver_proof_diagnostics(self) -> None:
        class FeasibleSolver:
            objective_value = 7.0
            best_objective_bound = 5.0
            wall_time = 12.5
            num_branches = 321
            num_conflicts = 45

            @staticmethod
            def status_name(_status):
                return "FEASIBLE"

        with self.assertRaisesRegex(
            OptimizationIncomplete,
            r"status=FEASIBLE; objectiveValue=7; bestBound=5; "
            r"absoluteGap=2; wallTimeSeconds=12.5; branches=321; conflicts=45",
        ):
            self.engine._require_optimal(
                FeasibleSolver(), cp_model.FEASIBLE, self.snapshot, "UNFILLED"
            )

    def test_coverage_model_aggregates_interchangeable_seats(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodEnd"] = "2026-08-01"
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dates": ["2026-08-01"],
                "requiredCount": 2,
            }
        ]
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        artifacts = self.engine._build_model(
            snapshot,
            slots,
            EligibilityIndex(snapshot),
            coverage_only=True,
        )

        self.assertEqual(artifacts.coverage_symmetry_constraints, 0)
        self.assertEqual(artifacts.coverage_aggregated_seats, 1)
        self.assertEqual(len(artifacts.unfilled), 1)
        self.assertTrue(artifacts.complete_coverage_hint)
        self.assertGreater(len(artifacts.model.proto.solution_hint.vars), 0)
        artifacts.model.minimize(artifacts.metrics["UNFILLED"])
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1
        solver.parameters.fix_variables_to_their_hinted_value = True
        status = solver.solve(artifacts.model)
        self.assertEqual(status, cp_model.OPTIMAL)
        self.assertEqual(solver.value(artifacts.metrics["UNFILLED"]), 0)

    def test_aggregate_coverage_hint_accounts_for_unfilled_seats(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodEnd"] = "2026-08-01"
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dates": ["2026-08-01"],
                "requiredCount": 4,
            }
        ]
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        artifacts = self.engine._build_model(
            snapshot,
            slots,
            EligibilityIndex(snapshot),
            coverage_only=True,
        )

        hint = dict(
            zip(
                artifacts.model.proto.solution_hint.vars,
                artifacts.model.proto.solution_hint.values,
                strict=True,
            )
        )
        selected = sum(hint[variable.index] for variable in artifacts.x.values())
        missing = next(iter(artifacts.unfilled.values()))
        self.assertEqual(hint[missing.index], len(slots) - selected)
        self.assertFalse(artifacts.complete_coverage_hint)

        artifacts.model.minimize(artifacts.metrics["UNFILLED"])
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1
        solver.parameters.fix_variables_to_their_hinted_value = True
        status = solver.solve(artifacts.model)
        self.assertEqual(status, cp_model.OPTIMAL)
        self.assertEqual(
            solver.value(artifacts.metrics["UNFILLED"]),
            len(slots) - selected,
        )

    def test_relaxed_coverage_stage_uses_matrix_derived_uat_budget(self) -> None:
        snapshot = replace(
            self.snapshot,
            settings=replace(self.snapshot.settings, require_optimal=False),
            strategies=tuple(
                replace(strategy, time_limit_seconds=120)
                for strategy in self.snapshot.strategies
            ),
        )
        engine = CpSatScheduleEngine(
            max_total_seconds=900,
            finalization_reserve_seconds=30,
        )
        original_solve_model = engine._solve_model
        observed_limit: list[float] = []

        def observe_limit(*args, **kwargs):
            if kwargs["stage_name"] == "UNFILLED":
                observed_limit.append(kwargs["time_limit_seconds"])
            return original_solve_model(*args, **kwargs)

        with patch.object(engine, "_solve_model", side_effect=observe_limit):
            engine.solve(snapshot)

        self.assertEqual(observed_limit, [240.0])

    def test_relaxed_identical_strategies_receive_distinct_tied_rosters(
        self,
    ) -> None:
        raw = load_raw()
        template = raw["strategies"][0]
        raw["settings"]["requireOptimal"] = False
        raw["strategies"] = [
            {
                **template,
                "id": f"strategy-tied-{index}",
                "code": f"TIED_{index}",
                "label": f"Tied {index}",
                "sortOrder": index,
            }
            for index in range(2)
        ]
        snapshot = Snapshot.from_dict(raw)
        variants = CpSatScheduleEngine(
            max_total_seconds=120,
            finalization_reserve_seconds=5,
        ).solve(snapshot)

        self.assertEqual(len({item.solution_hash for item in variants}), 2)
        self.assertIsNone(variants[0].equivalent_to_strategy_id)
        for variant in variants[1:]:
            self.assertIsNone(variant.equivalent_to_strategy_id)
            final_stage = variant.stage_objectives[-1]
            # A second tied strategy may already find a distinct roster during
            # its normal tier solve.  The explicit diversity pass is required
            # only when that first result duplicates an earlier solution.
            if final_stage["name"] == "DIVERSIFY":
                self.assertTrue(final_stage["businessObjectiveBoundsPreserved"])
                self.assertTrue(final_stage["excludedEquivalentStrategies"])
            else:
                self.assertTrue(final_stage["name"].startswith("TIER_"))
            self.assertTrue(validate_variant(snapshot, variant).valid)

    def test_full_model_is_built_once_and_cloned_for_all_strategies(self) -> None:
        snapshot = replace(
            self.snapshot,
            settings=replace(self.snapshot.settings, require_optimal=False),
        )
        engine = CpSatScheduleEngine(
            max_total_seconds=120,
            finalization_reserve_seconds=5,
        )
        original_build_model = engine._build_model
        full_model_builds = 0

        def observe_build(*args, **kwargs):
            nonlocal full_model_builds
            if not kwargs.get("coverage_only", False):
                full_model_builds += 1
            return original_build_model(*args, **kwargs)

        with patch.object(engine, "_build_model", side_effect=observe_build):
            variants = engine.solve(snapshot)

        self.assertEqual(len(variants), len(snapshot.strategies))
        self.assertEqual(full_model_builds, 1)

    def test_coverage_aggregation_keeps_distinct_demand_groups(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodEnd"] = "2026-08-01"
        first = {
            **raw["demand"][0],
            "dates": ["2026-08-01"],
            "requiredCount": 1,
        }
        raw["demand"] = [first, {**first, "id": "demand-second"}]
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        artifacts = self.engine._build_model(
            snapshot,
            slots,
            EligibilityIndex(snapshot),
            coverage_only=True,
        )

        self.assertEqual(len({slot.occurrence_id for slot in slots}), 1)
        self.assertEqual(len(artifacts.unfilled), 2)
        self.assertEqual(artifacts.coverage_aggregated_seats, 0)
        artifacts.model.minimize(artifacts.metrics["UNFILLED"])
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1
        status = solver.solve(artifacts.model)
        self.assertEqual(status, cp_model.OPTIMAL)
        self.assertEqual(solver.value(artifacts.metrics["UNFILLED"]), 0)

    def test_weekly_certificate_is_exact_lower_bound_across_rest_boundary(
        self,
    ) -> None:
        snapshot = Snapshot.from_dict(
            decomposed_certificate_snapshot_raw(required_count=2)
        )
        slots = generate_slots(snapshot)
        engine = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        )

        with patch("grafik_solver.cp_sat_engine.MIN_DECOMPOSED_PROOF_SLOTS", 0):
            certificate = engine._coverage_certificate(
                snapshot,
                slots,
                EligibilityIndex(snapshot),
                engine._clock() + 29,
            )

        self.assertIsNotNone(certificate)
        assert certificate is not None
        self.assertEqual(certificate.lower_bound, 3)
        self.assertEqual(len(certificate.blocks), 2)
        self.assertEqual(len(certificate.boundary_partitions), 2)
        self.assertTrue(certificate.all_weeks_optimal)

        artifacts = engine._build_model(
            snapshot,
            slots,
            EligibilityIndex(snapshot),
            coverage_only=True,
        )
        artifacts.model.minimize(artifacts.metrics["UNFILLED"])
        solver = cp_model.CpSolver()
        solver.parameters.num_search_workers = 1
        status = solver.solve(artifacts.model)
        self.assertEqual(status, cp_model.OPTIMAL)
        self.assertEqual(solver.value(artifacts.metrics["UNFILLED"]), 3)
        self.assertLessEqual(
            certificate.lower_bound,
            solver.value(artifacts.metrics["UNFILLED"]),
        )

    def test_solver_records_exact_weekly_certificate(self) -> None:
        snapshot = Snapshot.from_dict(decomposed_certificate_snapshot_raw())
        engine = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        )

        with patch("grafik_solver.cp_sat_engine.MIN_DECOMPOSED_PROOF_SLOTS", 0):
            result = engine.solve(snapshot)[0]

        certificate = result.stage_objectives[0]["certificate"]
        self.assertEqual(certificate["kind"], "BOUNDARY_AWARE_PERIOD_DECOMPOSITION")
        self.assertEqual(certificate["lowerBound"], 1)
        self.assertEqual(len(certificate["blocks"]), 2)
        self.assertEqual(len(certificate["boundaryPartitions"]), 2)
        self.assertTrue(certificate["allWeeksOptimal"])
        self.assertEqual(result.metrics["UNFILLED"], 1)
        self.assertTrue(result.optimal)

    def test_incomplete_period_subproblem_keeps_proven_integer_bound(self) -> None:
        class FeasibleSolver:
            best_objective_bound = 1.2

            @staticmethod
            def status_name(_status):
                return "FEASIBLE"

            @staticmethod
            def value(_expression):
                return 3

        snapshot = Snapshot.from_dict(decomposed_certificate_snapshot_raw())
        slots = generate_slots(snapshot)
        engine = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        )

        with patch.object(
            engine,
            "_solve_model",
            return_value=(FeasibleSolver(), cp_model.FEASIBLE),
        ):
            proof = engine._solve_coverage_subproblem(
                snapshot,
                slots,
                EligibilityIndex(snapshot),
                stage_name="TEST_PERIOD_BOUND",
                time_limit_seconds=1,
            )

        self.assertEqual(proof.status, "FEASIBLE")
        self.assertFalse(proof.optimal)
        self.assertEqual(proof.incumbent, 3)
        self.assertEqual(proof.lower_bound, 2)

    def test_coverage_symmetry_skips_groups_with_locked_seats(self) -> None:
        raw = load_raw()
        raw.pop("slots")
        raw["periodEnd"] = "2026-08-01"
        raw["demand"] = [
            {
                **raw["demand"][0],
                "dates": ["2026-08-01"],
                "requiredCount": 2,
            }
        ]
        raw["payRules"] = []
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["lockedAssignments"] = [
            {
                "slotId": (
                    "2026-08-01|shift-morning|role-sommelier|"
                    "duty-service|demand-morning|2"
                ),
                "employeeId": "employee-alice",
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        slots = generate_slots(snapshot)
        artifacts = self.engine._build_model(
            snapshot,
            slots,
            EligibilityIndex(snapshot),
            coverage_only=True,
        )

        self.assertEqual(artifacts.coverage_symmetry_constraints, 0)

    def test_objective_target_and_tolerance_are_applied_and_reported(self) -> None:
        raw = load_raw()
        raw["strategies"] = [
            {
                "id": "strategy-target",
                "code": "TARGET",
                "label": "Target",
                "sortOrder": 0,
                "timeLimitSeconds": 30,
                "objectiveTerms": [
                    {
                        "tier": 1,
                        "metric": "TOTAL_COST",
                        "weight": 2,
                        "direction": "MIN",
                        "tolerance": 125,
                        "parameters": {"targetValue": 0},
                    }
                ],
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        variant = self.engine.solve(snapshot)[0]
        stage = next(
            item
            for item in variant.stage_objectives
            if any(
                term.get("metric") == "TOTAL_COST"
                for term in item.get("terms", [])
            )
        )
        coefficient = stage["terms"][0]["normalizationCoefficient"]
        self.assertEqual(stage["tolerance"], coefficient * 125)
        self.assertEqual(
            stage["frozenUpperBound"],
            stage["value"] + coefficient * 125,
        )
        self.assertEqual(stage["terms"][0]["parameters"], {"targetValue": 0})
        self.assertEqual(stage["terms"][0]["tolerance"], 125)
        self.assertGreater(coefficient, 0)
        self.assertTrue(validate_variant(snapshot, variant).valid)

    def test_zero_weight_objective_is_accepted_and_omitted(self) -> None:
        raw = load_raw()
        raw["strategies"] = [
            {
                "id": "strategy-disabled-cost",
                "code": "DISABLED_COST",
                "label": "Disabled cost",
                "sortOrder": 0,
                "timeLimitSeconds": 30,
                "objectiveTerms": [
                    {
                        "tier": 7,
                        "metric": "TOTAL_COST",
                        "weight": 0,
                        "direction": "MIN",
                        "tolerance": 125,
                        "parameters": {"targetValue": 0},
                    }
                ],
            }
        ]
        snapshot = Snapshot.from_dict(raw)
        self.assertEqual(snapshot.strategies[0].objective_terms[0].weight, 0)
        variant = self.engine.solve(snapshot)[0]
        self.assertEqual(variant.stage_objectives[0]["tier"], 0)
        self.assertTrue(
            any(
                term.get("metric") == "COMMON_FAIRNESS_GUARD_SCORE"
                for stage in variant.stage_objectives[1:]
                for term in stage.get("terms", [])
            )
        )
        self.assertTrue(validate_variant(snapshot, variant).valid)

    def test_strategies_can_produce_independent_solutions(self) -> None:
        by_strategy = {variant.strategy_id: variant for variant in self.variants}
        self.assertNotEqual(
            by_strategy["strategy-cost"].solution_hash,
            by_strategy["strategy-preference"].solution_hash,
        )
        self.assertLessEqual(
            by_strategy["strategy-cost"].metrics["TOTAL_COST"],
            by_strategy["strategy-preference"].metrics["TOTAL_COST"],
        )
        self.assertLessEqual(
            by_strategy["strategy-preference"].metrics["PREFERENCE_VIOLATIONS"],
            by_strategy["strategy-cost"].metrics["PREFERENCE_VIOLATIONS"],
        )

    def test_cost_strategy_uses_available_nominal_capacity_before_overtime(self) -> None:
        raw = load_raw()
        raw.pop("slots", None)
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        raw["availabilityWindows"] = []
        raw["demand"] = [copy.deepcopy(raw["demand"][0])]
        raw["strategies"] = [copy.deepcopy(raw["strategies"][0])]
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["payRules"] = [
            {
                "id": "overtime-by-employee-nominal",
                "calculationType": "MONTHLY_THRESHOLD_PER_HOUR",
                "values": {
                    "thresholdSource": "EMPLOYEE_NOMINAL",
                    "thresholdMinutes": 0,
                    "rateMinorPerHour": 1,
                },
                "conditions": [],
                "stackingGroup": "overtime",
                "stackingMode": "STACK",
                "priority": 0,
                "active": True,
            }
        ]
        cheap = copy.deepcopy(raw["employees"][2])
        cheap.update(
            {
                "id": "employee-cheap-overtime",
                "baseHourlyRateMinor": 100,
                "nominalMonthlyMinutes": 240,
                "maximumMonthlyMinutes": 480,
                "maximumWeeklyMinutes": 480,
                "overtimePolicy": "ALLOWED",
            }
        )
        expensive = copy.deepcopy(cheap)
        expensive.update(
            {
                "id": "employee-expensive-nominal",
                "baseHourlyRateMinor": 1000,
                "maximumMonthlyMinutes": 240,
                "maximumWeeklyMinutes": 240,
                "overtimePolicy": "NEVER",
            }
        )
        raw["employees"] = [cheap, expensive]

        snapshot = Snapshot.from_dict(raw)
        variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)[0]

        self.assertEqual(variant.metrics["UNFILLED"], 0)
        self.assertEqual(variant.metrics["OVERTIME_MINUTES"], 0)
        self.assertEqual(
            {assignment.employee_id for assignment in variant.assignments},
            {"employee-cheap-overtime", "employee-expensive-nominal"},
        )
        self.assertEqual(variant.stage_objectives[0]["overtimeMinimum"], 0)

    def test_overtime_is_used_only_when_needed_for_best_coverage(self) -> None:
        raw = load_raw()
        raw.pop("slots", None)
        raw["settings"]["missingAvailabilityMeansAvailable"] = True
        raw["settings"]["requireOptimal"] = True
        raw["availabilityWindows"] = []
        raw["demand"] = [copy.deepcopy(raw["demand"][0])]
        raw["strategies"] = [copy.deepcopy(raw["strategies"][0])]
        raw["budget"] = {"amountMinor": None, "hard": False}
        raw["payRules"] = [
            {
                "id": "overtime-by-employee-nominal",
                "calculationType": "MONTHLY_THRESHOLD_PER_HOUR",
                "values": {
                    "thresholdSource": "EMPLOYEE_NOMINAL",
                    "thresholdMinutes": 0,
                    "rateMinorPerHour": 5000,
                },
                "conditions": [],
                "stackingGroup": "overtime",
                "stackingMode": "STACK",
                "priority": 0,
                "active": True,
            }
        ]
        employee = copy.deepcopy(raw["employees"][2])
        employee.update(
            {
                "id": "employee-only-available",
                "nominalMonthlyMinutes": 240,
                "maximumMonthlyMinutes": 480,
                "maximumWeeklyMinutes": 480,
                "overtimePolicy": "ALLOWED",
            }
        )
        raw["employees"] = [employee]

        snapshot = Snapshot.from_dict(raw)
        variant = CpSatScheduleEngine(
            max_total_seconds=30, finalization_reserve_seconds=1
        ).solve(snapshot)[0]

        self.assertEqual(variant.metrics["UNFILLED"], 0)
        self.assertEqual(variant.metrics["OVERTIME_MINUTES"], 240)
        self.assertEqual(variant.stage_objectives[0]["overtimeMinimum"], 240)
        self.assertEqual(len(variant.assignments), 2)

    def test_avoided_shift_period_is_counted_as_a_soft_preference(self) -> None:
        raw = load_raw()
        for employee in raw["employees"]:
            employee["avoidedShiftTemplateIds"] = ["shift-morning"]
        variants = self.engine.solve(Snapshot.from_dict(raw))
        baseline = {
            variant.strategy_id: variant.metrics["PREFERENCE_VIOLATIONS"]
            for variant in self.variants
        }
        for variant in variants:
            self.assertEqual(
                variant.metrics["PREFERENCE_VIOLATIONS"],
                baseline[variant.strategy_id] + 2,
            )

    def test_home_location_marker_is_not_an_objective_anymore(self) -> None:
        for variant in self.variants:
            self.assertEqual(variant.metrics["HOME_LOCATION_VIOLATIONS"], 0)

    def test_unknown_or_conflicting_period_template_ids_are_rejected(self) -> None:
        unknown = load_raw()
        unknown["employees"][0]["blockedShiftTemplateIds"] = ["missing-shift"]
        with self.assertRaisesRegex(SnapshotError, "missing templates"):
            self.engine.solve(Snapshot.from_dict(unknown))

        conflicting = load_raw()
        conflicting["employees"][0]["preferredShiftTemplateIds"] = ["shift-morning"]
        conflicting["employees"][0]["blockedShiftTemplateIds"] = ["shift-morning"]
        with self.assertRaisesRegex(SnapshotError, "prefer and block"):
            self.engine.solve(Snapshot.from_dict(conflicting))

    def test_independent_validator_rejects_rest_violation(self) -> None:
        variant = self.variants[0]
        slots = {slot.id: slot for slot in generate_slots(self.snapshot)}
        assignments = list(variant.assignments)
        evening = next(
            item
            for item in assignments
            if slots[item.slot_id].date.isoformat() == "2026-08-01"
            and slots[item.slot_id].shift_template_id == "shift-evening"
        )
        morning_index = next(
            index
            for index, item in enumerate(assignments)
            if slots[item.slot_id].date.isoformat() == "2026-08-01"
            and slots[item.slot_id].shift_template_id == "shift-morning"
        )
        assignments[morning_index] = Assignment(
            slot_id=assignments[morning_index].slot_id,
            employee_id=evening.employee_id,
            cost_units=assignments[morning_index].cost_units,
            cost_components=assignments[morning_index].cost_components,
        )
        invalid = replace(variant, assignments=tuple(assignments))
        report = validate_variant(self.snapshot, invalid)
        self.assertFalse(report.valid)
        self.assertTrue(
            any(
                error.startswith(("OVERLAP_OR_REST:", "DAILY_SHIFT_LIMIT:"))
                for error in report.errors
            )
        )

    def test_worker_lifecycle_claims_validates_saves_and_finalizes(self) -> None:
        rpc = _FakeRpc(self.raw)
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(
            config,
            rpc=rpc,
            engine=_FakeEngine(self.variants),
        )
        self.assertEqual(runtime.run(), 0)
        self.assertEqual(len(rpc.saved), 2)
        self.assertTrue(rpc.finalized)
        self.assertFalse(rpc.failed)
        self.assertEqual(rpc.claim_requests[0]["worker_id"], "test-worker")
        self.assertEqual(
            rpc.claim_requests[0]["worker_version"], "ORTOOLS_V2_2026_08_02"
        )

    def test_worker_treats_structured_finalization_failure_as_failed_run(self) -> None:
        rpc = _FakeRpc(self.raw)
        rpc.finalization_value = {
            "status": "FAILED",
            "errorCode": "RUN_VARIANTS_INCOMPLETE",
            "readyVariantCount": 2,
            "expectedVariantCount": 3,
        }
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(config, rpc=rpc, engine=_FakeEngine(self.variants))

        with self.assertLogs("grafik_solver.lifecycle", level="ERROR") as logs:
            self.assertEqual(runtime.run_once(), 1)

        self.assertTrue(rpc.finalized)
        self.assertFalse(rpc.failed)
        self.assertIn("RUN_VARIANTS_INCOMPLETE", "\n".join(logs.output))

    def test_worker_heartbeat_filters_engine_only_diagnostics(self) -> None:
        rpc = _FakeRpc(self.raw)
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(config, rpc=rpc, engine=_FakeEngine(self.variants))

        runtime._solver_progress(
            {
                "phase": "SOLVING",
                "progress": 10,
                "strategyCount": 2,
                "slotCount": 1362,
                "eligibleDecisionPairs": 21048,
                "coverageSymmetryConstraints": 798,
                "solverStatus": "OPTIMAL",
                "solverBestBound": None,
            }
        )

        self.assertEqual(
            runtime._progress_snapshot(),
            {
                "schemaVersion": 2,
                "phase": "SOLVING",
                "progress": 10,
                "strategyCount": 2,
            },
        )

    def test_solver_stage_boundary_renews_starved_heartbeat(self) -> None:
        rpc = _FakeRpc(self.raw)
        clock_values = iter((100.0, 161.0, 161.0))
        engine = _StageBoundaryEngine(self.variants)
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(
            config,
            rpc=rpc,
            engine=engine,
            clock=lambda: next(clock_values),
        )

        self.assertEqual(runtime.run_once(), 0)
        self.assertEqual(rpc.heartbeat_calls, 1)
        self.assertTrue(rpc.finalized)

    def test_solver_stage_boundary_stops_after_lease_loss(self) -> None:
        rpc = _FakeRpc(self.raw)
        rpc.heartbeat_value = Heartbeat(cancel_requested=False, lease_valid=False)
        clock_values = iter((100.0, 161.0, 161.0))
        engine = _StageBoundaryEngine(self.variants)
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(
            config,
            rpc=rpc,
            engine=engine,
            clock=lambda: next(clock_values),
        )

        self.assertEqual(runtime.run_once(), 1)
        self.assertEqual(rpc.heartbeat_calls, 1)
        self.assertFalse(rpc.finalized)
        self.assertEqual(rpc.interrupt_reason, None)

    def test_retryable_heartbeat_response_error_does_not_stop_run(self) -> None:
        rpc = _FakeRpc(self.raw)
        rpc.heartbeat_errors = [
            RpcError(
                "Gateway action solver_heartbeat_v2 returned invalid JSON",
                retryable=True,
            )
        ]
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="test-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(config, rpc=rpc, engine=_FakeEngine(self.variants))

        with self.assertLogs("grafik_solver.lifecycle", level="WARNING") as logs:
            self.assertTrue(runtime._heartbeat_once(rpc.claim_value, force=True))

        self.assertFalse(runtime._stop.event.is_set())
        self.assertEqual(runtime._heartbeat_failures, 1)
        self.assertIn("status=None; retryable=True", "\n".join(logs.output))
        self.assertIn("returned invalid JSON", "\n".join(logs.output))

    def test_pull_worker_claims_the_next_queued_run(self) -> None:
        rpc = _FakeRpc(self.raw)
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="free-host-worker-test",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=1,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(
            config,
            rpc=rpc,
            engine=_FakeEngine(self.variants),
        )
        self.assertEqual(runtime.run_once(), 0)
        self.assertEqual(len(rpc.claim_requests), 1)
        self.assertEqual(rpc.claim_requests[0]["worker_id"], "free-host-worker-test")
        self.assertNotIn("run_id", rpc.claim_requests[0])
        self.assertNotIn("dispatch_token", rpc.claim_requests[0])
        self.assertTrue(rpc.finalized)

    def test_pull_worker_processes_multiple_runs_without_dispatcher(self) -> None:
        rpc = _FakeRpc(self.raw)
        rpc.claim_values = [rpc.claim_value, rpc.claim_value]
        config = WorkerConfig(
            solver_gateway_url=(
                "https://example.supabase.co/functions/v1/solver-gateway"
            ),
            solver_gateway_token="g" * 64,
            solver_version="ORTOOLS_V2_2026_08_02",
            worker_id="long-lived-worker",
            task_attempt=1,
            poll_interval_seconds=1,
            max_runs=2,
            idle_exit_seconds=0,
            rpc_timeout_seconds=1,
            heartbeat_seconds=60,
            lease_seconds=90,
            solver_max_seconds=30,
        )
        runtime = WorkerRuntime(
            config,
            rpc=rpc,
            engine=_FakeEngine(self.variants),
        )
        self.assertEqual(runtime.run(), 0)
        self.assertEqual(len(rpc.claim_requests), 2)
        self.assertEqual(len(rpc.saved), 4)

    def test_external_boundary_counts_weekly_but_not_monthly_or_outside_daily(
        self,
    ) -> None:
        raw = boundary_snapshot_raw(
            [
                {
                    "employeeId": "employee-alice",
                    "start": "2026-07-20T00:00:00+02:00",
                    "end": "2026-07-20T20:00:00+02:00",
                },
                {
                    "employeeId": "employee-alice",
                    "start": "2026-07-31T06:00:00+02:00",
                    "end": "2026-07-31T10:00:00+02:00",
                },
                {
                    "employeeId": "employee-alice",
                    "start": "2026-07-31T11:00:00+02:00",
                    "end": "2026-07-31T15:00:00+02:00",
                },
            ],
            maximum_weekly_minutes=720,
            maximum_consecutive_days=3,
        )
        snapshot = Snapshot.from_dict(raw)
        variant = self.engine.solve(snapshot)[0]
        report = validate_variant(snapshot, variant)
        self.assertTrue(report.valid, report.errors)
        self.assertEqual(report.assignment_count, 1)
        self.assertEqual(variant.metrics["NOMINAL_DEVIATION_MINUTES"], 0)

        weekly_employee = replace(snapshot.employees[0], maximum_weekly_minutes=719)
        weekly_snapshot = replace(snapshot, employees=(weekly_employee,))
        weekly_report = validate_variant(weekly_snapshot, variant)
        self.assertTrue(
            any(
                error.startswith("WEEKLY_MINUTE_LIMIT:")
                for error in weekly_report.errors
            )
        )
        with self.assertRaises(OptimizationError):
            self.engine.solve(weekly_snapshot)

    def test_external_boundary_extends_consecutive_days(self) -> None:
        raw = boundary_snapshot_raw(
            [
                {
                    "employeeId": "employee-alice",
                    "start": "2026-07-30T08:00:00+02:00",
                    "end": "2026-07-30T12:00:00+02:00",
                },
                {
                    "employeeId": "employee-alice",
                    "start": "2026-07-31T08:00:00+02:00",
                    "end": "2026-07-31T12:00:00+02:00",
                },
            ],
            maximum_weekly_minutes=2000,
            maximum_consecutive_days=2,
        )
        snapshot = Snapshot.from_dict(raw)
        with self.assertRaises(OptimizationError):
            self.engine.solve(snapshot)

        allowed_employee = replace(snapshot.employees[0], maximum_consecutive_days=3)
        allowed_snapshot = replace(snapshot, employees=(allowed_employee,))
        variant = self.engine.solve(allowed_snapshot)[0]
        strict_report = validate_variant(snapshot, variant)
        self.assertTrue(
            any(
                error.startswith("CONSECUTIVE_DAY_LIMIT:")
                for error in strict_report.errors
            )
        )

    def test_external_boundary_still_blocks_rest(self) -> None:
        base_snapshot = Snapshot.from_dict(
            boundary_snapshot_raw(
                [], maximum_weekly_minutes=2000, maximum_consecutive_days=3
            )
        )
        variant = self.engine.solve(base_snapshot)[0]
        conflicting_snapshot = Snapshot.from_dict(
            boundary_snapshot_raw(
                [
                    {
                        "employeeId": "employee-alice",
                        "start": "2026-07-31T23:00:00+02:00",
                        "end": "2026-08-01T04:00:00+02:00",
                    }
                ],
                maximum_weekly_minutes=2000,
                maximum_consecutive_days=3,
            )
        )
        report = validate_variant(conflicting_snapshot, variant)
        self.assertTrue(
            any(
                "EXTERNAL_ASSIGNMENT_CONFLICT_OR_REST" in error
                for error in report.errors
            )
        )
        with self.assertRaises(SnapshotError):
            self.engine.solve(conflicting_snapshot)

    def test_global_budget_does_not_reset_between_strategies(self) -> None:
        raw = load_raw()
        strategy_template = raw["strategies"][0]
        raw["strategies"] = [
            {
                **strategy_template,
                "id": f"strategy-global-budget-{index}",
                "code": f"GLOBAL_BUDGET_{index}",
                "label": f"Global budget {index}",
                "sortOrder": index,
                "timeLimitSeconds": 100,
            }
            for index in range(4)
        ]
        snapshot = Snapshot.from_dict(raw)
        fake_clock = _FakeClock()
        completed = []
        engine = CpSatScheduleEngine(
            max_total_seconds=10,
            finalization_reserve_seconds=2,
            result_callback=completed.append,
            clock=fake_clock,
        )
        original_solve_model = engine._solve_model
        observed_limits: list[float] = []

        def consume_budget(*args, **kwargs):
            observed_limits.append(kwargs["time_limit_seconds"])
            # Coverage, the mandatory overtime gate and the configured
            # strategy tier all consume the same global budget.
            fake_clock.advance(2.5)
            return original_solve_model(*args, **kwargs)

        with (
            patch.object(engine, "_solve_model", side_effect=consume_budget),
            self.assertRaises(OptimizationIncomplete),
        ):
            engine.solve(snapshot)

        self.assertLessEqual(len(completed), 1)
        self.assertEqual(len(observed_limits), 4)
        self.assertEqual(observed_limits, [8.0, 5.5, 3.0, 0.5])
        self.assertTrue(snapshot.settings.require_optimal)

    def test_solver_status_is_reported_before_wall_clock_overrun(self) -> None:
        class FeasibleSolver:
            objective_value = 1.0
            best_objective_bound = 0.0
            wall_time = 8.1
            num_branches = 10
            num_conflicts = 2

            @staticmethod
            def status_name(_status):
                return "FEASIBLE"

            @staticmethod
            def value(_expression):
                return 1

        fake_clock = _FakeClock()
        engine = CpSatScheduleEngine(
            max_total_seconds=10,
            finalization_reserve_seconds=2,
            clock=fake_clock,
        )

        def overrun(*_args, **_kwargs):
            fake_clock.advance(9)
            return FeasibleSolver(), cp_model.FEASIBLE

        with (
            patch.object(engine, "_solve_model", side_effect=overrun),
            self.assertRaisesRegex(
                OptimizationIncomplete,
                r"UNFILLED ended incomplete; status=FEASIBLE",
            ),
        ):
            engine.solve(self.snapshot)

    def test_proof_budget_exhaustion_is_not_retried_unchanged(self) -> None:
        self.assertEqual(
            WorkerRuntime._classify_failure(OptimizationIncomplete("budget")),
            (False, "OPTIMIZATION_INCOMPLETE"),
        )

    def test_scoped_budgets_allocate_monthly_threshold_to_exact_assignment(
        self,
    ) -> None:
        raw = scoped_budget_snapshot_raw()
        snapshot = Snapshot.from_dict(raw)
        variant = self.engine.solve(snapshot)[0]
        report = validate_variant(snapshot, variant)
        self.assertTrue(report.valid, report.errors)
        self.assertEqual(variant.metrics["TOTAL_COST"], 24000)

        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        assignment_costs = {
            slots[assignment.slot_id].location_id: assignment.cost_units
            for assignment in variant.assignments
        }
        self.assertEqual(assignment_costs, {"location-a": 0, "location-b": 24000})

        budgets = {result.budget_id: result for result in report.budget_results}
        self.assertEqual(budgets["budget-global"].spent_units, 24000)
        self.assertEqual(budgets["budget-location-a"].spent_units, 0)
        for budget_id in (
            "budget-location-b",
            "budget-role-b",
            "budget-duty-b",
            "budget-combined-b",
        ):
            self.assertEqual(budgets[budget_id].spent_units, 24000)
            self.assertFalse(budgets[budget_id].exceeded)
        self.assertEqual(budgets["budget-role-b"].scope, {"roleId": "role-b"})
        self.assertEqual(
            budgets["budget-combined-b"].scope,
            {
                "locationId": "location-b",
                "roleId": "role-b",
                "dutyId": "duty-b",
            },
        )

        for strict_budget_id in (
            "budget-global",
            "budget-location-b",
            "budget-role-b",
            "budget-duty-b",
            "budget-combined-b",
        ):
            with self.subTest(budget=strict_budget_id):
                strict_raw = copy.deepcopy(raw)
                next(
                    budget
                    for budget in strict_raw["budgets"]
                    if budget["id"] == strict_budget_id
                )["amountMinor"] = 399
                strict_snapshot = Snapshot.from_dict(strict_raw)
                with self.assertRaises(OptimizationError):
                    self.engine.solve(strict_snapshot)
                strict_report = validate_variant(strict_snapshot, variant)
                self.assertTrue(
                    any(
                        error.startswith(f"HARD_BUDGET:{strict_budget_id}:")
                        for error in strict_report.errors
                    ),
                    strict_report.errors,
                )

    def test_employee_duty_capability_is_limited_by_role_and_location(self) -> None:
        raw = scoped_budget_snapshot_raw()
        snapshot = Snapshot.from_dict(raw)
        employee = snapshot.employees[0]
        duty_b_slot = next(
            slot for slot in generate_slots(snapshot) if slot.duty_ids == ("duty-b",)
        )
        self.assertTrue(
            EligibilityIndex(snapshot).evaluate(employee, duty_b_slot).allowed
        )

        wrong_scope_raw = copy.deepcopy(raw)
        wrong_scope_raw["employees"][0]["dutyGrants"][1]["roleId"] = "role-a"
        wrong_scope = Snapshot.from_dict(wrong_scope_raw)
        result = EligibilityIndex(wrong_scope).evaluate(
            wrong_scope.employees[0], generate_slots(wrong_scope)[1]
        )
        self.assertFalse(result.allowed)
        self.assertIn("DUTIES", result.reasons)
        with self.assertRaises(SnapshotError):
            self.engine.solve(wrong_scope)

        expired_role_raw = copy.deepcopy(raw)
        expired_role_raw["employees"][0]["roleGrants"][1]["validTo"] = "2026-08-01"
        expired_role = Snapshot.from_dict(expired_role_raw)
        expired_result = EligibilityIndex(expired_role).evaluate(
            expired_role.employees[0], generate_slots(expired_role)[1]
        )
        self.assertIn("ROLE", expired_result.reasons)
        with self.assertRaises(SnapshotError):
            self.engine.solve(expired_role)

        for grants_field, reason in (
            ("dutyGrants", "DUTIES"),
            ("locationGrants", "LOCATION"),
        ):
            with self.subTest(grants=grants_field):
                future_grant_raw = copy.deepcopy(raw)
                future_grant_raw["employees"][0][grants_field][1]["validFrom"] = (
                    "2026-08-03"
                )
                future_grant = Snapshot.from_dict(future_grant_raw)
                future_result = EligibilityIndex(future_grant).evaluate(
                    future_grant.employees[0], generate_slots(future_grant)[1]
                )
                self.assertIn(reason, future_result.reasons)

        invalid_period_raw = copy.deepcopy(raw)
        invalid_period_raw["employees"][0]["dutyGrants"][0].update(
            {"validFrom": "2026-08-02", "validTo": "2026-08-01"}
        )
        with self.assertRaisesRegex(SnapshotError, "cannot precede"):
            Snapshot.from_dict(invalid_period_raw)

        split_period_raw = copy.deepcopy(raw)
        split_period_raw["employees"][0]["roleGrants"][1]["validTo"] = "2026-07-31"
        split_period_raw["employees"][0]["roleGrants"].append(
            {"roleId": "role-b", "validFrom": "2026-08-02"}
        )
        split_period = Snapshot.from_dict(split_period_raw)
        split_result = EligibilityIndex(split_period).evaluate(
            split_period.employees[0], generate_slots(split_period)[1]
        )
        self.assertTrue(split_result.allowed, split_result.reasons)

        overtime_only_raw = copy.deepcopy(raw)
        overtime_grant = overtime_only_raw["employees"][0]["locationGrants"][1]
        overtime_grant["standardAllowed"] = False
        overtime_grant["overtimeAllowed"] = True
        overtime_only = Snapshot.from_dict(overtime_only_raw)
        overtime_result = EligibilityIndex(overtime_only).evaluate(
            overtime_only.employees[0], generate_slots(overtime_only)[1]
        )
        self.assertIn("LOCATION", overtime_result.reasons)
        with self.assertRaises(SnapshotError):
            self.engine.solve(overtime_only)

    def test_pay_rate_period_changes_rate_and_contract_mid_period(self) -> None:
        raw = scoped_budget_snapshot_raw()
        employee = raw["employees"][0]
        employee["baseHourlyRateMinor"] = 9999
        employee["contractCode"] = "LEGACY"
        employee["payRatePeriods"] = [
            {
                "validFrom": "2026-08-01",
                "validTo": "2026-08-01",
                "baseRateMinor": 1000,
                "contractCode": "FIRST",
            },
            {
                "validFrom": "2026-08-02",
                "baseRateMinor": 2000,
                "contractCode": "SECOND",
            },
        ]
        raw["payRules"] = [
            {
                "id": "second-contract-bonus",
                "calculationType": "FIXED_PER_SHIFT",
                "values": {"amountMinor": 100},
                "conditions": [
                    {
                        "field": "contract_code",
                        "operator": "EQ",
                        "value": "SECOND",
                    }
                ],
                "stackingGroup": "second-contract",
                "stackingMode": "STACK",
                "priority": 0,
                "active": True,
            }
        ]
        raw["budgets"] = []
        snapshot = Snapshot.from_dict(raw)
        variant = self.engine.solve(snapshot)[0]
        slots = {slot.id: slot for slot in generate_slots(snapshot)}
        costs = {
            slots[assignment.slot_id].date.isoformat(): assignment.cost_units
            for assignment in variant.assignments
        }
        self.assertEqual(costs["2026-08-01"], 1000 * 240)
        self.assertEqual(costs["2026-08-02"], 2000 * 240 + 100 * 60)
        self.assertTrue(validate_variant(snapshot, variant).valid)

        overlap_raw = copy.deepcopy(raw)
        overlap_raw["employees"][0]["payRatePeriods"][0]["validTo"] = "2026-08-02"
        with self.assertRaisesRegex(SnapshotError, "cannot overlap"):
            Snapshot.from_dict(overlap_raw)


class _FakeEngine:
    def __init__(self, variants):
        self.variants = variants

    def solve(self, _snapshot):
        return self.variants

    def stop(self):
        return None


class _StageBoundaryEngine(_FakeEngine):
    def __init__(self, variants):
        super().__init__(variants)
        self.progress_callback = None

    def set_progress_callback(self, callback):
        self.progress_callback = callback

    def solve(self, _snapshot):
        assert self.progress_callback is not None
        self.progress_callback(
            {
                "solverStage": "UNFILLED",
                "solverStatus": "OPTIMAL",
            }
        )
        return self.variants


class _FakeRpc:
    def __init__(self, raw):
        self.raw = copy.deepcopy(raw)
        self.claim_value = Claim("run-fixture-001", "attempt-1", "lease-1")
        self.claim_values = [self.claim_value]
        self.saved = []
        self.finalized = False
        self.failed = False
        self.claim_requests = []
        self.heartbeat_calls = 0
        self.heartbeat_value = Heartbeat(cancel_requested=False, lease_valid=True)
        self.heartbeat_errors = []
        self.interrupt_reason = None
        self.finalization_value = None

    def claim(self, **kwargs):
        self.claim_requests.append(kwargs)
        return self.claim_values.pop(0) if self.claim_values else None

    def load_snapshot(self, _claim):
        return SnapshotEnvelope(
            self.raw, sha256_hex(self.raw, exclude_snapshot_hash=True)
        )

    def heartbeat(self, _claim, _progress):
        self.heartbeat_calls += 1
        if self.heartbeat_errors:
            raise self.heartbeat_errors.pop(0)
        return self.heartbeat_value

    def save_variant(self, _claim, variant):
        self.saved.append(variant)

    def finalize(self, _claim):
        self.finalized = True
        return self.finalization_value

    def interrupt(self, _claim, _reason):
        self.interrupt_reason = _reason
        return None

    def fail_attempt(self, _claim, **_kwargs):
        self.failed = True


if __name__ == "__main__":
    unittest.main()
