# Solver Gateway

`solver-gateway` is the privileged Supabase boundary shared by the one-shot
OR-Tools worker and Cloud Run dispatcher. Neither receives the service-role
key; each uses an independent opaque token and channel-specific header.

## Worker channel

Header: `X-Solver-Gateway-Token`

| RPC | Purpose |
|---|---|
| `solver_claim_v2` | Claim the exact dispatched run using its one-time token and immutable solver version. |
| `solver_load_snapshot_v2` | Load the snapshot under a live lease. |
| `solver_heartbeat_v2` | Extend the lease and persist progress. |
| `solver_save_variant_v2` | Save a validated strategy result. |
| `solver_finalize_v2` | Perform final database validation. |
| `solver_interrupt_v2` | Persist controlled interruption. |
| `solver_fail_attempt_v2` | Persist a retryable or terminal failure. |

The claim requires `p_run_id`, `p_dispatch_token`, worker identity,
`p_worker_version`, dispatch attempt and lease duration. PostgreSQL verifies
the immutable version before consuming the launch token.

## Dispatcher channel

Header: `X-Dispatcher-Gateway-Token`

| RPC | Purpose |
|---|---|
| `solver_dispatch_next_v2` | Reserve one queued run. |
| `solver_mark_dispatched_v2` | Bind it to a Cloud Run execution. |
| `solver_release_dispatch_v2` | Release a conclusively rejected launch. |
| `solver_reconcile_stale_v2` | Scan and conditionally repair stale dispatch or lease states. |

Recovery supports `RESERVATION_EXPIRED`, `CLAIMED_UNACKNOWLEDGED`,
`LAUNCH_EXPIRED` and `LEASE_EXPIRED`. Direct apply of a
`CLAIMED_UNACKNOWLEDGED` candidate is allowed only after an exact `NOT_FOUND`
observation.

## Security

`SOLVER_GATEWAY_TOKEN` and `DISPATCHER_GATEWAY_TOKEN` must be distinct opaque
machine tokens and each must differ from `SUPABASE_SERVICE_ROLE_KEY`. Requests
must present exactly one channel header; cross-channel actions fail closed.

```bash
node --test supabase/functions/solver-gateway/contract.test.mjs
```
