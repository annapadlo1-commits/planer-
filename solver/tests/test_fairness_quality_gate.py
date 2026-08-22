from __future__ import annotations

import json
import sys
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.lifecycle import (  # noqa: E402
    FairnessQualityGateFailed,
    WorkerRuntime,
)
from grafik_solver.models import Snapshot, SnapshotError, VariantResult  # noqa: E402


def quality_snapshot() -> Snapshot:
    raw = json.loads(
        (ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(
            encoding="utf-8"
        )
    )
    raw["settings"]["fairnessQualityGate"] = {
        "minimumEstimatedAchievableTargetUtilizationBps": 700,
        "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
        "maxAttempts": 3,
    }
    raw["strategies"][1]["code"] = "PREFERENCES"
    raw["strategies"][1]["randomSeed"] = 7
    return Snapshot.from_dict(raw)


def preference_variant(minimum_bps: int, spread_bps: int) -> VariantResult:
    return VariantResult(
        strategy_id="11111111-1111-4111-8111-111111111111",
        strategy_code="PREFERENCES",
        label="Preferencje i równy podział",
        sort_order=1,
        assignments=(),
        unfilled_slot_ids=(),
        metrics={
            "LOAD_UTILIZATION_TARGET_COUNT": 19,
            "MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_bps,
            "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": spread_bps,
        },
        stage_objectives=(),
        optimal=False,
        solution_hash="0" * 64,
    )


class SequenceEngine:
    def __init__(self, results: list[tuple[VariantResult, ...]]) -> None:
        self.results = results
        self.snapshots: list[Snapshot] = []

    def solve(self, snapshot: Snapshot) -> tuple[VariantResult, ...]:
        self.snapshots.append(snapshot)
        return self.results[len(self.snapshots) - 1]


def runtime_with(engine: SequenceEngine) -> WorkerRuntime:
    runtime = object.__new__(WorkerRuntime)
    runtime.engine = engine
    runtime._stop = type(
        "TestStop",
        (),
        {"event": threading.Event(), "get_reason": lambda self: None},
    )()
    return runtime


def test_bad_472_bps_attempt_is_retried_and_good_56_bps_result_is_audited() -> None:
    engine = SequenceEngine(
        [
            (preference_variant(500, 472),),
            (preference_variant(788, 56),),
        ]
    )
    variants = runtime_with(engine)._solve_with_quality_gate(quality_snapshot())

    assert len(engine.snapshots) == 2
    assert [snapshot.settings.random_seed for snapshot in engine.snapshots] == [
        7,
        104_736,
    ]
    assert engine.snapshots[1].strategies[1].random_seed == 104_736
    assert variants[0].metrics["FAIRNESS_QUALITY_GATE_PASSED"] == 1
    assert variants[0].metrics["FAIRNESS_QUALITY_GATE_ATTEMPT_COUNT"] == 2
    assert variants[0].metrics["FAIRNESS_QUALITY_GATE_SELECTED_SEED"] == 104_736
    assert variants[0].stage_objectives[-1] == {
        "tier": 0,
        "name": "FAIRNESS_QUALITY_GATE",
        "value": 56,
        "status": "PASS",
        "tolerance": 300,
        "frozenUpperBound": 300,
        "timeBudgetSeconds": 0,
        "elapsedSeconds": 0,
        "usedFallback": True,
    }


def test_three_failed_deterministic_attempts_are_not_publishable() -> None:
    engine = SequenceEngine(
        [
            (preference_variant(500, 472),),
            (preference_variant(650, 350),),
            (preference_variant(690, 310),),
        ]
    )
    runtime = runtime_with(engine)

    with pytest.raises(FairnessQualityGateFailed, match="po 3 deterministycznych"):
        runtime._solve_with_quality_gate(quality_snapshot())

    assert [snapshot.settings.random_seed for snapshot in engine.snapshots] == [
        7,
        104_736,
        209_465,
    ]
    assert WorkerRuntime._classify_failure(
        FairnessQualityGateFailed("failed")
    ) == (False, "FAIRNESS_QUALITY_GATE_FAILED")


def test_quality_gate_contract_rejects_out_of_range_or_unknown_settings() -> None:
    raw = json.loads(
        (ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(
            encoding="utf-8"
        )
    )
    raw["settings"]["fairnessQualityGate"] = {
        "minimumEstimatedAchievableTargetUtilizationBps": 700,
        "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
        "maxAttempts": 4,
    }
    with pytest.raises(SnapshotError, match="maxAttempts"):
        Snapshot.from_dict(raw)

    raw["settings"]["fairnessQualityGate"]["maxAttempts"] = 3
    raw["settings"]["fairnessQualityGate"]["hiddenOverride"] = True
    with pytest.raises(SnapshotError, match="Unsupported fairnessQualityGate"):
        Snapshot.from_dict(raw)
