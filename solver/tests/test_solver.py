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
from grafik_solver.rpc import Claim, Heartbeat, RpcError, SnapshotEnvelope
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

    def test_shift_period_and_employee_period_rules_are_parsed(self) -> Non…15484 tokens truncated…,
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
            fake_clock.advance(3)
            return original_solve_model(*args, **kwargs)

        with (
            patch.object(engine, "_solve_model", side_effect=consume_budget),
            self.assertRaises(OptimizationIncomplete),
        ):
            engine.solve(snapshot)

        self.assertEqual(len(completed), 1)
        self.assertEqual(len(observed_limits), 3)
        self.assertEqual(observed_limits, [8.0, 5.0, 2.0])
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

