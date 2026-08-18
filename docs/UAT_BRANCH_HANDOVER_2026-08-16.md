# UAT branch handover — 2026-08-16

> **Aneks 2026-08-18:** po commitach `e191cf6`, `5afd356` i `a999e9b` Studio lidera może rozpocząć od pustej obsady i korzysta z autorytatywnego snapshotu zewnętrznych przydziałów. Docelowy rozwój jednego szkicu, operacji zbiorczych, panelu skutków, blokad i cyklu publikacji opisują nadrzędne `LEADER_STUDIO_PRODUCT_SCOPE_2026-08-18.md` oraz B4F-97–B4F-101. Lokalny fragment B4F-99 nie jest jeszcze wdrożony na UAT.

## Active replacement

- Branch: `codex/uat-consolidated-fixes`
- Current verified commit: `ce079390c741577e08b126bb4a86104f170748dd` (`ce07939`).
- Vercel: deployment `GXK2udQjyx25DijPCufHpuGFfdD3`, GitHub status `success`; Northflank `solver-gateway`: build `buoyant-elbow-9669`, GitHub status `success`.
- Draft PR: `#7`.
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

## Current release gate — audit update 2026-08-17

- Node `182/182`, solver `93/93`, TypeScript and Next production build passed for `ce07939`.
- Supabase UAT contains eight approved migrations in the replacement line; production Supabase remains untouched.
- Authenticated desktop E2E of the prior functional batch and authenticated mobile E2E at `390×844` for `ce07939` passed technically. Physical-device PWA installation and the full owner UAT remain required before any promotion.
- Open, not implemented release items include B4F-44/B4F-73 (canonical Google OAuth/UAT host), B4F-52 (permissions), B4F-70 (leader editing context), B4F-71 (global proportional fairness) and B4F-74 (leader recalculated summary). B4F-33 remains a separate product decision about simultaneous multi-location coverage.

Production Supabase `bdybebzvzapihjdauehg` and `main` remain out of scope.
