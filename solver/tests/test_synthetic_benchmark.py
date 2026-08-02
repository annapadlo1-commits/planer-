from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(ROOT / "src"))

from benchmarks.synthetic_full import (
    EMPLOYEE_COUNT,
    SLOT_COUNT,
    STRATEGY_COUNT,
    generate_synthetic_snapshot,
)
from grafik_solver.models import Snapshot
from grafik_solver.slots import generate_slots


class SyntheticBenchmarkGeneratorTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.raw = generate_synthetic_snapshot()
        cls.snapshot = Snapshot.from_dict(cls.raw)
        cls.slots = generate_slots(cls.snapshot)

    def test_full_scale_shape_is_stable(self) -> None:
        self.assertEqual(len(self.snapshot.employees), EMPLOYEE_COUNT)
        self.assertEqual(len(self.slots), SLOT_COUNT)
        self.assertEqual(len(self.snapshot.strategies), STRATEGY_COUNT)
        self.assertGreater(len(self.snapshot.roles), 1)
        self.assertGreater(len(self.snapshot.locations), 1)
        self.assertGreater(len(self.snapshot.duties), 1)
        self.assertEqual(self.snapshot.currency, "PLN")
        self.assertEqual(len(self.snapshot.budgets), 4)
        self.assertTrue(any(budget.location_id for budget in self.snapshot.budgets))
        self.assertTrue(any(budget.role_id for budget in self.snapshot.budgets))
        self.assertTrue(any(budget.duty_id for budget in self.snapshot.budgets))
        self.assertTrue(
            all(employee.duty_capabilities for employee in self.snapshot.employees)
        )
        self.assertTrue(
            all(employee.role_grants for employee in self.snapshot.employees)
        )
        self.assertTrue(
            all(employee.location_grants for employee in self.snapshot.employees)
        )
        self.assertTrue(
            all(employee.pay_rate_periods for employee in self.snapshot.employees)
        )
        self.assertTrue(
            all(
                capability.role_id and capability.location_id
                for employee in self.snapshot.employees
                for capability in employee.duty_capabilities or ()
            )
        )

    def test_fixture_exercises_multiple_windows_and_dynamic_pay(self) -> None:
        windows_per_employee: dict[str, int] = {}
        for window in self.snapshot.availability_windows:
            windows_per_employee[window.employee_id] = (
                windows_per_employee.get(window.employee_id, 0) + 1
            )
        self.assertEqual(len(windows_per_employee), EMPLOYEE_COUNT)
        self.assertTrue(all(count > 31 for count in windows_per_employee.values()))
        self.assertEqual(len(self.snapshot.pay_rules), 3)
        self.assertTrue(any(rule.conditions for rule in self.snapshot.pay_rules))


if __name__ == "__main__":
    unittest.main()
