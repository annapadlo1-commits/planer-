# Phase 4A.2B neutral live-schema baseline

This directory is a reviewed recovery artifact derived from the schema-only UAT
capture recorded in `manifest.json`. It is **not** part of the normal Supabase
migration chain. Nothing in this directory authorizes a remote database apply,
migration-ledger repair, UAT reset/rebase, or production access.

## Safety boundary

- The private raw capture is not committed.
- No business rows, `auth.users`, Storage objects, credentials, connection
  strings, cron command text, UAT project ref, or production project ref are in
  the neutral SQL files.
- The three isolated-UAT routines live only in
  `90_environment_uat_functions.sql.tmpl`. Their five project-ref literals are
  replaced by one mandatory token.
- Six Supabase event triggers, managed/extension ACLs, and `supabase_admin`
  default ACLs are observed and asserted on a compatible fresh platform; they
  are not replayed. The three application-owned `postgres/public` default-ACL
  sections are restored last to preserve the captured UAT behavior.
- The pinned fresh local platform contributes exactly three managed
  `supabase_admin/supabase_functions` default-ACL records. The source UAT has
  neither that schema nor those records. This platform compatibility delta is
  not rewritten: the restore contract asserts its exact 470-byte fingerprint
  separately, then verifies the remaining 29 records against the exact UAT
  fingerprint.
- The source companion attestation remains pinned at 56 records. Restore
  expects its only deliberate delta: the one cron job is absent because its
  command text was never captured. The 67 omitted ACL dump sections and the
  supplemental 75-record live managed-ACL catalog are independently hashed.
- The recovery cron job remains deferred because its command text was
  intentionally excluded from the capture.
- The `profile-avatars` bucket is created through the Storage API. Direct writes
  to `storage.buckets` are forbidden.
- The ordinary logged PGMQ queue `schedule_optimizer_v2` is reconstructed with
  `pgmq.create`; no queue messages or archive rows are captured.

## Deterministic local restore

Use only a fresh local Supabase/PostgreSQL 17 stack. Do not run this from a
linked checkout and do not copy the repository's legacy migrations into the
restore work directory.

1. Assemble the exact SQL and render a local-only 20-letter project ref:

   ```sh
   python scripts/phase4a2b/assemble_baseline.py \
     --baseline-dir supabase/baseline/phase4a2b \
     --project-ref localphasegateabcdef \
     --output /tmp/phase4a2b-baseline.sql
   ```

2. Apply the assembled bytes once, transactionally, to the fresh database.
3. Start the compatible local Storage API, export its local base URL (direct
   service URL or Kong URL ending in `/storage/v1`) and the matching local
   service-role key only for the local process, and run:

   ```sh
   SUPABASE_STORAGE_URL=http://127.0.0.1:5000 \
     scripts/phase4a2b/provision_local_storage_bucket.sh
   ```

4. Run `supabase/tests/phase4a2b_baseline_restore_contract.sql` and the selected
   rollback-only application contracts.
5. Stop the local project with `--no-backup` and repeat in a second, different
   fresh work directory through the Supabase local migration runner. The direct
   restore must leave zero migration rows; the migrator pass must create exactly
   one synthetic candidate row and must never import the UAT ledger.

`manifest.json` is the authority for file order, byte counts, and SHA-256
digests. The assembler stops if any listed byte changes, if the file set changes,
or if the environment token appears outside its template.
