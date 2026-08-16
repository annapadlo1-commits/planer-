# UAT branch handover — 2026-08-16

## Active replacement

- Branch: `codex/uat-consolidated-fixes`
- Purpose: coherent repair batch collected after the owner stopped UAT on 2026-08-16.
- Promotion rule: this branch must not be merged to `main` or production before the full technical suite, Supabase UAT migration validation, deployed Chrome E2E and owner UAT all pass.

## Archived faulty state

- Archive branch: `archive/uat-failed-2026-08-16`
- Archived commit: `5701666a960e558755805c96c5e01279c3cd577c`
- Previous active UAT branch: `agent/uat-matrix-role-portal-overhaul`
- Reason for archive: the deployed UAT state blocked company-schedule merge and contained unresolved findings in Excel/Google Sheets import, overtime semantics and pricing, budgets, standby and decision drill-downs.
- The archive is a rollback/audit point only. It must never be selected as a production source.

## Retirement procedure for the previous active branch

Do not delete `agent/uat-matrix-role-portal-overhaul` until Vercel and Northflank are both configured to deploy the same validated commit from `codex/uat-consolidated-fixes`. After the replacement deployment and smoke tests:

1. record the exact Vercel and Northflank commit;
2. confirm the archive branch still points to the commit above;
3. delete the previous remote active branch;
4. update `PROJECT_STATUS.md` and the master UAT register with the new branch, commit and deployment evidence.

Production Supabase `bdybebzvzapihjdauehg` and `main` remain out of scope.
