# Phase 4A.2C — default-privilege hardening

## Outcome

This phase adds one migration that makes future objects created by `postgres`
private by default. It is a layer after the immutable Phase 4A.2B neutral
baseline; it does not change that baseline or authorize applying it remotely.

The change removes legacy automatic access for `PUBLIC`, `anon`,
`authenticated`, and `service_role` from future tables, sequences, and
routines. Existing object ACLs, RLS policies, data, and Supabase-managed default
privileges are outside the migration's mutation scope.

## Why global and schema-local revokes are both required

PostgreSQL applies global default privileges first and adds schema-local
defaults afterward. A schema-local revoke cannot cancel a global privilege.
PostgreSQL also grants `PUBLIC EXECUTE` on new routines by default. Therefore:

1. global revokes remove automatic API-role privileges and the built-in routine
   `PUBLIC EXECUTE` default;
2. `public`-scoped revokes remove the additive legacy rows restored by Phase
   4A.2B;
3. the redundant schema-local `postgres` entries are removed so a baseline
   restore and an ordinary migration chain converge, while owners retain their
   implicit owner privileges.

Reference: https://www.postgresql.org/docs/current/sql-alterdefaultprivileges.html

This also follows Supabase's secure Data API direction: future exposed objects
must receive deliberate grants rather than inheriting API access.

Reference: https://supabase.com/changelog/45329-breaking-change-tables-not-exposed-to-data-and-graphql-api-automatically

## Future-object rule

Every future object in an exposed schema must be private unless the same
reviewed migration explicitly supplies the complete access contract:

- tables and views: narrow object grants, RLS, and policies; exposed views use
  an appropriate invoker-security model;
- sequences: only the exact rights required by the caller;
- routines: explicit role-only `EXECUTE` grants;
- `SECURITY DEFINER`: trusted owner, empty `search_path`, fully-qualified
  references, and explicit `EXECUTE` revokes/grants.

`service_role` bypassing RLS is not a substitute for an intentional object
grant and is never granted access by default.

## Verification gate

The source PR is not sufficient evidence by itself. Before merge, a separate
one-time isolated restore gate must:

1. restore the exact Phase 4A.2B baseline and run its unchanged legacy-state
   contract;
2. fingerprint every existing application object ACL, RLS table state, and
   policy before the migration;
3. apply Phase 4A.2C and prove those fingerprints are unchanged;
4. run the new rollback-only contract, including default-deny canaries for a
   table, sequence, invoker routine, and `SECURITY DEFINER` routine;
5. run Phase 4A.1, public API, runtime, and resource-scope regressions;
6. repeat through a two-row synthetic migration path and compare normalized
   final schemas;
7. prove cleanup leaves no containers, volumes, networks, or probe objects.

A local-container PASS must then be followed by a separately authorized test on
a fresh current hosted Supabase development project, including Security Advisor
checks before and after. The existing UAT is not the disposable validation
target for this phase.

## Safety status

- Phase 4A.2B baseline files and hashes: **IMMUTABLE**
- UAT baseline application: **STOP**
- UAT migration-ledger repair: **STOP**
- Production access or mutation: **STOP**
- `main`: **UNCHANGED**
- Supabase-managed default privileges: **OBSERVE ONLY**
