-- GRAFIK PRO 3.0 — fail-closed cutover provenance guards
-- Alpha 15 stays usable in ALPHA15/SHADOW, but its legacy plans cannot become
-- the production schedule after DEFAULT_ENGINE is explicitly set to ORTOOLS_V2.

create or replace function solver_private.guard_legacy_plan_publication_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_engine text;
  v_becomes_published boolean;
begin
  if tg_op='INSERT' then
    v_becomes_published := new.status='PUBLISHED';
  else
    v_becomes_published := new.status='PUBLISHED'
      and old.status is distinct from new.status;
  end if;

  if not v_becomes_published then
    return new;
  end if;

  select flag.engine into v_engine
  from public.solver_feature_flags flag
  where flag.flag_key='DEFAULT_ENGINE';

  if v_engine='ORTOOLS_V2' then
    raise exception 'LEGACY_PUBLICATION_DISABLED';
  end if;
  return new;
end;
$$;

revoke all on function solver_private.guard_legacy_plan_publication_v2()
  from public,anon,authenticated;
grant execute on function solver_private.guard_legacy_plan_publication_v2()
  to service_role;

drop trigger if exists plans_legacy_publication_cutover_guard on public.plans;
create trigger plans_legacy_publication_cutover_guard
before insert or update of status on public.plans
for each row execute function solver_private.guard_legacy_plan_publication_v2();

comment on function solver_private.guard_legacy_plan_publication_v2() is
  'Blocks legacy Alpha 15 plan publication only after the explicit ORTOOLS_V2 cutover.';

-- The legacy portal exposes one status per calendar day. OR-Tools consumes
-- exact timestamp ranges instead, so employees need a self-only read boundary
-- that preserves multiple windows on the same day and protected HR/imported
-- absences. The Matrix effective on the first day of the requested month owns
-- the timezone, matching optimizer_configuration_v2/optimizer_request_v2.
create or replace function public.employee_time_constraints_self_v2(
  p_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date;
  v_employee_id uuid;
  v_timezone text;
  v_period_start timestamptz;
  v_period_end timestamptz;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if p_month is null then raise exception 'MONTH_REQUIRED'; end if;
  v_month:=date_trunc('month',p_month)::date;

  select employee_row.id into v_employee_id
  from public.employees employee_row
  where employee_row.auth_user_id=auth.uid()
    and employee_row.active
    and employee_row.archived_at is null
  order by employee_row.id
  limit 1;
  if v_employee_id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  select nullif(matrix_row.settings->>'timezone','') into v_timezone
  from public.matrix_versions matrix_row
  where matrix_row.status in ('ACTIVE','ARCHIVED')
    and matrix_row.schema_version>=2
    and matrix_row.effective_from<=v_month
    and coalesce(matrix_row.content_hash,'') ~ '^[0-9a-f]{64}$'
    and coalesce(matrix_row.workforce_hash,'') ~ '^[0-9a-f]{64}$'
  order by matrix_row.effective_from desc,matrix_row.version desc
  limit 1;
  if v_timezone is null then raise exception 'MATRIX_V2_FOR_MONTH_NOT_FOUND'; end if;
  if not exists(
    select 1 from pg_catalog.pg_timezone_names timezone_row
    where timezone_row.name=v_timezone
  ) then raise exception 'INVALID_MATRIX_TIMEZONE'; end if;

  v_period_start:=v_month::timestamp at time zone v_timezone;
  v_period_end:=(v_month+interval '1 month')::timestamp at time zone v_timezone;

  return jsonb_build_object(
    'employeeId',v_employee_id,
    'timezone',v_timezone,
    'constraints',coalesce((
      select jsonb_agg(jsonb_build_object(
        'id',constraint_row.id,
        'kind',constraint_row.constraint_kind,
        'startsAt',lower(constraint_row.time_range),
        'endsAt',upper(constraint_row.time_range),
        'source',constraint_row.source,
        'editable',constraint_row.source='GRAFIK_PRO'
          and constraint_row.editable_by_employee,
        'note',constraint_row.note
      ) order by lower(constraint_row.time_range),
        upper(constraint_row.time_range),constraint_row.id)
      from public.employee_time_constraints_v2 constraint_row
      where constraint_row.employee_id=v_employee_id
        and constraint_row.status='ACTIVE'
        and constraint_row.time_range
          && tstzrange(v_period_start,v_period_end,'[)')
    ),'[]'::jsonb)
  );
end;
$$;

revoke all on function public.employee_time_constraints_self_v2(date)
  from public,anon,authenticated;
grant execute on function public.employee_time_constraints_self_v2(date)
  to authenticated;

comment on function public.employee_time_constraints_self_v2(date) is
  'Returns only the authenticated employee exact active availability ranges for the Matrix month timezone.';
