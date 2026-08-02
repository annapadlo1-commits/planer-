from __future__ import annotations

import io
import json
import os
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from grafik_dispatcher.app import create_app
from grafik_dispatcher.cloud_run import (
    CloudRunJobLauncher,
    ExecutionIdentity,
    ExecutionState,
    LaunchDisposition,
    LaunchReceipt,
    LaunchUncertain,
    RecoveryObservation,
    dispatch_override_environment,
    execution_identity_from_resource,
)
from grafik_dispatcher.config import DispatcherConfig
from grafik_dispatcher.rpc import (
    DispatcherGatewayClient,
    DispatchInFlight,
    DispatchReservation,
    RecoveryApplyResult,
    RecoveryCandidate,
    RecoveryKind,
    RpcError,
)
from grafik_dispatcher.service import DispatchCoordinator, DispatchUncertain

RUN_ID = "11111111-1111-4111-8111-111111111111"
TOKEN = "22222222-2222-4222-8222-222222222222"
EXECUTION = "projects/p/locations/europe-west1/jobs/solver/executions/e-1"
VERSION = "ORTOOLS_V2_2026_08_02"


def reservation(attempt: int = 1) -> DispatchReservation:
    return DispatchReservation(RUN_ID, TOKEN, 42, attempt, VERSION)


def execution(
    state: ExecutionState = ExecutionState.RUNNING, attempt: int = 1
) -> ExecutionIdentity:
    return ExecutionIdentity(EXECUTION, RUN_ID, TOKEN, attempt, VERSION, state)


class Response:
    def __init__(self, payload: object):
        self.body = json.dumps(payload).encode()

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, limit: int) -> bytes:
        return self.body[:limit]


class FakeApi:
    def __init__(self):
        self.executions: list[ExecutionIdentity] = []
        self.started = 0
        self.start_result = EXECUTION
        self.start_error: Exception | None = None
        self.get_calls: list[str] = []
        self.list_limits: list[int | None] = []

    def list_executions(self, *, limit: int | None):
        self.list_limits.append(limit)
        return tuple(self.executions if limit is None else self.executions[:limit])

    def get_execution(self, execution_name: str):
        self.get_calls.append(execution_name)
        return next(
            (item for item in self.executions if item.execution_name == execution_name),
            None,
        )

    def start_execution(self, _reservation: DispatchReservation):
        self.started += 1
        if self.start_error:
            raise self.start_error
        return self.start_result


class FakeRpc:
    def __init__(self):
        self.reservations: list[DispatchReservation | DispatchInFlight | None] = []
        self.candidates: list[RecoveryCandidate] = []
        self.marked: list[tuple[DispatchReservation, str]] = []
        self.released: list[DispatchReservation] = []
        self.applied: list[RecoveryCandidate] = []

    def reserve_next(self, **_kwargs):
        return self.reservations.pop(0) if self.reservations else None

    def mark_dispatched(self, item: DispatchReservation, execution_name: str):
        self.marked.append((item, execution_name))

    def release(self, item: DispatchReservation, **_kwargs):
        self.released.append(item)

    def scan_recovery(self, **_kwargs):
        return tuple(self.candidates)

    def apply_recovery(self, candidate: RecoveryCandidate, **_kwargs):
        self.applied.append(candidate)
        return RecoveryApplyResult(True, "REQUEUED", 99)


class FakeLauncher:
    def __init__(self):
        self.observations: dict[RecoveryKind, RecoveryObservation] = {}
        self.inflight: tuple[ExecutionIdentity, ...] = ()
        self.receipt = LaunchReceipt(execution(), LaunchDisposition.CREATED)

    def launch(self, _reservation: DispatchReservation):
        return self.receipt

    def find_inflight(self, _run_id: str):
        return self.inflight

    def observe_recovery(self, candidate: RecoveryCandidate):
        return self.observations[candidate.kind]


