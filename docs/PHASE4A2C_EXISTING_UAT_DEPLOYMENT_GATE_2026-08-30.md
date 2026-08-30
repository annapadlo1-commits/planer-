# Phase 4A.2C — existing UAT deployment gate

## Purpose

This document defines a narrowly authorized exception to the disposable-hosted-
branch recommendation in the Phase 4A.2C design. It permits validation on the
existing isolated UAT project only after a fail-closed read-only preflight.

It does not authorize production access, migration-ledger repair, Phase 4A.2B
baseline application, replay of historical migrations, or use of any project
other than `nhthrtpkfpmufmrmdyjg`.

## Pinned UAT identity and state

- project ref: `nhthrtpkfpmufmrmdyjg`
- environment control: `ISOLATED_UAT_DESTRUCTIVE_TOOLS`
- environment value: `ISOLATED_UAT`
- pre-migration ledger rows: `254`
- pre-migration ledger MD5: `04c5c2ad59937027420bd7c71b782d14`
- expected migration: `20260830180000_phase4a2c_default_privileges_hardening`
- pre-migration application/default-ACL fingerprint:
  `29 / 3005 bytes / c86785623e746bdaf24fabcb75b2a6019385b230830284d851ec27ad030933a3`
- post-migration application/default-ACL fingerprint:
  `27 / 2708 bytes / 1f690d52941e6a5865cb59919ded58fa087f2e594215836bd33a78a1141ae9ff`
- existing public-object ACL/RLS/policy snapshot:
  `3623 / 367503 bytes / 9ea69a5ac1f4d89a7463aa2e2b8efe64e7bd87f753319e43e7e3c6b735071637`
- canonical migration receipt: `6 / 818 bytes / MD5 c3550dc2c665d7349a4919e314f7a356`
- exact post-migration ledger fingerprint:
  `255 / MD5 9996f95dfb7d936194efcf4e6fc59214`
- active Matrix: exactly one, workforce count `86`
- active Matrix content hash:
  `32dac23aea267e87c037a47dd796f06da03f9ab17e01da94c21603b301681187`
- active Matrix workforce hash:
  `0d64a87e0e96a3f77852f4234d12881c294b3dca8a555ae78644e10ff050b9a2`

Any mismatch is `STOP`. A new import, Matrix publication, migration, or platform
change requires recapture and review rather than weakening a predicate.

## Authorized sequence

1. Run `docs/PHASE4A2C_UAT_READ_ONLY_PREFLIGHT.sql` through a read-only execution
   path. The sole acceptable final verdict is `GO — PHASE4A2C UAT PREFLIGHT`.
2. Run `docs/PHASE4A2C_UAT_EXISTING_SECURITY_SNAPSHOT.sql` and record
   `3623 / 367503 / 9ea69a...1637`. Record Security and Performance Advisor
   results before migration.
3. Obtain explicit user authorization for the persistent UAT migration.
4. Execute the complete
   `docs/PHASE4A2C_UAT_ATOMIC_ONE_MIGRATION_APPLY.sql` in one Supabase MCP
   `execute_sql` call. Do not use `db push`, `migration up`,
   `apply_migration`, or replay the migration directory. The runner uses a
   `REPEATABLE READ` transaction, locks and fingerprints the 254-row ledger,
   and revalidates the pinned active Matrix, pre-migration default ACL,
   grantor-aware public ACL/RLS/policy snapshot, and zero probe residue inside
   that same transaction before the first `ALTER`. It then executes exactly
   the six statements also present in the reviewed migration, writes their
   canonical receipt, verifies the complete 255-row fingerprint, and commits
   atomically. Any mismatch aborts the entire transaction before mutation.
5. Verify the ledger is exactly
   `255 / 9996f95dfb7d936194efcf4e6fc59214`, and the new row is exactly
   `20260830180000 / phase4a2c_default_privileges_hardening / 6 statements /
   818 bytes / c3550dc2c665d7349a4919e314f7a356`.
6. Run `supabase/tests/phase4a2c_existing_uat_hosted_contract.sql`. It creates
   canary objects only inside a transaction and ends with `ROLLBACK`.
7. Re-run the canonical read-only security snapshot and require the exact same
   record count, byte count and SHA-256. Confirm active Matrix and business-data
   control counts are unchanged.
8. Re-run Security and Performance Advisors and compare with the recorded
   baseline.
9. Confirm no object whose name begins `phase4a2c_uat_probe_` exists.

The local-only contract remains unchanged. This hosted contract is a separate
identity-pinned gate and must never be generalized to accept an arbitrary
remote database.

## Forward-repair rule

The default-privilege migration and its canonical application receipt are
persistent. The receipt written atomically with the six statements is normal
migration application, not a later ledger repair. If postflight fails:

- stop application and migration work on the UAT branch;
- preserve all before/after evidence;
- do not edit or delete the applied ledger row;
- do not replay Phase 4A.2B or historical migrations;
- prepare a new forward-only repair migration from the observed catalog state;
- require independent review and explicit authorization before applying it.

## Safety boundary

- production ref `bdybebzvzapihjdauehg`: **NO ACCESS / NO MUTATION**
- `main`: **UNCHANGED**
- UAT business data: **NO DML**
- existing object ACL/RLS/policies: **OBSERVE ONLY**
- migration-ledger repair: **PROHIBITED**
- probe residue after rollback: **ZERO REQUIRED**
