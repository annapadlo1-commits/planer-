# UAT branch handover — 2026-08-16

## Active replacement

- Branch: `codex/uat-consolidated-fixes`
- Current verified commit: `ced0a99792f52151649a6e08f6c3fabd4aa632d7`.
- Vercel: `Ready`; Northflank `solver-gateway`: build `imported-pocket-6666`, `Deployed`.
- Purpose: coherent repair batch collected after the owner stopped UAT on 2026-08-16.
- Promotion rule: this branch must not be merged to `main` or production before the full technical suite, Supabase UAT migration validation, deployed Chrome E2E and owner UAT all pass.

## Archived faulty state

- Archive branch: `archive/uat-failed-2026-08-16`
- Archived commit: `5701666a960e558755805c96c5e01279c3cd577c`
- Previous active UAT branch: `agent/uat-matrix-role-portal-overhaul`
- Reason for archive: the deployed UAT state blocked company-schedule merge and contained unresolved findings in Excel/Google Sheets import, overtime semantics and pricing, budgets, standby and decision drill-downs.
- The archive is a rollback/audit point only. It must never be selected as a production source.

## Previous active branch retired

- `agent/uat-matrix-role-portal-overhaul` was deleted remotely on 2026-08-16 after Vercel and Northflank deployed the replacement branch and the public smoke test passed.
- The deleted branch remains fully recoverable from `archive/uat-failed-2026-08-16`, which was verified immediately before deletion at the same commit `5701666a960e558755805c96c5e01279c3cd577c`.
- Do not recreate or deploy the retired branch. Use the archive only for rollback analysis.

## Remaining release gate

- Node `156/156`, solver `93` tests plus `32` subtests, TypeScript and Next build passed.
- Supabase UAT contains the three approved batch migrations; production Supabase remains untouched.
- Authenticated Chrome E2E on the branch preview and owner UAT remain required before any promotion.

Production Supabase `bdybebzvzapihjdauehg` and `main` remain out of scope.