class RpcContractTests(unittest.TestCase):
    def client(self, payload: object) -> DispatcherGatewayClient:
        return DispatcherGatewayClient(
            "https://p.supabase.co/functions/v1/solver-gateway",
            "dispatcher-token".ljust(64, "x"),
            timeout_seconds=3,
            urlopen=lambda *_args, **_kwargs: Response(payload),
        )

    def test_reservation_preserves_solver_version(self):
        item = self.client(
            {
                "found": True,
                "runId": RUN_ID,
                "dispatchToken": TOKEN,
                "queueMessageId": 42,
                "dispatchAttempt": 1,
                "solverVersion": VERSION,
            }
        ).reserve_next(dispatcher_id="dispatcher:1", lease_seconds=90)
        self.assertEqual(item, reservation())

    def test_claimed_unacknowledged_shape(self):
        item = self.client(
            {
                "found": False,
                "dispatchInFlight": True,
                "claimedUnacknowledged": True,
                "runId": RUN_ID,
            }
        ).reserve_next(dispatcher_id="dispatcher:1", lease_seconds=90)
        self.assertEqual(item, DispatchInFlight(RUN_ID, True))

    def test_scan_accepts_all_four_kinds(self):
        rows = [
            {
                "runId": RUN_ID,
                "kind": "RESERVATION_EXPIRED",
                "dispatchToken": TOKEN,
                "dispatchAttempt": 1,
                "attemptNumber": None,
                "executionName": None,
                "solverVersion": VERSION,
            },
            {
                "runId": "33333333-3333-4333-8333-333333333333",
                "kind": "CLAIMED_UNACKNOWLEDGED",
                "dispatchToken": TOKEN,
                "dispatchAttempt": 1,
                "attemptNumber": 1,
                "executionName": None,
                "solverVersion": VERSION,
            },
            {
                "runId": "44444444-4444-4444-8444-444444444444",
                "kind": "LAUNCH_EXPIRED",
                "dispatchToken": None,
                "dispatchAttempt": 1,
                "attemptNumber": None,
                "executionName": EXECUTION,
                "solverVersion": VERSION,
            },
            {
                "runId": "55555555-5555-4555-8555-555555555555",
                "kind": "LEASE_EXPIRED",
                "dispatchToken": None,
                "dispatchAttempt": 1,
                "attemptNumber": 1,
                "executionName": EXECUTION,
                "solverVersion": VERSION,
            },
        ]
        candidates = self.client({"candidates": rows}).scan_recovery(
            dispatcher_id="dispatcher:1", limit=20, launch_grace_seconds=180
        )
        self.assertEqual({item.kind for item in candidates}, set(RecoveryKind))

    def test_claimed_terminal_cannot_be_applied_before_mark(self):
        candidate = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.CLAIMED_UNACKNOWLEDGED,
            1,
            TOKEN,
            1,
            None,
            VERSION,
        )
        with self.assertRaises(RpcError):
            self.client({}).apply_recovery(
                candidate,
                dispatcher_id="dispatcher:1",
                launch_grace_seconds=180,
                observed_state="FAILED",
                observed_execution_name=EXECUTION,
            )


