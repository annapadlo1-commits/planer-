from __future__ import annotations

import json
import sys
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "src"))

from grafik_solver.config import ConfigurationError, WorkerConfig
from grafik_solver.rpc import (
    MAX_GATEWAY_REQUEST_BYTES,
    RpcError,
    SolverGatewayClient,
)

GATEWAY_URL = "https://example.supabase.co/functions/v1/solver-gateway"
GATEWAY_TOKEN = "gateway-test-token".ljust(64, "x")
SOLVER_VERSION = "ORTOOLS_V2_2026_08_02"
RUN_ID = "11111111-1111-4111-8111-111111111111"
DISPATCH_TOKEN = "22222222-2222-4222-8222-222222222222"


class _Response:
    def __init__(self, body: bytes):
        self.body = body

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, maximum: int) -> bytes:
        return self.body[:maximum]


class GatewayClientTests(unittest.TestCase):
    def test_call_uses_only_gateway_token_and_exact_envelope(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        with patch.object(
            client._opener,
            "open",
            return_value=_Response(b'{"status":"READY"}'),
        ) as open_call:
            result = client.call("solver_finalize_v2", {"p_run_id": "run-placeholder"})

        self.assertEqual(result, {"status": "READY"})
        request = open_call.call_args.args[0]
        self.assertEqual(request.full_url, GATEWAY_URL)
        self.assertEqual(request.get_method(), "POST")
        headers = {name.lower(): value for name, value in request.header_items()}
        self.assertEqual(headers["x-solver-gateway-token"], GATEWAY_TOKEN)
        self.assertNotIn("apikey", headers)
        self.assertNotIn("authorization", headers)
        self.assertEqual(
            json.loads(request.data),
            {
                "action": "solver_finalize_v2",
                "args": {"p_run_id": "run-placeholder"},
            },
        )

    def test_unknown_action_is_rejected_before_network(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        with (
            patch.object(client._opener, "open") as open_call,
            self.assertRaisesRegex(RpcError, "is not allowed") as raised,
        ):
            client.call("solver_dispatch_next_v2", {})
        self.assertFalse(raised.exception.retryable)
        open_call.assert_not_called()

    def test_cloud_claim_is_bound_to_dispatch_and_worker_version(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        response = {
            "runId": "run-1",
            "attemptId": "attempt-1",
            "leaseToken": "lease-1",
        }
        with patch.object(client, "call", return_value=response) as call:
            claim = client.claim(
                run_id=RUN_ID,
                dispatch_token=DISPATCH_TOKEN,
                worker_id="worker-eu-1:42",
                worker_version=SOLVER_VERSION,
                task_attempt=1,
                lease_seconds=90,
            )
        self.assertEqual(claim.run_id, "run-1")
        call.assert_called_once_with(
            "solver_claim_v2",
            {
                "p_run_id": RUN_ID,
                "p_dispatch_token": DISPATCH_TOKEN,
                "p_worker_id": "worker-eu-1:42",
                "p_worker_version": SOLVER_VERSION,
                "p_task_attempt": 1,
                "p_lease_seconds": 90,
            },
        )

    def test_oversized_request_is_rejected_before_network(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        with (
            patch.object(client._opener, "open") as open_call,
            self.assertRaisesRegex(RpcError, "exceeds the client limit") as raised,
        ):
            client.call(
                "solver_save_variant_v2",
                {"p_variant": {"padding": "x" * MAX_GATEWAY_REQUEST_BYTES}},
            )
        self.assertFalse(raised.exception.retryable)
        open_call.assert_not_called()

    def test_http_status_preserves_retry_classification(self) -> None:
        for status, retryable in ((403, False), (429, True), (503, True)):
            with self.subTest(status=status):
                client = SolverGatewayClient(
                    GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1
                )
                error = urllib.error.HTTPError(
                    GATEWAY_URL, status, "gateway error", {}, None
                )
                with (
                    patch.object(client._opener, "open", side_effect=error),
                    self.assertRaises(RpcError) as raised,
                ):
                    client.call("solver_finalize_v2", {})
                self.assertEqual(raised.exception.status, status)
                self.assertEqual(raised.exception.retryable, retryable)

    def test_worker_configuration_has_no_service_role_fallback(self) -> None:
        valid_environment = {
            "SOLVER_GATEWAY_URL": GATEWAY_URL,
            "SOLVER_GATEWAY_TOKEN": GATEWAY_TOKEN,
            "SOLVER_VERSION": SOLVER_VERSION,
            "RUN_ID": RUN_ID,
            "DISPATCH_TOKEN": DISPATCH_TOKEN,
            "DISPATCH_ATTEMPT": "1",
        }
        with patch.dict("os.environ", valid_environment, clear=True):
            config = WorkerConfig.from_env()
        self.assertEqual(config.solver_gateway_url, GATEWAY_URL)
        self.assertEqual(config.solver_gateway_token, GATEWAY_TOKEN)
        self.assertEqual(config.solver_version, SOLVER_VERSION)
        self.assertEqual(config.run_id, RUN_ID)
        self.assertEqual(config.dispatch_token, DISPATCH_TOKEN)
        self.assertEqual(config.task_attempt, 1)

        legacy_only = {
            "SUPABASE_URL": "https://example.supabase.co",
            "SUPABASE_SECRET_KEY": "sb_secret_must_not_be_used",
        }
        with (
            patch.dict("os.environ", legacy_only, clear=True),
            self.assertRaisesRegex(ConfigurationError, "SOLVER_GATEWAY_URL"),
        ):
            WorkerConfig.from_env()

    def test_gateway_url_and_token_are_fail_closed(self) -> None:
        base = {
            "SOLVER_GATEWAY_URL": GATEWAY_URL,
            "SOLVER_GATEWAY_TOKEN": GATEWAY_TOKEN,
            "SOLVER_VERSION": SOLVER_VERSION,
            "RUN_ID": RUN_ID,
            "DISPATCH_TOKEN": DISPATCH_TOKEN,
            "DISPATCH_ATTEMPT": "1",
        }
        for name, value, message in (
            ("SOLVER_GATEWAY_TOKEN", "short", "SOLVER_GATEWAY_TOKEN"),
            (
                "SOLVER_GATEWAY_TOKEN",
                "sb_secret_not_a_gateway_token_1234567890",
                "SOLVER_GATEWAY_TOKEN",
            ),
            (
                "SOLVER_GATEWAY_TOKEN",
                "header.payload.signature",
                "SOLVER_GATEWAY_TOKEN",
            ),
            (
                "SOLVER_GATEWAY_URL",
                f"{GATEWAY_URL}?redirect=evil",
                "SOLVER_GATEWAY_URL",
            ),
            (
                "SOLVER_GATEWAY_URL",
                "https://user:password@example.supabase.co/functions/v1/solver-gateway",
                "SOLVER_GATEWAY_URL",
            ),
        ):
            with (
                self.subTest(name=name, value=value),
                patch.dict("os.environ", {**base, name: value}, clear=True),
                self.assertRaisesRegex(ConfigurationError, message),
            ):
                WorkerConfig.from_env()


if __name__ == "__main__":
    unittest.main()
