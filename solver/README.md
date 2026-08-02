# Dynamic Matrix v2 OR-Tools worker

This package is the one-shot Python/OR-Tools worker launched as a Cloud Run Job.
Supabase keeps the durable PGMQ queue, immutable snapshots, leases and results;
the dispatcher reserves a run and starts exactly one execution for it. The
worker never receives Supabase credentials.

The image supplies its immutable `SOLVER_VERSION`. The dispatcher supplies only
`RUN_ID`, `DISPATCH_TOKEN`, and `DISPATCH_ATTEMPT` as per-execution overrides.
`solver_claim_v2` consumes that reservation and grants a database lease only
when the reported worker version equals the version persisted on the run. A
stale image therefore fails closed before the dispatch token is consumed or the
snapshot is read.

Worker RPC sequence:

1. `solver_claim_v2` for the exact dispatched run;
2. `solver_load_snapshot_v2`;
3. periodic `solver_heartbeat_v2`;
4. one `solver_save_variant_v2` per dynamic Matrix strategy;
5. `solver_finalize_v2`, or `solver_interrupt_v2` /
   `solver_fail_attempt_v2` on failure.

Required environment:

- `SOLVER_GATEWAY_URL` and `SOLVER_GATEWAY_TOKEN`;
- `SOLVER_VERSION` (the package version is the local-development fallback).
- `RUN_ID`, `DISPATCH_TOKEN`, and positive `DISPATCH_ATTEMPT` execution
  overrides.

The worker processes only that run and exits. It does not poll the queue. The
dispatcher reconciles expired reservations, uncertain launches, and expired
worker leases, so an interrupted execution cannot leave a schedule permanently
stuck in `RUNNING`.

The client disables proxy discovery and redirects, uses a strict action
allowlist, and never sends `apikey` or `Authorization` headers.

```bash
PYTHONPATH=src:/tmp/grafik_solver_deps python -m pytest -q
ruff check src tests
docker compose run --rm solver
```
