from __future__ import annotations

import unittest

from grafik_solver.cp_sat_engine import (
    BUILT_IN_STRATEGY_OBJECTIVE_TIERS,
    LEGACY_BUILT_IN_STRATEGY_OBJECTIVE_TIERS,
    LEGACY_MANDATORY_PRODUCT_GUARDS,
    LEGACY_STRATEGY_SEMANTICS_VERSION,
    MANDATORY_PRODUCT_GUARDS,
    OBSOLETE_HOME_STRATEGY_SEMANTICS_VERSION,
    PREVIOUS_MANDATORY_PRODUCT_GUARDS,
    PREVIOUS_STRATEGY_SEMANTICS_VERSION,
    STRATEGY_SEMANTICS_VERSION,
    CpSatScheduleEngine,
)
from grafik_solver.models import SnapshotError, Strategy


def strategy_raw(
    code: str,
    *,
    tier_override: tuple[str, int] | None = None,
    version: str = STRATEGY_SEMANTICS_VERSION,
) -> dict:
    objective_contract = (
        LEGACY_BUILT_IN_STRATEGY_OBJECTIVE_TIERS
        if version == LEGACY_STRATEGY_SEMANTICS_VERSION
        else BUILT_IN_STRATEGY_OBJECTIVE_TIERS
    )
    tiers = dict(objective_contract[code])
    if tier_override is not None:
        tiers[tier_override[0]] = tier_override[1]
    return {
        "id": f"strategy-{code.lower()}",
        "code": code,
        "label": code,
        "sortOrder": 0,
        "strategySemanticsVersion": version,
        "mandatoryProductGuards": list(
            MANDATORY_PRODUCT_GUARDS
            if version == STRATEGY_SEMANTICS_VERSION
            else PREVIOUS_MANDATORY_PRODUCT_GUARDS
            if version == PREVIOUS_STRATEGY_SEMANTICS_VERSION
            else LEGACY_MANDATORY_PRODUCT_GUARDS
        ),
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
            self.assertEqual(
                strategy.strategy_semantics_version,
                STRATEGY_SEMANTICS_VERSION,
            )
            self.assertEqual(
                strategy.mandatory_product_guards,
                MANDATORY_PRODUCT_GUARDS,
            )

    def test_historical_b4f165_matrix_remains_readable(self) -> None:
        for index, code in enumerate(LEGACY_BUILT_IN_STRATEGY_OBJECTIVE_TIERS):
            strategy = Strategy.from_dict(
                strategy_raw(code, version=LEGACY_STRATEGY_SEMANTICS_VERSION),
                index,
            )
            CpSatScheduleEngine._validate_strategy_semantics(strategy)
            self.assertEqual(
                strategy.strategy_semantics_version,
                LEGACY_STRATEGY_SEMANTICS_VERSION,
            )

    def test_historical_b4f168_matrix_remains_readable(self) -> None:
        for index, code in enumerate(BUILT_IN_STRATEGY_OBJECTIVE_TIERS):
            strategy = Strategy.from_dict(
                strategy_raw(
                    code,
                    version=OBSOLETE_HOME_STRATEGY_SEMANTICS_VERSION,
                ),
                index,
            )
            CpSatScheduleEngine._validate_strategy_semantics(strategy)
            self.assertEqual(
                strategy.strategy_semantics_version,
                OBSOLETE_HOME_STRATEGY_SEMANTICS_VERSION,
            )

    def test_historical_b4f169_matrix_remains_readable(self) -> None:
        for index, code in enumerate(BUILT_IN_STRATEGY_OBJECTIVE_TIERS):
            strategy = Strategy.from_dict(
                strategy_raw(code, version=PREVIOUS_STRATEGY_SEMANTICS_VERSION),
                index,
            )
            CpSatScheduleEngine._validate_strategy_semantics(strategy)
            self.assertEqual(
                strategy.strategy_semantics_version,
                PREVIOUS_STRATEGY_SEMANTICS_VERSION,
            )

    def test_current_contract_rejects_obsolete_home_location_objective(self) -> None:
        raw = strategy_raw("BALANCED")
        raw["objectiveTerms"].append(
            {
                "tier": 2,
                "metric": "HOME_LOCATION_VIOLATIONS",
                "weight": 1,
                "direction": "MIN",
            }
        )
        strategy = Strategy.from_dict(raw, 0)
        with self.assertRaisesRegex(
            SnapshotError,
            "HOME_LOCATION_VIOLATIONS is obsolete",
        ):
            CpSatScheduleEngine._validate_strategy_semantics(strategy)

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