class CloudRunTests(unittest.TestCase):
    def test_only_three_per_run_overrides(self):
        self.assertEqual(
            dispatch_override_environment(reservation()),
            (
                ("RUN_ID", RUN_ID),
                ("DISPATCH_TOKEN", TOKEN),
                ("DISPATCH_ATTEMPT", "1"),
            ),
        )

    def test_execution_requires_actual_solver_version(self):
        env = [
            SimpleNamespace(name="RUN_ID", value=RUN_ID),
            SimpleNamespace(name="DISPATCH_TOKEN", value=TOKEN),
            SimpleNamespace(name="DISPATCH_ATTEMPT", value="1"),
            SimpleNamespace(name="SOLVER_VERSION", value=VERSION),
        ]
        resource = SimpleNamespace(
            name=EXECUTION,
            running_count=1,
            template=SimpleNamespace(
                containers=[SimpleNamespace(name="solver", env=env)]
            ),
        )
        identity = execution_identity_from_resource(
            resource,
            job_name="projects/p/locations/europe-west1/jobs/solver",
            container_name="solver",
        )
        self.assertEqual(identity, execution())

    def test_existing_execution_prevents_duplicate_launch(self):
        api = FakeApi()
        api.executions = [execution()]
        receipt = CloudRunJobLauncher(
            "projects/p/locations/europe-west1/jobs/solver", "solver", 10, api=api
        ).launch(reservation())
        self.assertEqual(receipt.disposition, LaunchDisposition.EXISTING)
        self.assertEqual(api.started, 0)

    def test_mismatched_image_version_still_prevents_duplicate_launch(self):
        api = FakeApi()
        api.executions = [
            ExecutionIdentity(
                EXECUTION, RUN_ID, TOKEN, 1, "OLD_IMAGE", ExecutionState.RUNNING
            )
        ]
        receipt = CloudRunJobLauncher(
            "projects/p/locations/europe-west1/jobs/solver", "solver", 10, api=api
        ).launch(reservation())
        self.assertEqual(receipt.disposition, LaunchDisposition.EXISTING)
        self.assertEqual(receipt.execution.solver_version, "OLD_IMAGE")
        self.assertEqual(api.started, 0)

    def test_uncertain_launch_recovers_by_identity(self):
        api = FakeApi()
        api.start_error = TimeoutError()
        launcher = CloudRunJobLauncher(
            "projects/p/locations/europe-west1/jobs/solver",
            "solver",
            10,
            api=api,
            reconciliation_delay_seconds=0,
        )
        calls = 0

        def lists(*, limit: int | None):
            nonlocal calls
            calls += 1
            return (execution(),) if calls > 1 else ()

        api.list_executions = lists  # type: ignore[method-assign]
        receipt = launcher.launch(reservation())
        self.assertEqual(
            receipt.disposition, LaunchDisposition.RECOVERED_AFTER_UNCERTAIN
        )
        self.assertEqual(api.started, 1)

    def test_named_recovery_uses_exact_get(self):
        api = FakeApi()
        api.executions = [execution(ExecutionState.FAILED)]
        candidate = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.LEASE_EXPIRED,
            1,
            None,
            1,
            EXECUTION,
            VERSION,
        )
        observed = CloudRunJobLauncher(
            "projects/p/locations/europe-west1/jobs/solver", "solver", 10, api=api
        ).observe_recovery(candidate)
        self.assertEqual(observed.state, ExecutionState.FAILED)
        self.assertEqual(api.get_calls, [EXECUTION])

    def test_stale_reservation_search_is_exhaustive(self):
        api = FakeApi()
        candidate = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.RESERVATION_EXPIRED,
            1,
            TOKEN,
            None,
            None,
            VERSION,
        )
        CloudRunJobLauncher(
            "projects/p/locations/europe-west1/jobs/solver", "solver", 10, api=api
        ).observe_recovery(candidate)
        self.assertEqual(api.list_limits, [None])


