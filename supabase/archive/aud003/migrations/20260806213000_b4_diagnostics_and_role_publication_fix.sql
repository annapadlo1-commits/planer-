-- B4 UAT: restore candidate diagnostics and make role publication replace the
-- previous logical role schedule even when a newer company configuration uses
-- a different physical matrix_roles_v2 row.

create or replace function solver_private.variant_primary_conflict_reasons_uat_v2(
  p_variant_id uuid,
  p_employee_id uuid,
  p_shift_id uuid
) returns text[]
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_shift public.plan_shifts_v2%rowtype;
  v_matrix_version_id uuid;
  v_month date;
  v_reasons text[]:='{}'::text[];
  v_tier integer;
  v_maximum_shifts_per_day integer:=1;
begin
  select shift_row.* into v_shift
  from public.plan_shifts_v2 shift_row
  where shift_row.id=p_shift_id and shift_row.variant_id=p_variant_id;
  if v_shift.id is null then return array['SHIFT_NOT_FOUND']::text[]; end if;

  select run.matrix_version_id,run.month
  into v_matrix_version_id,v_month
  from public.plan_variants_v2 variant
  join public.optimization_runs_v2 run on run.id=variant.run_id
  where variant.id=p_variant_id;
  select coalesce(nullif(version.settings->>'maximumShiftsPerDay','')::integer,1)
  into v_maximum_shifts_per_day
  from public.matrix_versions version
  where version.id=v_matrix_version_id;

  if (
    select count(distinct assignment.shift_id)
    from public.plan_assignments_v2 assignment
    join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
    where assignment.variant_id=p_variant_id
      and assignment.employee_id=p_employee_id
      and assigned_shift.shift_date=v_shift.shift_date
  )>=v_maximum_shifts_per_day then
    v_reasons:=array_append(v_reasons,'ONE_PRIMARY_SHIFT_PER_DAY');
  end if;

  if (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'FIRST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date-1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'LAST'
        )
    )
  ) or (
    solver_private.shift_template_is_sequence_edge_uat_v2(
      v_matrix_version_id,v_shift.shift_template_id,v_shift.shift_date,'LAST'
    ) and exists(
      select 1
      from public.plan_assignments_v2 assignment
      join public.plan_shifts_v2 assigned_shift on assigned_shift.id=assignment.shift_id
      where assignment.variant_id=p_variant_id
        and assignment.employee_id=p_employee_id
        and assigned_shift.shift_date=v_shift.shift_date+1
        and solver_private.shift_template_is_sequence_edge_uat_v2(
          v_matrix_version_id,assigned_shift.shift_template_id,
          assigned_shift.shift_date,'FIRST'
        )
    )
  ) then
    v_reasons:=array_append(v_reasons,'CONSECUTIVE_SHIFT_SEQUENCE');
  end if;

  select standby.tier into v_tier
  from public.published_standby_assignments_v2 standby
  where standby.month=v_month
    and standby.standby_date=v_shift.shift_date
    and standby.employee_id=p_employee_id
    and standby.status in ('PLANNED','ACTIVATED')
  order by standby.tier
  limit 1;
  if v_tier=1 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_1_RESERVED');
  elsif v_tier=2 then
    v_reasons:=array_append(v_reasons,'STANDBY_TIER_2_RESERVED');
  end if;

  return v_reasons;
end;
$$;

create or replace function solver_private.supersede_previous_logical_role_schedule_uat_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_logical_role_id uuid;
begin
  select role.logical_id into v_logical_role_id
  from public.matrix_roles_v2 role
  where role.id=new.role_id;
  if v_logical_role_id is null then
    raise exception 'ROLE_LOGICAL_ID_MISSING';
  end if;

  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-logical-role:'||new.month::text||':'||v_logical_role_id::text,0
  ));

  update public.published_role_schedules_v2 publication
  set status='ARCHIVED',
      archived_at=now(),
      archived_by=coalesce(auth.uid(),new.created_by)
  from public.matrix_roles_v2 previous_role
  where publication.role_id=previous_role.id
    and publication.id<>new.id
    and publication.month=new.month
    and publication.status='PUBLISHED'
    and previous_role.logical_id=v_logical_role_id;
  return new;
end;
$$;

drop trigger if exists published_role_supersede_logical_predecessor_v2
  on public.published_role_schedules_v2;
create trigger published_role_supersede_logical_predecessor_v2
before insert on public.published_role_schedules_v2
for each row execute function
  solver_private.supersede_previous_logical_role_schedule_uat_v2();

notify pgrst,'reload schema';
