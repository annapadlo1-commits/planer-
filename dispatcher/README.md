# Grafik Pro — Cloud Run dispatcher

Dispatcher is a deliberately small, single-instance HTTP service. It reserves a
PGMQ-backed solver run through the private gateway, starts exactly one Cloud Run
Job execution and acknowledges the execution name back to Postgres. It never
reads scheduling data and never holds the Supabase `service_role` secret.

`POST /dispatch` performs a bounded recovery sweep and starts at most
`MAX_DISPATCH_PER_REQUEST` executions. `GET /healthz` is side-effect free.

## Required configuration

- `DISPATCHER_GATEWAY_URL` — exact HTTPS Edge Function URL ending in
  `/functions/v1/solver-gateway`;
- `DISPATCHER_GATEWAY_TOKEN` — dispatcher-only machine token;
- `CLOUD_RUN_JOB` — full `projects/.../locations/.../jobs/...` resource name;
- `SOLVER_CONTAINER_NAME` — container name configured on that job.

The optional lease, reconciliation and timeout settings are bounded in
`grafik_dispatcher.config`. Per execution the dispatcher overrides only
`RUN_ID`, `DISPATCH_TOKEN` and `DISPATCH_ATTEMPT`. `SOLVER_VERSION` remains an
immutable base environment value on the digest-pinned job image.

## Failure model

Cloud Run API calls are never retried as blind launches. Before launch and after
an ambiguous response the dispatcher reconciles executions by run id, one-time
dispatch token and attempt number. A matching execution prevents a duplicate
launch even when its image reports another solver version; the version-bound
SQL claim then rejects the old image before it consumes the token.

Recovery is two-phase: Postgres returns immutable candidates, the dispatcher
observes Cloud Run, and only conclusive states are sent to the compare-and-swap
apply RPC. Active or unknown executions are retained for a later sweep.

Run locally with the same environment as Cloud Run:

```sh
gunicorn --bind 0.0.0.0:8080 --workers 1 --threads 1 \
  'grafik_dispatcher.app:create_app()'
```
