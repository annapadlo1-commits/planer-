from __future__ import annotations

import json
import logging
from collections.abc import Callable, Iterable
from http import HTTPStatus
from typing import Any

from .cloud_run import CloudRunJobLauncher
from .config import DispatcherConfig
from .rpc import DispatcherGatewayClient, RpcError
from .service import DispatchCoordinator, DispatchRetryable, DispatchUncertain

LOGGER = logging.getLogger(__name__)

StartResponse = Callable[[str, list[tuple[str, str]]], Any]
WsgiApp = Callable[[dict[str, Any], StartResponse], Iterable[bytes]]


def _response(
    start_response: StartResponse, status: HTTPStatus, payload: dict[str, Any]
) -> list[bytes]:
    body = json.dumps(payload, separators=(",", ":")).encode()
    start_response(
        f"{status.value} {status.phrase}",
        [
            ("Cache-Control", "no-store"),
            ("Content-Type", "application/json; charset=utf-8"),
            ("Content-Length", str(len(body))),
            ("X-Content-Type-Options", "nosniff"),
        ],
    )
    return [body]


def _coordinator(config: DispatcherConfig) -> DispatchCoordinator:
    rpc = DispatcherGatewayClient(
        config.dispatcher_gateway_url,
        config.dispatcher_gateway_token,
        timeout_seconds=config.rpc_timeout_seconds,
    )
    launcher = CloudRunJobLauncher(
        config.cloud_run_job,
        config.solver_container_name,
        config.run_api_timeout_seconds,
    )
    return DispatchCoordinator(
        rpc=rpc,
        launcher=launcher,
        dispatcher_id=config.dispatcher_id,
        lease_seconds=config.dispatch_lease_seconds,
        max_per_request=config.max_dispatch_per_request,
        launch_grace_seconds=config.reconcile_launch_grace_seconds,
        recovery_limit=config.reconcile_limit,
    )


def create_app(
    config: DispatcherConfig | None = None,
    *,
    coordinator: DispatchCoordinator | None = None,
) -> WsgiApp:
    runtime_config = config or DispatcherConfig.from_environment()
    dispatch = coordinator or _coordinator(runtime_config)

    def application(
        environ: dict[str, Any], start_response: StartResponse
    ) -> Iterable[bytes]:
        path = str(environ.get("PATH_INFO", ""))
        method = str(environ.get("REQUEST_METHOD", "GET")).upper()
        if path == "/healthz" and method == "GET":
            return _response(start_response, HTTPStatus.OK, {"status": "ok"})
        if path != "/dispatch":
            return _response(
                start_response, HTTPStatus.NOT_FOUND, {"error": "NOT_FOUND"}
            )
        if method != "POST":
            return _response(
                start_response,
                HTTPStatus.METHOD_NOT_ALLOWED,
                {"error": "METHOD_NOT_ALLOWED"},
            )
        try:
            result = dispatch.dispatch_batch()
        except DispatchRetryable:
            return _response(
                start_response,
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"status": "retryable"},
            )
        except DispatchUncertain:
            return _response(
                start_response, HTTPStatus.ACCEPTED, {"status": "uncertain"}
            )
        except RpcError as exc:
            LOGGER.exception("Dispatcher gateway failed", exc_info=exc)
            return _response(
                start_response,
                HTTPStatus.SERVICE_UNAVAILABLE,
                {"error": "GATEWAY_UNAVAILABLE"},
            )
        except Exception as exc:
            LOGGER.exception("Unexpected dispatcher failure", exc_info=exc)
            return _response(
                start_response,
                HTTPStatus.INTERNAL_SERVER_ERROR,
                {"error": "INTERNAL_ERROR"},
            )

        status = (
            "dispatched"
            if result.started
            else "recovered"
            if result.recovery.changed
            else "idle"
        )
        return _response(
            start_response,
            HTTPStatus.OK,
            {
                "status": status,
                "started": len(result.started),
                "runIds": [run_id for run_id, _ in result.started],
                "recovery": {
                    "inspected": result.recovery.inspected,
                    "acknowledged": result.recovery.acknowledged,
                    "requeued": result.recovery.requeued,
                    "failed": result.recovery.failed,
                    "cancelled": result.recovery.cancelled,
                    "deferred": result.recovery.deferred,
                    "stale": result.recovery.stale,
                },
            },
        )

    return application
