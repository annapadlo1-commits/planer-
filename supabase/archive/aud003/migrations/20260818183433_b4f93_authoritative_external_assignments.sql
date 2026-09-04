-- B4F-93 regression: a manual September studio inherited every historical
-- variant whose row still said PUBLISHED, including role publications already
-- archived by the publication authority tables.  Those stale rows fabricated
-- overlaps, limits and consecutive-day violations in an otherwise empty draft.

alter function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
  rename to build_snapshot_payload_before_authoritative_external_uat_v1;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_month date := date_trunc('month',p_month)::date;
  v_period_end date := (date_trunc('month',p_month)+interval '1 month - 1 day')::date;
  v_external jsonb := '[]'::jsonb;
begin
  v_snapshot := solver_private.build_snapshot_payload_before_authoritative_external_uat_v1(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,p_scope_type,p_scope_role_id
  );

  with raw as (
    select value->>'employeeId' employee_id,
      (value->>'start')::timestamptz starts_at,
      (value->>'end')::timestamptz ends_at
    from jsonb_array_elements(coalesce(v_snapshot->'externalAssignments','[]'::jsonb))
  ), authoritative as (
    select distinct raw.employee_id,raw.starts_at,raw.ends_at
    from raw
    where raw.starts_at::date between v_month-6 and v_period_end+6
      and (
        -- Selected plans from another category in the month being assembled
        -- are intentionally supplied by the category wrapper and remain hard.
        raw.starts_at::date between v_month and v_period_end
        or exists (
          select 1
          from public.published_role_schedules_v2 publication
          join public.plan_assignments_v2 assignment
            on assignment.variant_id=publication.variant_id
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where publication.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
        or exists (
          select 1
          from public.published_schedules_v2 publication
          join public.published_schedule_variants_v2 member
            on member.schedule_id=publication.id
          join public.plan_assignments_v2 assignment
            on assignment.variant_id=member.variant_id
          join public.plan_shifts_v2 shift_row on shift_row.id=assignment.shift_id
          where publication.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
        or exists (
          select 1
          from public.plans plan_row
          join public.shifts shift_row on shift_row.plan_id=plan_row.id
          join public.assignments assignment on assignment.shift_id=shift_row.id
          where plan_row.status='PUBLISHED'
            and assignment.employee_id::text=raw.employee_id
            and shift_row.starts_at=raw.starts_at and shift_row.ends_at=raw.ends_at
        )
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',employee_id,'start',starts_at,'end',ends_at
  ) order by employee_id,starts_at,ends_at),'[]'::jsonb)
  into v_external from authoritative;

  return jsonb_set(v_snapshot,'{externalAssignments}',v_external,true);
end;
$$;

revoke all on function
  solver_private.build_snapshot_payload_before_authoritative_external_uat_v1(uuid,date,uuid,uuid,text,uuid),
  solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
from public,anon,authenticated;

grant execute on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)
to service_role;

comment on function solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid) is
  'Builds solver snapshots with current-month cross-category blocks and only authoritative adjacent-month publications; archived variants never constrain a new studio.';

-- Repair already opened manual studios as well.  The predicate is semantic,
-- not environment-specific: manual studios are leader copies without a source.
update solver_private.optimization_snapshots_v2 snapshot_row
set snapshot=solver_private.build_snapshot_payload_v2(
  run_row.id,run_row.month,run_row.matrix_version_id,run_row.scenario_id,
  run_row.scope_type,run_row.scope_role_id
)
from public.optimization_runs_v2 run_row
where snapshot_row.run_id=run_row.id
  and exists (
    select 1 from public.plan_variants_v2 variant
    where variant.run_id=run_row.id and variant.variant_kind='LEADER_COPY'
      and variant.source_variant_id is null
  );
