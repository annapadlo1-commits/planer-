# Dynamic Matrix v2 OR-Tools worker

This package is a provider-neutral Python/OR-Tools pull worker. Supabase keeps
the durable PGMQ queue, immutable snapshots, leases and results; the container
can run on an owner computer, NAS or any free/low-cost Docker host. The worker
never receives Supabase credentials.

The image supplies its immutable `SOLVER_VERSION`. `solver_claim_next_v2`
atomically consumes one queue message and grants a database lease only when the
reported worker version equals the version persisted on the run. A stale image
therefore fails closed before reading the snapshot.

Worker RPC sequence:

1. `solver_claim_next_v2`;
2. `solver_load_snapshot_v2`;
3. periodic `solver_heartbeat_v2`;
4. one `solver_save_variant_v2` per dynamic Matrix strategy;
5. `solver_finalize_v2`, or `solver_interrupt_v2` /
   `solver_fail_attempt_v2` on failure.

Required environment:

- `SOLVER_GATEWAY_URL` and `SOLVER_GATEWAY_TOKEN`;
- `SOLVER_VERSION` (the package version is the local-development fallback).

The worker polls only while idle, processes one run at a time, and may be
configured to exit after an idle period (`IDLE_EXIT_SECONDS`) or after a fixed
number of runs (`MAX_RUNS`). A Supabase Cron task requeues expired leases, so a
host shutdown never leaves a schedule permanently stuck in `RUNNING`.

The client disables proxy discovery and redirects, uses a strict action
allowlist, and never sends `apikey` or `Authorization` headers.

```bash
PYTHONPATH=src:/tmp/grafik_solver_deps python -m pytest -q
ruff check src tests
docker compose up --build -d
```
