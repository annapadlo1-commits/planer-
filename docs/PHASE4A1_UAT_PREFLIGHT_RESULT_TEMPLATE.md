# Phase 4A.1 UAT read-only preflight result

> Run the companion SQL only in the manually verified SZAFUNEK UAT project. Do not paste secrets or personal data here.

## UAT identity confirmed manually: YES / NO
- Project reference/host (redacted):
- Database/user/version:

## Migration ledger
- Required Phase 1/3/3B versions present:
- `20260827160000` absent:
- Latest source / latest live:

## Migration ID compatibility classification
- Old-source IDs `20260826200600` / `20260826210018` present: YES / NO
- Canonical IDs `20260826201603` / `20260826210712` present: YES / NO
- Classification: CANONICAL UAT HISTORY / OLD-SOURCE HISTORY / MIXED HISTORY / CONFLICT / NOT YET APPLIED
- If an old-source ID is present: `STOP — MIGRATION HISTORY REPAIR REQUIRED BEFORE NORMAL MIGRATOR`

## Live ahead/source ahead/diverged
- Classification: NONE / SOURCE AHEAD / LIVE AHEAD / DIVERGED
- Unknown live migrations:

## RLS blockers

## Additional permissive policies

## ACL blockers

## Helper parity
- `has_app_role`:
- `can_manage_plans`:
- `matrix_v2_can_manage_resource_uat_v1`:

## Owner pattern
- Trusted helper owners:
- Decision on implicit owner: ACCEPT / SOURCE CHANGE REQUIRED

## Active Matrix count
- Expected: 1
- Actual:

## Duplicate role codes

## Duplicate location codes

## Unmapped legacy roles

## Unmapped legacy locations

## Scope grant problems

## Schema incompatibilities

## Baseline row counts

| Table | Before count |
|---|---:|

## Bulk-adjust live state
- ABSENT / PRESENT / SIGNATURE DRIFT:

## Final preflight verdict

Choose exactly one:

- `GO TO REQUEST MUTATION APPROVAL`
- `STOP`

Reason:
