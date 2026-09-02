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
    Claim,
    MAX_GATEWAY_REQUEST_BYTES,
    RpcError,
    SolverGatewayClient,
)

GATEWAY_URL = "https://example.supabase.co/functions/v1/solver-gateway"
GATEWAY_TOKEN = "gateway-test-token".ljust(64, "x")
SOLVER_VERSION = "ORTOOLS_V2_2026_08_02"
SOLVER_CONTRACT_VERSION = "SOLVER_CONTRACT_V2"
SOLVER_SOURCE_SHA = "a" * 40
SOLVER_IMAGE_DIGEST = "sha256:" + "b" * 64
SOLVER_BUILD_TIMESTAMP = "2026-09-03T10:15:30Z"


class _Response:
    def __init__(self, body: bytes, status: int = 200):
        self.body = body
        self.status = status

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def read(self, maximum: int) -> bytes:
        return self.body[:maximum]

    def close(self) -> None:
        return None


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

    def test_pull_claim_is_bound_to_worker_version(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        response = {
            "runId": "run-1",
            "attemptId": "attempt-1",
            "leaseToken": "lease-1",
        }
        with patch.object(client, "call", return_value=response) as call:
            claim = client.claim(
                worker_id="worker-eu-1:42",
                worker_version=SOLVER_VERSION,
                contract_version=SOLVER_CONTRACT_VERSION,
                source_sha=SOLVER_SOURCE_SHA,
                image_digest=SOLVER_IMAGE_DIGEST,
                build_timestamp=SOLVER_BUILD_TIMESTAMP,
                task_attempt=1,
                lease_seconds=90,
            )
        self.assertEqual(claim.run_id, "run-1")
        call.assert_called_once_with(
            "solver_claim_next_v3",
            {
                "p_worker_id": "worker-eu-1:42",
                "p_worker_version": SOLVER_VERSION,
                "p_worker_build_manifest": {
                    "contractVersion": SOLVER_CONTRACT_VERSION,
                    "sourceSha": SOLVER_SOURCE_SHA,
                    "imageDigest": SOLVER_IMAGE_DIGEST,
                    "buildTimestamp": SOLVER_BUILD_TIMESTAMP,
                },
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

    def test_save_variants_uses_one_atomic_gateway_request(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        variants = (
            {"strategyCode": "BALANCED"},
            {"strategyCode": "MIN_COST"},
            {"strategyCode": "PREFERENCES"},
        )
        with patch.object(
            client,
            "call",
            return_value={"savedVariantCount": 3},
        ) as call:
            result = client.save_variants(
                Claim("run-1", "attempt-1", "lease-1"),
                variants,
            )

        self.assertEqual(result, {"savedVariantCount": 3})
        call.assert_called_once_with(
            "solver_save_variants_v2",
            {
                "p_run_id": "run-1",
                "p_attempt_id": "attempt-1",
                "p_lease_token": "lease-1",
                "p_variants": [dict(variant) for variant in variants],
            },
        )

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

    def test_http_error_preserves_safe_gateway_failure_code(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        error = urllib.error.HTTPError(
            GATEWAY_URL,
            400,
            "gateway error",
            {},
            _Response(b'{"error":"RUN_VARIANTS_INCOMPLETE"}'),
        )
        with (
            patch.object(client._opener, "open", side_effect=error),
            self.assertRaisesRegex(RpcError, "RUN_VARIANTS_INCOMPLETE") as raised,
        ):
            client.call("solver_finalize_v2", {})
        self.assertFalse(raised.exception.retryable)

    def test_heartbeat_retries_malformed_success_json(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=2)
        responses = [
            _Response(b'{"ok":'),
            _Response(b'{"cancelRequested":false,"leaseValid":true}'),
        ]
        with patch.object(client._opener, "open", side_effect=responses) as open_call:
            heartbeat = client.heartbeat(
                Claim("run-1", "attempt-1", "lease-1"),
                {"schemaVersion": 2, "phase": "SOLVING", "progress": 10},
            )

        self.assertFalse(heartbeat.cancel_requested)
        self.assertTrue(heartbeat.lease_valid)
        self.assertEqual(open_call.call_count, 2)

    def test_non_heartbeat_malformed_json_remains_fail_closed(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=2)
        with (
            patch.object(client._opener, "open", return_value=_Response(b'{"ok":')),
            self.assertRaisesRegex(RpcError, "returned invalid JSON") as raised,
        ):
            client.call("solver_finalize_v2", {"p_run_id": "run-1"})

        self.assertFalse(raised.exception.retryable)
        self.assertEqual(raised.exception.status, 200)

    def test_heartbeat_unexpected_success_shape_is_retryable(self) -> None:
        client = SolverGatewayClient(GATEWAY_URL, GATEWAY_TOKEN, maximum_attempts=1)
        with (
            patch.object(client, "call", return_value="unexpected"),
            self.assertRaisesRegex(RpcError, "unexpected response shape") as raised,
        ):
            client.heartbeat(
                Claim("run-1", "attempt-1", "lease-1"),
                {"schemaVersion": 2, "phase": "SOLVING"},
            )

        self.assertTrue(raised.exception.retryable)

    def test_worker_configuration_has_no_service_role_fallback(self) -> None:
        valid_environment = {
            "SOLVER_GATEWAY_URL": GATEWAY_URL,
            "SOLVER_GATEWAY_TOKEN": GATEWAY_TOKEN,
            "SOLVER_VERSION": SOLVER_VERSION,
            "SOLVER_CONTRACT_VERSION": SOLVER_CONTRACT_VERSION,
            "SOLVER_SOURCE_SHA": SOLVER_SOURCE_SHA,
            "SOLVER_IMAGE_DIGEST": SOLVER_IMAGE_DIGEST,
            "SOLVER_BUILD_TIMESTAMP": SOLVER_BUILD_TIMESTAMP,
            "WORKER_TASK_ATTEMPT": "1",
        }
        with patch.dict("os.environ", valid_environment, clear=True):
            config = WorkerConfig.from_env()
        self.assertEqual(config.solver_gateway_url, GATEWAY_URL)
        self.assertEqual(config.solver_gateway_token, GATEWAY_TOKEN)
        self.assertEqual(config.solver_version, SOLVER_VERSION)
        self.assertEqual(config.contract_version, SOLVER_CONTRACT_VERSION)
        self.assertEqual(config.source_sha, SOLVER_SOURCE_SHA)
        self.assertEqual(config.image_digest, SOLVER_IMAGE_DIGEST)
        self.assertEqual(config.build_timestamp, SOLVER_BUILD_TIMESTAMP)
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
            "SOLVER_CONTRACT_VERSION": SOLVER_CONTRACT_VERSION,
            "SOLVER_SOURCE_SHA": SOLVER_SOURCE_SHA,
            "SOLVER_IMAGE_DIGEST": SOLVER_IMAGE_DIGEST,
            "SOLVER_BUILD_TIMESTAMP": SOLVER_BUILD_TIMESTAMP,
            "WORKER_TASK_ATTEMPT": "1",
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

    def test_worker_build_manifest_is_fail_closed(self) -> None:
        base = {
            "SOLVER_GATEWAY_URL": GATEWAY_URL,
            "SOLVER_GATEWAY_TOKEN": GATEWAY_TOKEN,
            "SOLVER_VERSION": SOLVER_VERSION,
            "SOLVER_CONTRACT_VERSION": SOLVER_CONTRACT_VERSION,
            "SOLVER_SOURCE_SHA": SOLVER_SOURCE_SHA,
            "SOLVER_IMAGE_DIGEST": SOLVER_IMAGE_DIGEST,
            "SOLVER_BUILD_TIMESTAMP": SOLVER_BUILD_TIMESTAMP,
            "WORKER_TASK_ATTEMPT": "1",
        }
        for name, value in (
            ("SOLVER_CONTRACT_VERSION", ""),
            ("SOLVER_SOURCE_SHA", "not-a-git-sha"),
            ("SOLVER_IMAGE_DIGEST", "latest"),
            ("SOLVER_BUILD_TIMESTAMP", "2026-09-03"),
        ):
            with (
                self.subTest(name=name),
                patch.dict("os.environ", {**base, name: value}, clear=True),
                self.assertRaisesRegex(ConfigurationError, name),
            ):
                WorkerConfig.from_env()

    def test_platform_deployment_sha_is_authoritative(self) -> None:
        base = {
            "SOLVER_GATEWAY_URL": GATEWAY_URL,
            "SOLVER_GATEWAY_TOKEN": GATEWAY_TOKEN,
            "SOLVER_VERSION": SOLVER_VERSION,
            "SOLVER_CONTRACT_VERSION": SOLVER_CONTRACT_VERSION,
            "SOLVER_SOURCE_SHA": SOLVER_SOURCE_SHA,
            "SOLVER_IMAGE_DIGEST": SOLVER_IMAGE_DIGEST,
            "SOLVER_BUILD_TIMESTAMP": SOLVER_BUILD_TIMESTAMP,
            "WORKER_TASK_ATTEMPT": "1",
        }

        with patch.dict(
            "os.environ",
            {**base, "NF_DEPLOYMENT_SHA": SOLVER_SOURCE_SHA},
            clear=True,
        ):
            config = WorkerConfig.from_env()
        self.assertEqual(config.source_sha, SOLVER_SOURCE_SHA)

        with (
            patch.dict(
                "os.environ",
                {**base, "NF_DEPLOYMENT_SHA": "c" * 40},
                clear=True,
            ),
            self.assertRaisesRegex(
                ConfigurationError,
                "SOLVER_SOURCE_SHA must match NF_DEPLOYMENT_SHA",
            ),
        ):
            WorkerConfig.from_env()

        with (
            patch.dict(
                "os.environ",
                {
                    **base,
                    "SOLVER_SOURCE_SHA": "",
                    "NF_DEPLOYMENT_SHA": "not-a-git-sha",
                },
                clear=True,
            ),
            self.assertRaisesRegex(ConfigurationError, "NF_DEPLOYMENT_SHA"),
        ):
            WorkerConfig.from_env()


if __name__ == "__main__":
    unittest.main()
