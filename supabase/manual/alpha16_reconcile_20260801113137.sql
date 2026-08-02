-- MANUAL PRE-DEPLOYMENT STEP. Do not add this file to the migration runner.
--
-- Production recorded this migration before Supabase Branching was connected.
-- Its original statement assumes two legacy functions already exist, so a
-- clean branch replay can fail before base migrations are restored. This
-- transaction changes only that one stored statement and refuses to continue
-- if the production record is not exactly the audited value below.

begin;

do $repair$
declare
  v_name text;
  v_statements text[];
  v_expected text:=E'\nrevoke execute on function public.claim_demo_owner() from authenticated;\n\nalter function public.shift_minutes(timestamp with time zone, timestamp with time zone)\n  set search_path = \'\';\n';
  v_replacement text:=$safe$
do $migration$
begin
  if to_regprocedure('public.claim_demo_owner()') is not null then
    execute 'revoke execute on function public.claim_demo_owner() from authenticated';
  end if;
  if to_regprocedure(
      'public.shift_minutes(timestamp with time zone,timestamp with time zone)'
    ) is not null then
    execute $sql$
      alter function public.shift_minutes(
        timestamp with time zone,timestamp with time zone
      ) set search_path = ''
    $sql$;
  end if;
end;
$migration$;
$safe$;
  v_changed integer;
begin
  select migration.name,migration.statements
  into v_name,v_statements
  from supabase_migrations.schema_migrations migration
  where migration.version='20260801113137'
  for update;
  if not found then
    raise exception 'MIGRATION_20260801113137_NOT_FOUND';
  end if;
  if v_name<>'disable_demo_owner_claim_and_pin_search_path'
    or cardinality(v_statements)<>1
    or btrim(v_statements[1])<>btrim(v_expected) then
    raise exception 'MIGRATION_20260801113137_UNEXPECTED_CONTENT';
  end if;
  update supabase_migrations.schema_migrations
  set statements=array[v_replacement]
  where version='20260801113137';
  get diagnostics v_changed=row_count;
  if v_changed<>1 then
    raise exception 'MIGRATION_20260801113137_REPAIR_COUNT:%',v_changed;
  end if;
end;
$repair$;

commit;
