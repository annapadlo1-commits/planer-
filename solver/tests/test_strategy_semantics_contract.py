from __future__ import annotations

import unittest

from grafik_solver.cp_sat_engine import (
    BUILT_IN_STRATEGY_OBJECTIVE_TIERS,
    MANDATORY_PRODUCT_GUARDS,
    CpSatScheduleEngine,
)
from grafik_solver.models import SnapshotError, Strategy


def strategy_raw(code: str, *, tier_override: tuple[str, int] | None = None) -> dict:
    tiers = dict(BUILT_IN_STRATEGY_OBJECTIVE_TIERS[code])
    if tier_override is not None:
        tiers[tier_override[0]] = tier_override[1]
    return {
        "id": f"strategy-{code.lower()}",
        "code": code,
        "label": code,
        "sortOrder": 0,
        "strategySemanticsVersion": "B4F165_V1",
        "mandatoryProductGuards": list(MANDATORY_PRODUCT_GUARDS),
        "objectiveTerms": [
            {
                "tier": tier,
                "metric": metric,
                "weight": 1,
                "direction": "MIN",
            }
            for metric, tier in tiers.items()
        ],
    }


class StrategySemanticsContractTests(unittest.TestCase):
    def test_published_contract_is_executed_exactly_as_declared(self) -> None:
        for index, code in enumerate(BUILT_IN_STRATEGY_OBJECTIVE_TIERS):
            strategy = Strategy.from_dict(strategy_raw(code), index)
            CpSatScheduleEngine._validate_strategy_semantics(strategy)
            self.assertEqual(strategy.strategy_semantics_version, "B4F165_V1")
            self.assertEqual(
                strategy.mandatory_product_guards,
                MANDATORY_PRODUCT_GUARDS,
            )

    def test_declared_and_effective_tier_mismatch_fails_closed(self) -> None:
        strategy = Strategy.from_dict(
            strategy_raw(
                "PREFERENCES",
                tier_override=("PREFERENCE_VIOLATIONS", 2),
            ),
            0,
        )
        with self.assertRaisesRegex(SnapshotError, "STRATEGY_SEMANTICS_MISMATCH"):
            CpSatScheduleEngine._validate_strategy_semantics(strategy)

    def test_legacy_unversioned_snapshot_remains_readable_without_hidden_override(self) -> None:
        raw = strategy_raw("PREFERENCES")
        raw.pop("strategySemanticsVersion")
        raw.pop("mandatoryProductGuards")
        raw["objectiveTerms"][3]["tier"] = 2
        strategy = Strategy.from_dict(raw, 0)
        CpSatScheduleEngine._validate_strategy_semantics(strategy)
        self.assertIsNone(strategy.strategy_semantics_version)


if __name__ == "__main__":
    unittest.main()