class CoordinatorTests(unittest.TestCase):
    def coordinator(self, rpc: FakeRpc, launcher: FakeLauncher):
        return DispatchCoordinator(
            rpc=rpc,
            launcher=launcher,
            dispatcher_id="dispatcher:revision:instance",
            lease_seconds=90,
            max_per_request=1,
            launch_grace_seconds=180,
            recovery_limit=20,
        )

    def test_active_recovery_is_deferred_never_applied(self):
        rpc = FakeRpc()
        candidate = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.LEASE_EXPIRED,
            1,
            None,
            1,
            EXECUTION,
            VERSION,
        )
        rpc.candidates = [candidate]
        launcher = FakeLauncher()
        launcher.observations[candidate.kind] = RecoveryObservation(
            ExecutionState.RUNNING, execution()
        )
        result = self.coordinator(rpc, launcher).dispatch_batch()
        self.assertEqual(result.recovery.deferred, 1)
        self.assertEqual(rpc.applied, [])

    def test_claim_before_mark_then_dispatcher_death_then_lease_retry(self):
        rpc = FakeRpc()
        claimed = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.CLAIMED_UNACKNOWLEDGED,
            1,
            TOKEN,
            1,
            None,
            VERSION,
        )
        rpc.candidates = [claimed]
        launcher = FakeLauncher()
        terminal = execution(ExecutionState.FAILED)
        launcher.observations[claimed.kind] = RecoveryObservation(
            ExecutionState.FAILED, terminal
        )
        first = self.coordinator(rpc, launcher).dispatch_batch()
        self.assertEqual(first.recovery.acknowledged, 1)
        self.assertEqual(len(rpc.marked), 1)
        self.assertEqual(rpc.applied, [])

        expired = RecoveryCandidate(
            RUN_ID,
            RecoveryKind.LEASE_EXPIRED,
            1,
            None,
            1,
            EXECUTION,
            VERSION,
        )
        rpc.candidates = [expired]
        launcher.observations[expired.kind] = RecoveryObservation(
            ExecutionState.FAILED, terminal
        )
        second = self.coordinator(rpc, launcher).dispatch_batch()
        self.assertEqual(second.recovery.requeued, 1)
        self.assertEqual(rpc.applied, [expired])

    def test_new_launch_is_acknowledged_once(self):
        rpc = FakeRpc()
        rpc.reservations = [reservation()]
        launcher = FakeLauncher()
        result = self.coordinator(rpc, launcher).dispatch_batch()
        self.assertEqual(result.started, ((RUN_ID, EXECUTION),))
        self.assertEqual(len(rpc.marked), 1)

    def test_ambiguous_launch_keeps_reservation(self):
        rpc = FakeRpc()
        rpc.reservations = [reservation()]
        launcher = FakeLauncher()

        def uncertain(_reservation: DispatchReservation):
            raise LaunchUncertain("timeout")

        launcher.launch = uncertain  # type: ignore[method-assign]
        with self.assertRaises(DispatchUncertain):
            self.coordinator(rpc, launcher).dispatch_batch()
        self.assertEqual(rpc.released, [])


class ConfigAndAppTests(unittest.TestCase):
    def environment(self):
        return {
            "DISPATCHER_GATEWAY_URL": (
                "https://p.supabase.co/functions/v1/solver-gateway"
            ),
            "DISPATCHER_GATEWAY_TOKEN": "dispatcher".ljust(64, "x"),
            "CLOUD_RUN_JOB": "projects/p/locations/europe-west1/jobs/solver",
            "SOLVER_CONTAINER_NAME": "solver",
            "DISPATCHER_ID": "dispatcher:revision:instance",
        }

    def test_config_accepts_strict_cloud_run_environment(self):
        with patch.dict(os.environ, self.environment(), clear=True):
            config = DispatcherConfig.from_environment()
        self.assertEqual(config.reconcile_launch_grace_seconds, 180)

    def test_config_rejects_supabase_shaped_token(self):
        env = self.environment()
        env["DISPATCHER_GATEWAY_TOKEN"] = "a.b.c"
        with patch.dict(os.environ, env, clear=True), self.assertRaises(ValueError):
            DispatcherConfig.from_environment()

    def test_health_and_dispatch_responses(self):
        rpc = FakeRpc()
        launcher = FakeLauncher()
        config = DispatcherConfig(
            "https://p.supabase.co/functions/v1/solver-gateway",
            "dispatcher".ljust(64, "x"),
            "projects/p/locations/europe-west1/jobs/solver",
            "solver",
            "dispatcher:revision:instance",
            90,
            1,
            180,
            20,
            10,
            10,
        )
        app = create_app(
            config,
            coordinator=DispatchCoordinator(
                rpc=rpc,
                launcher=launcher,
                dispatcher_id="dispatcher:revision:instance",
                lease_seconds=90,
                max_per_request=1,
            ),
        )

        def call(path: str, method: str):
            status: list[str] = []
            headers: list[tuple[str, str]] = []
            body = b"".join(
                app(
                    {
                        "PATH_INFO": path,
                        "REQUEST_METHOD": method,
                        "wsgi.input": io.BytesIO(b""),
                    },
                    lambda value, items: (status.append(value), headers.extend(items)),
                )
            )
            return status[0], json.loads(body)

        status, body = call("/healthz", "GET")
        self.assertEqual(status, "200 OK")
        self.assertEqual(body["status"], "ok")
        status, body = call("/dispatch", "POST")
        self.assertEqual(status, "200 OK")
        self.assertEqual(body["started"], 0)


if __name__ == "__main__":
    unittest.main()
