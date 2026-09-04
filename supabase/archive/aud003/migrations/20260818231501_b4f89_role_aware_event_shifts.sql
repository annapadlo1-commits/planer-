-- B4F-89: the operational event editor must only offer shift templates that
-- physically occur in the selected dates and have staffing demand for the
-- selected role. Keep the previous scoped calendar calculation intact and
-- enrich its shift-template contract in a small authenticated wrapper.

alter function public.workforce_calendar_context_uat_v4(date)
  rename to workforce_calendar_context_base_b4f89;

create function public.workforce_calendar_context_uat_v4(p_month date)
returns jsonb
language plpgsql stable security definer set search_path=''
as $$
declare
  v_result jsonb;
  v_matrix uuid;
  v_templates jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  v_result:=public.workforce_calendar_context_base_b4f89(p_month);
  v_matrix:=nullif(v_result->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(
    template.value||jsonb_build_object(
      'roleIds',coalesce((select jsonb_agg(distinct staffing.role_id order by staffing.role_id)
        from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=(template.value->>'id')::uuid),'[]'::jsonb),
      'roleNames',coalesce((select jsonb_agg(distinct role.name order by role.name)
        from public.matrix_staffing_rules_v2 staffing
        join public.matrix_roles_v2 role on role.id=staffing.role_id
          and role.matrix_version_id=v_matrix and role.active
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=(template.value->>'id')::uuid),'[]'::jsonb)
    ) order by template.ordinality
  ),'[]'::jsonb)
  into v_templates
  from jsonb_array_elements(coalesce(v_result->'shiftTemplates','[]'::jsonb))
    with ordinality as template(value,ordinality);

  return jsonb_set(v_result,'{shiftTemplates}',v_templates,true);
end;
$$;

revoke all on function public.workforce_calendar_context_uat_v4(date)
from public,anon,authenticated;
grant execute on function public.workforce_calendar_context_uat_v4(date) to authenticated;

revoke all on function public.workforce_calendar_context_base_b4f89(date)
from public,anon,authenticated;

comment on function public.workforce_calendar_context_uat_v4(date)
is 'B4F-89: scoped workforce calendar with role-aware event shift templates.';

create or replace function public.workforce_calendar_event_range_save_uat_v2(
  p_month date,p_start_date date,p_end_date date,p_event_kind text,
  p_title text,p_description text,p_location_id uuid,
  p_demands jsonb default '[]'::jsonb,p_hot_limits jsonb default '[]'::jsonb
) returns jsonb
language plpgsql security definer set search_path=''
as $$
declare
  v_date date;
  v_result jsonb;
  v_rows jsonb:='[]'::jsonb;
  v_day_demands jsonb;
  v_matrix uuid;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not public.can_manage_plans() then raise exception 'FORBIDDEN'; end if;
  if p_start_date is null or p_end_date is null or p_end_date<p_start_date then
    raise exception 'INVALID_DATE_RANGE';
  end if;
  if p_start_date<date_trunc('month',p_month)::date
    or p_end_date>=(date_trunc('month',p_month)+interval '1 month')::date then
    raise exception 'EVENT_RANGE_OUTSIDE_MONTH';
  end if;
  if p_end_date-p_start_date>30 then raise exception 'EVENT_RANGE_TOO_LONG'; end if;

  select matrix.id into v_matrix from public.matrix_versions matrix
  where matrix.status='ACTIVE' and matrix.schema_version>=2
    and matrix.effective_from<=date_trunc('month',p_month)::date
    and (matrix.effective_to is null or matrix.effective_to>=(date_trunc('month',p_month)+interval '1 month - 1 day')::date)
  order by matrix.effective_from desc,matrix.version desc limit 1;

  for v_date in select generate_series(p_start_date,p_end_date,interval '1 day')::date loop
    if p_event_kind='EVENT' then
      select coalesce(jsonb_agg(demand.value order by demand.ordinality),'[]'::jsonb)
      into v_day_demands
      from jsonb_array_elements(coalesce(p_demands,'[]'::jsonb))
        with ordinality as demand(value,ordinality)
      join public.matrix_shift_templates_v2 template
        on template.id=(demand.value->>'shiftTemplateId')::uuid
        and template.matrix_version_id=v_matrix and template.active
        and template.location_id=p_location_id
        and extract(isodow from v_date)::integer=any(template.day_mask)
      where exists(select 1 from public.matrix_staffing_rules_v2 staffing
        where staffing.matrix_version_id=v_matrix and staffing.active
          and staffing.shift_template_id=template.id
          and staffing.role_id=(demand.value->>'roleId')::uuid);
      if jsonb_array_length(v_day_demands)=0 then continue; end if;
    else
      v_day_demands:='[]'::jsonb;
    end if;

    v_result:=public.workforce_calendar_event_save_uat_v2(
      null,p_month,v_date,p_event_kind,p_title,p_description,p_location_id,
      v_day_demands,p_hot_limits
    );
    v_rows:=v_rows||jsonb_build_array(jsonb_build_object(
      'date',v_date,'id',v_result->>'id','saved',true,
      'demandCount',jsonb_array_length(v_day_demands)
    ));
  end loop;

  if p_event_kind='EVENT' and jsonb_array_length(v_rows)=0 then
    raise exception 'EVENT_HAS_NO_ACTIVE_ROLE_SHIFTS';
  end if;
  return jsonb_build_object('saved',true,'startDate',p_start_date,'endDate',p_end_date,
    'count',jsonb_array_length(v_rows),'events',v_rows);
end;
$$;

revoke all on function public.workforce_calendar_event_range_save_uat_v2(
  date,date,date,text,text,text,uuid,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.workforce_calendar_event_range_save_uat_v2(
  date,date,date,text,text,text,uuid,jsonb,jsonb) to authenticated,service_role;

notify pgrst,'reload schema';
