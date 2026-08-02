from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.cp_sat_engine import (  # noqa: E402
    SAFE_CP_SAT_INTEGER,
    CpSatScheduleEngine,
)
from grafik_solver.models import Snapshot, SnapshotError  # noqa: E402
from grafik_solver.slots import generate_slots  # noqa: E402

FIXTURE_PATH = ROOT / "tests" / "fixtures" / "small_snapshot.json"


def load_raw() -> dict:
    return json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))


class CapacityGuardrailTests(unittest.TestCase):
    def test_snapshot_dimensions_are_bounded_before_model_construction(self) -> None:
        snapshot = Snapshot.from_dict(load_raw())
        slots = generate_slots(snapshot)

        with (
            patch("grafik_solver.cp_sat_engine.MAX_SOLVER_SLOTS", len(slots) - 1),
            self.assertRaisesRegex(SnapshotError, "slot capacity"),
        ):
            CpSatScheduleEngine._validate_capacity(snapshot, slots)

        with (
            patch(
                "grafik_solver.cp_sat_engine.MAX_SOLVER_EMPLOYEES",
                len(snapshot.employees) - 1,
            ),
            self.assertRaisesRegex(SnapshotError, "employee capacity"),
        ):
            CpSatScheduleEngine._validate_capacity(snapshot, slots)

        with (
            patch(
                "grafik_solver.cp_sat_engine.MAX_SOLVER_STRATEGIES",
                len(snapshot.strategies) - 1,
            ),
            self.assertRaisesRegex(SnapshotError, "strategy capacity"),
        ):
            CpSatScheduleEngine._validate_capacity(snapshot, slots)

        with (
            patch("grafik_solver.cp_sat_engine.MAX_SOLVER_DECISION_PAIRS", 1),
            self.assertRaisesRegex(SnapshotError, "decision-variable capacity"),
        ):
            CpSatScheduleEngine._validate_capacity(snapshot, slots)

    def test_objective_coefficients_cannot_overflow_cp_sat(self) -> None:
        raw = load_raw()
        raw["strategies"] = [raw["strategies"][0]]
        raw["strategies"][0]["objectiveTerms"] = [
            {
                "tier": 1,
                "metric": "UNFILLED",
                "weight": SAFE_CP_SAT_INTEGER,
                "direction": "MIN",
            }
        ]

        with self.assertRaisesRegex(SnapshotError, "safe CP-SAT integer range"):
            CpSatScheduleEngine().solve(Snapshot.from_dict(raw))

    def test_cost_coefficients_cannot_overflow_cp_sat(self) -> None:
        raw = load_raw()
        raw["strategies"] = [raw["strategies"][0]]
        raw["employees"] = [
            {**employee, "baseHourlyRateMinor": SAFE_CP_SAT_INTEGER}
            for employee in raw["employees"]
        ]

        with self.assertRaisesRegex(SnapshotError, "Cost model exceeds"):
            CpSatScheduleEngine().solve(Snapshot.from_dict(raw))


if __name__ == "__main__":
    unittest.main()
