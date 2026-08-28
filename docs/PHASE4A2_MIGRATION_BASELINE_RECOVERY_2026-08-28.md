# Phase 4A.2 — UAT migration baseline recovery gate

Captured: 2026-08-28T10:56:29.400Z

## Outcome

The current repository migration directory and the live UAT ledger are not safe to reconcile by timestamp renames or by replaying missing-looking files.

This change freezes the read-only evidence and introduces a fail-closed preflight for the next step. It intentionally contains **no baseline SQL**, performs **no ledger repair**, and changes **no Supabase migration file**.

## Fixed identities

| Item | Required value |
| --- | --- |
| Repository | `annapadlo1-commits/planer-` |
| Base branch | `codex/uat-consolidated-fixes` |
| Source commit | `5565c50370cb9436a76d1e6d7013250eaad2bece` |
| Source tree | `a8f6148cc0ff8960638553951972ba949b464d84` |
| UAT project ref | `nhthrtpkfpmufmrmdyjg` |
| UAT branch | `dynamic-matrix-solver-v2` |
| Forbidden production ref | `bdybebzvzapihjdauehg` |
| UAT ledger rows | `254` |
| UAT ledger fingerprint | `04c5c2ad59937027420bd7c71b782d14` |

## Reconciliation result

| Classification | Count |
| --- | ---: |
| Source migration files | 224 |
| Live UAT ledger rows | 254 |
| Same version and name | 45 |
| Same name, different version | 131 |
| Same-name mappings with normalized SQL equality | 90 |
| Same-name mappings with real SQL drift | 41 |
| Source-only names | 48 |
| Live-only names | 82 |

The 82 live-only names include 49 Alpha 16 replay entries, 4 development/manual repairs, 7 Northflank runtime migrations, and 22 other repair/final/receipt entries.

## Why a single live-schema baseline is required

The drift is semantic, not merely numeric. Later UAT repair migrations complete or replace behavior that differs from similarly named source migrations. In particular, do not rerun:

- `20260822160000_b4f165_strategy_source_of_truth.sql`;
- `20260822220000_b4f169_deterministic_fairness_quality_gate.sql`.

Those files can publish/clone Matrix state or otherwise mutate business data. Their downstream behavior is already represented in the live UAT schema.

Normal migration push, mass timestamp rewrite, and bulk `migration repair` remain **STOP** until a reviewed baseline has been captured and restored successfully on an isolated empty test project.

## Capture boundary

Supabase documents that `supabase db dump` creates a schema-only dump by default and excludes managed schemas such as `auth` and `storage`: https://supabase.com/docs/reference/cli/supabase-db-dump

That default dump alone is not sufficient for this UAT. The evidence manifest records additional state that the baseline package must handle explicitly:

- four custom `storage.objects` policies;
- the private `profile-avatars` bucket configuration;
- two `supabase_realtime` publication members;
- one active `pg_cron` job, recorded by schedule and command hash;
- custom schemas `authorization_private` and `solver_private`;
- extension inventory and default ACL count.

No storage object data, employee data, auth users, secrets, connection strings, or cron command text are stored in the manifest.

## Approved next-stage procedure

1. Check out the exact source commit/tree above.
2. Independently verify the Supabase target is the UAT project and not production.
3. Run `docs/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT.sql`.
4. Continue only when the final row is exactly `GO — READ-ONLY SCHEMA CAPTURE ONLY`.
5. In an approved environment with Supabase CLI, Docker, and a UAT-only database connection, run the official schema-only dump flow.
6. Build a companion SQL file for the managed-schema policies, bucket configuration, realtime membership, cron job, required extensions, and privilege/default-ACL behavior.
7. Review the generated SQL for data statements, credentials, environment-specific IDs, and ledger writes. A baseline must not contain business data or write to `supabase_migrations.schema_migrations`.
8. Restore the complete candidate baseline into a fresh isolated test project and run schema, RLS, ACL, RPC, Northflank, Matrix, and Phase 4A contracts.
9. Open a separate baseline SQL PR. Do not mutate the UAT ledger in that PR.
10. Only after baseline restore evidence passes may a separately authorized ledger-repair plan be proposed.

Supabase’s migration guide and repair command are reference material, not authorization to repair this database:

- https://supabase.com/docs/guides/deployment/database-migrations
- https://supabase.com/docs/reference/cli/supabase-migration-repair

## Exit criteria for this gate

- manifest fingerprint recomputes exactly;
- preflight is SELECT-only and fail-closed;
- source tree and UAT identity are pinned;
- excluded companion objects are enumerated;
- no file under `supabase/migrations/` changes;
- UAT and production remain unmodified.

Verdict after merging this gate: **READY FOR APPROVED READ-ONLY BASELINE CAPTURE**, not ready for migration repair.
