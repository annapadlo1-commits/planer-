# Solver Gateway

`solver-gateway` is the only privileged Supabase boundary used by the
provider-neutral OR-Tools worker. The worker never receives a Supabase
service-role key; it authenticates with one dedicated opaque gateway token.

Header: `X-Solver-Gateway-Token`

| RPC | Purpose |
|---|---|
| `solver_claim_next_v2` | Atomically pull one PGMQ message and create a version-bound lease. |
| `solver_load_snapshot_v2` | Load the immutable snapshot under a live lease. |
| `solver_heartbeat_v2` | Extend the lease and persist bounded progress. |
| `solver_save_variant_v2` | Save one validated strategy result. |
| `solver_finalize_v2` | Perform final database validation. |
| `solver_interrupt_v2` | Persist controlled interruption or cancellation. |
| `solver_fail_attempt_v2` | Persist a retryable or terminal worker error. |

`solver_claim_next_v2` requires `p_worker_id`, `p_worker_version`,
`p_task_attempt`, and `p_lease_seconds`. The database rejects the claim unless
`p_worker_version` equals the immutable `solver_version` stored on the run.

The token must contain 32-512 visible non-whitespace characters, must not look
like a Supabase key or JWT, and must differ from the service-role key. Unknown
actions, unknown arguments, malformed values, excessive JSON complexity and
oversized bodies are rejected before any privileged RPC is called.

Required Edge Function secret: `SOLVER_GATEWAY_TOKEN`. `SUPABASE_URL` and
the named `SUPABASE_SECRET_KEYS['default']` key remain available only inside
the function runtime. Missing or malformed secret-key configuration fails closed
without falling back to the legacy service-role credential.

```bash
node --test --experimental-strip-types contract.test.mjs
```
