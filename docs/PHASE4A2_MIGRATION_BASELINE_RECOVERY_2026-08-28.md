# Phase 4A.2 — UAT migration baseline recovery gate

Evidence refreshed: 2026-08-29T17:22:50Z

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
| Preflight Git blob SHA | `9d43a89a0e533b336e8d071832f321fcc0774972` |
| Preflight file SHA-256 | `52b9412dbaa71c9cebafaf1cbf9baef74d029deff2e7672a606c438297c690e9` |
| Companion records | `56` |
| Companion fingerprint | `e7f678581129e4f5669c668095e076c9e4e62e10f2fd7c913725cb559e4c074d` |

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

That default dump alone is not sufficient for this UAT. The evidence manifest records additional state that the baseline package must handle explicitly. The final preflight verdict fingerprints the complete captured companion snapshot and fails closed when any of it drifts:

- four custom `storage.objects` policies, including `USING` and `WITH CHECK` predicates, roles, permissiveness, and table RLS posture;
- the complete non-owner configuration of the private `profile-avatars` bucket;
- the `supabase_realtime` publication flags, direct members, column lists, row filters, and schema memberships;
- one active `pg_cron` job, represented by schedule, execution configuration, command byte length, and command hashes without command text;
- user-schema owners and ACLs, event-trigger definitions, extension versions/relocatability, and all 29 default-ACL rows.

No storage object data, employee data, auth users, secrets, connection strings, or cron command text are stored in the manifest.

Sections F and G of the preflight are additional diagnostics for human review. The exact ledger fingerprint already covers the protected migration-chain rows. The final automated `GO` gate covers the pinned session/capture role, UAT identity, ledger, active Matrix invariant, and the complete 56-record companion fingerprint.

## Required future procedure (not authorization)

This gate does not authorize a dump, restore, SQL execution beyond the read-only preflight, migration application, ledger repair, branch reset/rebase, deployment, or production access. Each later mutating or externally publishing step requires separate approval.

1. Remain on the reviewed Phase 4A.2 gate commit that contains this runbook and the preflight. The frozen source commit is provenance; do not check it out before executing the preflight.
2. Verify the exact preflight artifact, frozen source tree, ancestry, and unchanged migration directory. Any mismatch is **STOP**:

   ```sh
   test "$(git hash-object docs/PHASE4A2_UAT_BASELINE_READ_ONLY_PREFLIGHT.sql)" = 9d43a89a0e533b336e8d071832f321fcc0774972
   test "$(git rev-parse '5565c50370cb9436a76d1e6d7013250eaad2bece^{tree}')" = a8f6148cc0ff8960638553951972ba949b464d84
   git merge-base --is-ancestor 5565c50370cb9436a76d1e6d7013250eaad2bece HEAD
   git diff --exit-code 5565c50370cb9436a76d1e6d7013250eaad2bece HEAD -- supabase/migrations
   ```

3. Independently verify the connected Supabase target is UAT ref `nhthrtpkfpmufmrmdyjg`, environment `ISOLATED_UAT`, and not production ref `bdybebzvzapihjdauehg`. Do not rely only on copied connection parameters.
4. Execute the verified preflight with abort-on-first-error behavior. Any client/query error, incomplete result set, missing or multiple final verdict rows, or anything other than exactly one final row containing `GO — READ-ONLY SCHEMA CAPTURE ONLY` is **STOP**.
5. Preserve sanitized evidence including the gate HEAD, preflight blob SHA, source commit/tree, UAT identity, ledger receipt, companion record count/hash, and final verdict. Do not store credentials, connection strings, business rows, auth users, storage objects, or cron command text.
6. Only after `GO`, and only if separately authorized, create a schema-only capture using a read-only UAT connection. If a source checkout is needed, check out `5565c50370cb9436a76d1e6d7013250eaad2bece` only now; do not execute the preflight from that commit because it does not contain the artifact.
7. Author companion SQL as a local reviewed artifact only. Do not execute it on UAT or production. Parameterize or redact any cron command material and never commit secrets.
8. A restore requires separate authorization and may target only a fresh disposable isolated test project. Validate schema, RLS, ACL, RPC, Northflank, Matrix, and Phase 4A contracts before opening a separate baseline SQL PR.
9. Ledger repair remains **STOP** and requires its own reviewed plan and explicit authorization after restore evidence passes.

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

Verdict after merging this gate: **READY TO REQUEST AUTHORIZATION FOR READ-ONLY BASELINE CAPTURE**, not ready for migration repair.
