-- AUD-2026-09-01-011: resolve the business timezone and current month before
-- any month-scoped workspace read. No device timezone or UTC fallback is used.

create or replace function public.current_company_time_context_v1()
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_user uuid:=auth.uid();
  v_matrix record;
  v_timezone text;
  v_current_month text;
begin
  if v_user is null then raise exception 'AUTH_REQUIRED'; end if;
  if not exists(
    select 1 from public.user_permissions permission
    where permission.auth_user_id=v_user
  ) and not exists(
    select 1 from public.matrix_scope_grants_v2 grant_row
    where grant_row.auth_user_id=v_user and grant_row.active
  ) then
    raise exception 'ACCESS_REQUIRED';
  end if;

  select matrix_version.id,matrix_version.version,matrix_version.status,
    nullif(trim(matrix_version.settings->>'timezone'),'') timezone
  into v_matrix
  from public.matrix_versions matrix_version
  where matrix_version.schema_version>=2
    and matrix_version.status in ('ACTIVE','DRAFT')
  order by (matrix_version.status='ACTIVE') desc,matrix_version.version desc
  limit 1;
  if v_matrix.id is null or v_matrix.timezone is null then
    raise exception 'COMPANY_TIMEZONE_REQUIRED';
  end if;
  if not exists(select 1 from pg_catalog.pg_timezone_names where name=v_matrix.timezone) then
    raise exception 'COMPANY_TIMEZONE_INVALID';
  end if;

  v_timezone:=v_matrix.timezone;
  v_current_month:=to_char(pg_catalog.timezone(v_timezone,statement_timestamp()),'YYYY-MM');
  return jsonb_build_object(
    'timezone',v_timezone,
    'currentMonth',v_current_month,
    'matrixVersionId',v_matrix.id,
    'matrixVersion',v_matrix.version,
    'matrixStatus',v_matrix.status
  );
end;
$$;

revoke all on function public.current_company_time_context_v1() from public,anon;
grant execute on function public.current_company_time_context_v1() to authenticated;
