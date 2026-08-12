from __future__ import annotations

import copy
import json
import sys
import unittest
from datetime import date
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.models import Employee, SnapshotError


class RoleSemanticsTests(unittest.TestCase):
    def employee_for(self, assignment_mode: str, priority: int) -> Employee:
        raw = json.loads((ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(encoding="utf-8"))["employees"][0]
        raw = copy.deepcopy(raw)
        role_id = raw["roleIds"][0]
        raw["roleGrants"] = [{
            "roleId": role_id,
            "assignmentMode": assignment_mode,
            "backupPriority": priority,
        }]
        return Employee.from_dict(raw)

    def test_dedicated_role_is_preferred_before_fallback_role(self) -> None:
        dedicated = self.employee_for("STANDARD", 100)
        fallback = self.employee_for("BACKUP", 1)
        role_id = dedicated.role_ids[0]
        day = date(2026, 8, 1)

        self.assertEqual(dedicated.role_assignment_penalty(role_id, day), 0)
        self.assertEqual(fallback.role_assignment_penalty(role_id, day), 1)
        self.assertLess(
            dedicated.role_assignment_penalty(role_id, day),
            fallback.role_assignment_penalty(role_id, day),
        )

    def test_unknown_assignment_mode_is_rejected(self) -> None:
        with self.assertRaisesRegex(SnapshotError, "STANDARD or BACKUP"):
            self.employee_for("SOMETIMES", 1)


if __name__ == "__main__":
    unittest.main()
