# Phase 4A.1 — scoped-manager security review

Baseline: `a13ab2084f2348e0251a85ba51082707bc655aa5`
Scope: source preparation only; no UAT or production mutation.

## Active frontend call-site classification

No active frontend direct `.from(table)` call was found for `assignments`,
`employee_availability`, `operational_events`, `employees`,
`employee_locations`, `employee_capabilities`, `attendance_events`,
`plan_issues`, `employer_cost_components_v2` or
`recovery_incident_rate_revisions_v2`.

The active workflows use server RPC projections:

- schedule/assignments/person data: `matrix_v2_workspace`, published schedule,
  employee portal, solver workspace and calendar RPCs;
- availability: employee availability save/read RPCs and the scoped
  `availability_exception_review_uat_v2` manager RPC;
- operational events: workforce calendar and operational-program RPCs;
- employer costs: `employer_cost_workspace_uat_v1` and OWNER/ADMIN save RPC;
- incident rates: scoped recovery detail/propose and OWNER/ADMIN decide RPCs.

Therefore Phase 4A.1 keeps employee self table policies, scopes legal manager
table access, and removes manager direct finance-table reads without removing an
active frontend path.

## Final direct-table classification

| Surface | Class | Final rule |
|---|---|---|
| published legacy `plans`/`shifts` | A — intentional global authenticated read | only `PUBLISHED`; drafts are OWNER/ADMIN |
| `assignments` | B — resource scoped | self, OWNER/ADMIN, or exact role + location + employee scope |
| `employee_availability` and history | B/D | employee self, OWNER/ADMIN, or employee resource scope |
| `operational_events` | B | OWNER/ADMIN or exact location scope |
| employees/locations/capabilities/attendance | B/D | self/administrative roles or canonical employee/location scope |
| `plan_issues` | B | OWNER/ADMIN or exact issue role/location scope |
| employer-cost components and incident rates | C | OWNER/ADMIN/HR_FINANCE direct read; managers use redacted RPCs |
| Matrix role categories | B | OWNER/ADMIN/HR_FINANCE or a category containing a scoped role |

## Manager-predicate allowlist after Phase 4A.1

The final policy scan permits these patterns:

1. `can_manage_plans()` in legacy policies. Its final direct-request semantics
   are OWNER/ADMIN only; a scoped manager can reach it only inside a canonical
   resource-checked wrapper which sets the private transaction-local actor.
2. `published_role_schedules_v2_manager_read`: explicit active ROLE_MANAGER
   grant matched to the schedule role logical ID. Phase 1 prevents null wildcard
   ROLE_MANAGER grants.
3. `has_app_role('OWNER')`, `has_app_role('ADMIN')` and approved HR/self checks.
4. The Phase 4A policies use `matrix_v2_can_manage_resource_uat_v1` or the
   fail-closed legacy adapter; raw ROLE_MANAGER/LOCATION_MANAGER role-name
   predicates are not allowed in these policies.

No global ROLE_MANAGER or LOCATION_MANAGER direct-table predicate is approved.

The legacy adapter also requires exactly one ACTIVE Matrix and exactly one
active role/location code match. Zero or multiple matches return `false`; the
helper never selects a newest/first ambiguous resource. Its explicit EXECUTE
grant is limited to `authenticated`. The read-only UAT preflight confirmed the
trusted SECURITY DEFINER owner pattern, so the migration sets owner `postgres`.

## Canonical UAT migration provenance

- `20260826201603_employee_workspace_privacy.sql` is byte-identical to the
  historical source filename before provenance reconciliation
  (`20260826200600_employee_workspace_privacy.sql`).
- `20260826210712_explicit_anonymous_schedule_hardening.sql` is byte-identical
  to the historical source filename before provenance reconciliation
  (`20260826210018_explicit_anonymous_schedule_hardening.sql`).
- `20260826224321_restore_frontend_rpc_parity.sql` is **RECOVERED BYTE-EXACT
  FROM UAT schema_migrations.statements** (MD5
  `210a5e84e48a83e08fa957c0da680755`, 5771 bytes).
- The Phase 4A.1 helper owner is explicitly `postgres`, matching the trusted
  SECURITY DEFINER owner pattern confirmed by the UAT read-only preflight.

## Deliberate non-goals

- no tenant-model change;
- no business-data update;
- no bulk-adjust function or Phase 4 repair;
- no UAT migration execution;
- no production or deployment work.
