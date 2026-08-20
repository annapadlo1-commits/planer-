-- B4F-115: exact blockers for active shifts without base staffing.
-- B4F-118: explicit, versioned shift marker colors preserved across drafts.

alter table public.matrix_shift_templates_v2
  add column color text not null default '#879681';

alter table public.matrix_shift_templates_v2
  add constraint matrix_shift_templates_v2_color_hex_check
  check (color ~ '^#[0-9A-Fa-f]{6}$');

create function public.matrix_shift_color_preserve_on_clone_uat_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_source_color text;
begin
  select source_row.color into v_source_color
  from public.matrix_shift_templates_v2 source_row
  where source_row.logical_id=new.logical_id
  order by source_row.updated_at desc,source_row.created_at desc,source_row.id desc
  limit 1;
  if v_source_color is not null then new.color:=v_source_color; end if;
  return new;
end;
$$;

revoke all on function public.matrix_shift_color_preserve_on_clone_uat_v1() from public,anon,authenticated;

create trigger matrix_shift_color_preserve_on_clone_uat_v1
before insert on public.matrix_shift_templates_v2
for each row execute function public.matrix_shift_color_preserve_on_clone_uat_v1();

alter function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)
  rename to matrix_v2_admin_save_before_b4f118;

create function public.matrix_v2_admin_save_alpha16(
  p_kind text,p_id uuid,p_data jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_color text;
begin
  v_result:=public.matrix_v2_admin_save_before_b4f118(p_kind,p_id,p_data);
  if upper(trim(p_kind))='SHIFT' and coalesce(trim(p_data->>'color'),'')<>'' then
    v_color:=upper(trim(p_data->>'color'));
    if v_color !~ '^#[0-9A-F]{6}$' then raise exception 'INVALID_SHIFT_COLOR'; end if;
    update public.matrix_shift_templates_v2
    set color=v_color,updated_at=now()
    where id=(v_result->>'id')::uuid;
  end if;
  return v_result;
end;
$$;

revoke all on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) from public,anon;
grant execute on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) to authenticated,service_role;

alter function public.matrix_v2_publication_readiness_uat_v2(date,date)
  rename to matrix_v2_publication_readiness_before_b4f115;

create function public.matrix_v2_publication_readiness_uat_v2(
  p_effective_from date,p_schedule_month date
)
returns jsonb
language plpgsql
stable
security definer
set search_path=''
as $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_default_scenario uuid;
  v_shift_blockers jsonb:='[]'::jsonb;
  v_blockers jsonb:='[]'::jsonb;
begin
  v_base:=public.matrix_v2_publication_readiness_before_b4f115(p_effective_from,p_schedule_month);
  v_matrix:=nullif(v_base->>'matrixVersionId','')::uuid;
  select scenario.id into v_default_scenario
  from public.matrix_scenarios_v2 scenario
  where scenario.matrix_version_id=v_matrix and scenario.active and scenario.is_default
  order by scenario.sort_order,scenario.id limit 1;

  if v_default_scenario is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'code','SHIFT_BASE_STAFFING_REQUIRED',
      'shiftTemplateId',shift_row.id,
      'shiftCode',shift_row.code,
      'shiftName',shift_row.name,
      'locationId',shift_row.location_id,
      'startsAt',to_char(shift_row.starts_at,'HH24:MI'),
      'endsAt',to_char(shift_row.ends_at,'HH24:MI'),
      'endsNextDay',shift_row.ends_next_day,
      'message',format('%s • %s • %s–%s: uzupełnij obsadę albo wyłącz zmianę.',location_row.name,shift_row.name,to_char(shift_row.starts_at,'HH24:MI'),to_char(shift_row.ends_at,'HH24:MI'))
    ) order by location_row.sort_order,shift_row.sort_order,shift_row.id),'[]'::jsonb)
    into v_shift_blockers
    from public.matrix_shift_templates_v2 shift_row
    join public.matrix_locations_v2 location_row
      on location_row.id=shift_row.location_id and location_row.matrix_version_id=shift_row.matrix_version_id
    where shift_row.matrix_version_id=v_matrix and shift_row.active
      and not exists(
        select 1 from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix
          and staffing.scenario_id=v_default_scenario
          and staffing.shift_template_id=shift_row.id
          and staffing.active and staffing.operation='SET'
          and staffing.count_value>=1
      );
  end if;

  v_blockers:=coalesce(v_base->'blockers','[]'::jsonb)||v_shift_blockers;
  return v_base||jsonb_build_object('ready',jsonb_array_length(v_blockers)=0,'blockers',v_blockers);
end;
$$;

revoke all on function public.matrix_v2_publication_readiness_uat_v2(date,date) from public,anon;
grant execute on function public.matrix_v2_publication_readiness_uat_v2(date,date) to authenticated,service_role;

comment on column public.matrix_shift_templates_v2.color is
  'B4F-118: versioned #RRGGBB marker shared by settings, exports and schedule UI.';
