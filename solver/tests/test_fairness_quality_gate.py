from __future__ import annotations

import copy
import json
import sys
import threading
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.cp_sat_engine import (  # noqa: E402
    MANDATORY_PRODUCT_GUARDS,
    CpSatScheduleEngine,
    OptimizationError,
    OptimizationIncomplete,
)
from grafik_solver.lifecycle import WorkerRuntime  # noqa: E402
from grafik_solver.models import Snapshot, SnapshotError, VariantResult  # noqa: E402
from grafik_solver.validator import validate_variant  # noqa: E402


def quality_snapshot(
    strategy_codes: tuple[str, ...] = ("PREFERENCES",),
    *,
    max_attempts: int = 3,
) -> Snapshot:
    raw = json.loads(
        (ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(
            encoding="utf-8"
        )
    )
    raw["settings"].pop("fairnessQualityGate", None)
    raw["settings"]["fairnessQualityTarget"] = {
        "minimumEstimatedAchievableTargetUtilizationBps": 700,
        "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
        "maxAttempts": max_attempts,
    }
    prototypes = raw["strategies"]
    strategies = []
    for index, code in enumerate(strategy_codes):
        strategy = copy.deepcopy(prototypes[index % len(prototypes)])
        strategy["id"] = f"00000000-0000-4000-8000-{index + 1:012d}"
        strategy["code"] = code
        strategy["label"] = code
        strategy["sortOrder"] = index
        strategy["randomSeed"] = 7
        strategy.pop("strategySemanticsVersion", None)
        strategy.pop("mandatoryProductGuards", None)
        strategies.append(strategy)
    raw["strategies"] = strategies
    return Snapshot.from_dict(raw)


def variant(
    code: str,
    minimum_bps: int,
    spread_bps: int,
    *,
    stages: tuple[dict[str, object], ...] = (),
) -> VariantResult:
    index = {"BALANCED": 1, "MIN_COST": 2, "PREFERENCES": 3}.get(code, 9)
    return VariantResult(
        strategy_id=f"00000000-0000-4000-8000-{index:012d}",
        strategy_code=code,
        label=code,
        sort_order=index,
        assignments=(),
        unfilled_slot_ids=(),
        metrics={
            "LOAD_UTILIZATION_TARGET_COUNT": 19,
            "MIN_ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_BPS": minimum_bps,
            "ESTIMATED_ACHIEVABLE_TARGET_UTILIZATION_SPREAD_BPS": spread_bps,
        },
        stage_objectives=stages,
        optimal=False,
        solution_hash=f"{index}" * 64,
    )


def attempt(
    minimum_bps: int,
    spread_bps: int,
    strategy_codes: tuple[str, ...] = ("PREFERENCES",),
    *,
    stages: tuple[dict[str, object], ...] = (),
) -> tuple[VariantResult, ...]:
    return tuple(
        variant(
            code,
            minimum_bps if code == "PREFERENCES" else 1_000,
            spread_bps if code == "PREFERENCES" else 0,
            stages=stages if code == "PREFERENCES" else (),
        )
        for code in strategy_codes
    )


class SequenceEngine:
    def __init__(
        self,
        results: list[tuple[VariantResult, ...] | Exception],
    ) -> None:
        self.results = results
        self.snapshots: list[Snapshot] = []

    def solve(self, snapshot: Snapshot) -> tuple[VariantResult, ...]:
        self.snapshots.append(snapshot)
        result = self.results[len(self.snapshots) - 1]
        if isinstance(result, Exception):
            raise result
        return result


def runtime_with(engine: object) -> WorkerRuntime:
    runtime = object.__new__(WorkerRuntime)
    runtime.engine = engine
    runtime._stop = type(
        "TestStop",
        (),
        {"event": threading.Event(), "get_reason": lambda self: None},
    )()
    return runtime


def test_target_reached_returns_ready_quality_metadata() -> None:
    engine = SequenceEngine([attempt(500, 472), attempt(788, 56)])

    variants = runtime_with(engine)._solve_with_quality_target(quality_snapshot())

    assert [snapshot.settings.random_seed for snapshot in engine.snapshots] == [
        7,
        104_736,
    ]
    metrics = variants[0].metrics
    assert metrics["FAIRNESS_TARGET_MET"] == 1
    assert metrics["FAIRNESS_TARGET_ATTEMPT_COUNT"] == 2
    assert metrics["FAIRNESS_TARGET_SELECTED_ATTEMPT"] == 2
    assert metrics["FAIRNESS_TARGET_SELECTED_SEED"] == 104_736
    assert metrics["FAIRNESS_TARGET_FALLBACK_USED"] == 0
    assert variants[0].stage_objectives[-1]["status"] == "TARGET_MET"


def test_impossible_70_percent_still_returns_best_legal_60_to_69_percent() -> None:
    engine = SequenceEngine(
        [attempt(620, 380), attempt(660, 340), attempt(690, 310)]
    )

    variants = runtime_with(engine)._solve_with_quality_target(quality_snapshot())

    assert len(variants) == 1
    metrics = variants[0].metrics
    assert metrics["FAIRNESS_TARGET_MET"] == 0
    assert metrics["FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS"] == 690
    assert metrics["FAIRNESS_TARGET_ACTUAL_SPREAD_BPS"] == 310
    assert metrics["FAIRNESS_TARGET_ATTEMPT_COUNT"] == 3
    assert metrics["FAIRNESS_TARGET_FALLBACK_USED"] == 1
    assert variants[0].stage_objectives[-1]["status"] == (
        "TARGET_NOT_MET_BEST_FOUND"
    )


def test_real_cp_sat_returns_66_percent_legal_schedule_when_target_is_impossible(
) -> None:
    raw = json.loads(
        (ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(
            encoding="utf-8"
        )
    )
    raw.pop("slots")
    raw["periodStart"] = "2026-08-01"
    raw["periodEnd"] = "2026-08-08"
    raw["settings"].update(
        {
            "missingAvailabilityMeansAvailable": True,
            "requireOptimal": True,
            "fairnessQualityTarget": {
                "minimumEstimatedAchievableTargetUtilizationBps": 700,
                "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
                "maxAttempts": 1,
            },
        }
    )
    shift = next(
        item for item in raw["shiftTemplates"] if item["id"] == "shift-morning"
    )
    shift["weekdays"] = [1, 2, 3, 4, 5, 6, 7]
    raw["shiftTemplates"] = [shift]
    raw["demand"] = [
        {
            **raw["demand"][0],
            "dates": [f"2026-08-{day:02d}" for day in range(1, 9)],
            "requiredCount": 1,
        }
    ]
    for employee in raw["employees"]:
        employee.update(
            {
                "nominalMonthlyMinutes": 720,
                "maximumMonthlyMinutes": 720,
                "maximumWeeklyMinutes": 720,
                "softDayOffDates": [],
                "dutyIds": ["duty-service", "duty-close"],
            }
        )
    raw["availabilityWindows"] = []
    raw["hardBlocks"] = []
    raw["externalAssignments"] = []
    raw["lockedAssignments"] = []
    raw["payRules"] = []
    raw["budget"] = {"amountMinor": None, "hard": False}
    raw["strategies"] = [
        {
            "id": "00000000-0000-4000-8000-000000000003",
            "code": "PREFERENCES",
            "label": "Preferencje i rowny podzial",
            "sortOrder": 0,
            "timeLimitSeconds": 20,
            "randomSeed": 7,
            "strategySemanticsVersion": "B4F170_V1",
            "mandatoryProductGuards": list(MANDATORY_PRODUCT_GUARDS),
            "objectiveTerms": [
                {
                    "tier": 1,
                    "metric": "UNFILLED",
                    "weight": 1_000_000,
                    "direction": "MIN",
                },
                {
                    "tier": 2,
                    "metric": "ROLE_LOAD_FAIRNESS_SCORE",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 3,
                    "metric": "NOMINAL_DEVIATION_MINUTES",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 4,
                    "metric": "PREFERENCE_VIOLATIONS",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 5,
                    "metric": "ROLE_WEEKEND_FAIRNESS_SCORE",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 6,
                    "metric": "TOTAL_COST",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 7,
                    "metric": "OVERTIME_MINUTES",
                    "weight": 1,
                    "direction": "MIN",
                },
                {
                    "tier": 7,
                    "metric": "BASELINE_CHANGES",
                    "weight": 1,
                    "direction": "MIN",
                },
            ],
        }
    ]
    snapshot = Snapshot.from_dict(raw)

    variants = runtime_with(
        CpSatScheduleEngine(
            max_total_seconds=30,
            finalization_reserve_seconds=2,
        )
    )._solve_with_quality_target(snapshot)

    assert len(variants) == 1
    result = variants[0]
    assert validate_variant(snapshot, result).valid
    assert len(result.assignments) == 8
    assert not result.unfilled_slot_ids
    assert result.metrics["FAIRNESS_TARGET_MET"] == 0
    assert result.metrics["FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS"] == 666
    assert result.metrics["FAIRNESS_TARGET_ACTUAL_SPREAD_BPS"] == 334
    assert result.metrics["FAIRNESS_TARGET_FALLBACK_USED"] == 1


def test_spread_above_30_percentage_points_is_a_non_blocking_reason() -> None:
    variants = runtime_with(
        SequenceEngine([attempt(730, 360)])
    )._solve_with_quality_target(quality_snapshot(max_attempts=1))

    metrics = variants[0].metrics
    assert metrics["FAIRNESS_TARGET_MET"] == 0
    assert metrics["FAIRNESS_TARGET_MINIMUM_MET"] == 1
    assert metrics["FAIRNESS_TARGET_SPREAD_MET"] == 0
    assert metrics["FAIRNESS_TARGET_FAILURE_MINIMUM"] == 0
    assert metrics["FAIRNESS_TARGET_FAILURE_SPREAD"] == 1


def test_all_three_misses_return_the_best_valid_incumbent_not_empty_result() -> None:
    engine = SequenceEngine(
        [attempt(650, 200), attempt(680, 330), attempt(670, 100)]
    )

    variants = runtime_with(engine)._solve_with_quality_target(quality_snapshot())

    assert variants
    assert variants[0].metrics["FAIRNESS_TARGET_ACTUAL_MINIMUM_BPS"] == 680
    assert variants[0].metrics["FAIRNESS_TARGET_SELECTED_ATTEMPT"] == 2
    assert variants[0].metrics["FAIRNESS_TARGET_ATTEMPT_COUNT"] == 3


def test_preferences_miss_does_not_remove_balanced_or_min_cost() -> None:
    codes = ("BALANCED", "MIN_COST", "PREFERENCES")
    engine = SequenceEngine(
        [attempt(640, 360, codes), attempt(660, 340, codes), attempt(680, 320, codes)]
    )

    variants = runtime_with(engine)._solve_with_quality_target(
        quality_snapshot(codes)
    )

    assert [item.strategy_code for item in variants] == list(codes)
    preferences = next(item for item in variants if item.strategy_code == "PREFERENCES")
    assert preferences.metrics["FAIRNESS_TARGET_MET"] == 0
    assert all(item.metrics.get("FAIRNESS_TARGET_MET") is None for item in variants[:2])


def test_true_infeasible_without_any_incumbent_remains_an_error() -> None:
    engine = SequenceEngine([OptimizationError("hard model is infeasible")])

    with pytest.raises(OptimizationError, match="infeasible"):
        runtime_with(engine)._solve_with_quality_target(quality_snapshot())


def test_timeout_after_a_verified_attempt_returns_atomic_fallback() -> None:
    engine = SequenceEngine(
        [
            attempt(660, 240),
            OptimizationIncomplete("fairness optimization timeout"),
        ]
    )

    variants = runtime_with(engine)._solve_with_quality_target(quality_snapshot())

    metrics = variants[0].metrics
    assert metrics["FAIRNESS_TARGET_MET"] == 0
    assert metrics["FAIRNESS_TARGET_FALLBACK_USED"] == 1
    assert metrics["FAIRNESS_TARGET_TIMEOUT_FALLBACK_USED"] == 1
    assert metrics["FAIRNESS_TARGET_ATTEMPT_COUNT"] == 2
    assert variants[0].stage_objectives[-1]["status"] == (
        "TARGET_NOT_MET_TIME_LIMIT"
    )


def test_optimal_fairness_proof_marks_target_as_structurally_unattainable() -> None:
    proof = (
        {
            "tier": 0,
            "name": "COMMON_FAIRNESS_GUARD",
            "value": 360,
            "status": "OPTIMAL",
            "bestBound": 360.0,
            "tolerance": 0,
            "frozenUpperBound": 360,
            "timeBudgetSeconds": 1.0,
            "elapsedSeconds": 0.1,
            "usedFallback": False,
        },
    )
    variants = runtime_with(
        SequenceEngine([attempt(640, 200, stages=proof)])
    )._solve_with_quality_target(quality_snapshot(max_attempts=1))

    assert variants[0].metrics["FAIRNESS_TARGET_PROVEN_UNATTAINABLE"] == 1
    assert variants[0].stage_objectives[-1]["status"] == (
        "TARGET_NOT_MET_PROVEN"
    )


def test_quality_target_contract_accepts_legacy_key_but_rejects_bad_settings() -> None:
    raw = json.loads(
        (ROOT / "tests" / "fixtures" / "small_snapshot.json").read_text(
            encoding="utf-8"
        )
    )
    raw["settings"]["fairnessQualityTarget"] = {
        "minimumEstimatedAchievableTargetUtilizationBps": 700,
        "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
        "maxAttempts": 4,
    }
    with pytest.raises(SnapshotError, match="maxAttempts"):
        Snapshot.from_dict(raw)

    raw["settings"]["fairnessQualityTarget"]["maxAttempts"] = 3
    raw["settings"]["fairnessQualityTarget"]["hiddenOverride"] = True
    with pytest.raises(SnapshotError, match="Unsupported fairnessQualityTarget"):
        Snapshot.from_dict(raw)

    raw["settings"].pop("fairnessQualityTarget")
    raw["settings"]["fairnessQualityGate"] = {
        "minimumEstimatedAchievableTargetUtilizationBps": 700,
        "maximumEstimatedAchievableTargetUtilizationSpreadBps": 300,
        "maxAttempts": 3,
    }
    assert Snapshot.from_dict(raw).settings.fairness_quality_target is not None
