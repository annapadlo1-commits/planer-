-- Phase 4A.2C: make future postgres-owned objects private by default.
--
-- This migration changes default privileges only. It does not alter ACLs on
-- any existing object, RLS, policies, business data, or managed Supabase roles.
--
-- Global revokes are required because per-schema default privileges are
-- additive. In particular, a schema-local revoke cannot remove PostgreSQL's
-- built-in global PUBLIC EXECUTE default for routines.

alter default privileges for role "postgres"
  revoke all on functions from public, "anon", "authenticated", "service_role";

alter default privileges for role "postgres"
  revoke all on tables from public, "anon", "authenticated", "service_role";

alter default privileges for role "postgres"
  revoke all on sequences from public, "anon", "authenticated", "service_role";

-- Phase 4A.2B intentionally restores the legacy additive public-schema rows.
-- Remove every captured entry, including the redundant postgres owner entry,
-- so baseline recovery and an ordinary migration chain converge. PostgreSQL
-- object owners retain their implicit owner privileges.

alter default privileges for role "postgres" in schema "public"
  revoke all on functions
  from public, "postgres", "anon", "authenticated", "service_role";

alter default privileges for role "postgres" in schema "public"
  revoke all on tables
  from public, "postgres", "anon", "authenticated", "service_role";

alter default privileges for role "postgres" in schema "public"
  revoke all on sequences
  from public, "postgres", "anon", "authenticated", "service_role";
