-- AUD-2026-09-01-014: the fresh UAT advisor/catalog review leaves exactly
-- three evidence-backed single-column foreign keys without a leading index.
-- Do not apply this UAT-only migration to another Supabase project.

begin;

set local lock_timeout='5s';
set local statement_timeout='60s';

do $guard$
begin
  if not exists (
    select 1
    from public.uat_environment_controls control
    where control.control_key='ISOLATED_UAT_DESTRUCTIVE_TOOLS'
      and control.enabled is true
      and control.config->>'environment'='ISOLATED_UAT'
      and control.config->>'projectRef'='nhthrtpkfpmufmrmdyjg'
  ) then
    raise exception 'AUD014_WRONG_SUPABASE_PROJECT';
  end if;
end;
$guard$;

create index if not exists application_access_directory_v1_auth_user_id_fk_idx
  on public.application_access_directory_v1 (auth_user_id);

create index if not exists audit_log_actor_id_fk_idx
  on public.audit_log (actor_id);

create index if not exists employee_preferences_employee_id_fk_idx
  on public.employee_preferences (employee_id);

do $verify$
begin
  if exists(
    select 1
    from (values
      ('application_access_directory_v1_auth_user_id_fk_idx',
        'public.application_access_directory_v1'::regclass,'auth_user_id'),
      ('audit_log_actor_id_fk_idx','public.audit_log'::regclass,'actor_id'),
      ('employee_preferences_employee_id_fk_idx',
        'public.employee_preferences'::regclass,'employee_id')
    ) expected(index_name,table_oid,column_name)
    left join pg_catalog.pg_class index_relation
      on index_relation.relname=expected.index_name
      and index_relation.relnamespace='public'::regnamespace
    left join pg_catalog.pg_index index_row
      on index_row.indexrelid=index_relation.oid
    where index_relation.oid is null
      or index_row.indrelid<>expected.table_oid
      or index_row.indisvalid is not true
      or index_row.indisready is not true
      or index_row.indislive is not true
      or index_row.indpred is not null
      or index_row.indexprs is not null
      or index_row.indnkeyatts<>1
      or index_row.indnatts<>1
      or pg_catalog.pg_get_indexdef(index_relation.oid,1,true)
         <>expected.column_name
  ) then
    raise exception 'AUD014_INDEX_DEFINITION_MISMATCH';
  end if;
end;
$verify$;

commit;
