-- A MASTER preview must remain usable while the owner is deliberately
-- resolving a publication conflict. Expose the conflict as data instead of
-- turning the entire employee portal into an error screen.

create or replace function public.uat_master_employee_portal_context_v2(
  p_employee_id uuid,p_month date
) returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_month date:=date_trunc('month',p_month)::date; v_matrix uuid; v_timezone text;
  v_profile public.matrix_employee_profiles_v2%rowtype; v_calendar jsonb; v_preferences jsonb;
  v_publication_conflict boolean:=false;
begin
  perform solver_private.assert_uat_master_persona_v2();
  select matrix.id,matrix.settings->>'timezone' into v_matrix,v_timezone
  from public.matrix_versions matrix where matrix.status in ('ACTIVE','ARCHIVED')
    and matrix.schema_version>=2 and matrix.effective_from<=v_month
  order by matrix.effective_from desc,matrix.version desc limit 1;
  select * into v_profile from public.matrix_employee_profiles_v2 profile
  where profile.matrix_version_id=v_matrix and profile.employee_id=p_employee_id
    and profile.active and profile.archived_at is null;
  if v_profile.id is null then raise exception 'EMPLOYEE_NOT_FOUND'; end if;
  begin
    v_calendar:=public.published_company_calendar_uat_v2(v_month);
  exception when others then
    if sqlerrm='SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION' then
      v_publication_conflict:=true;
      v_calendar:=jsonb_build_object('month',v_month,'assignments','[]'::jsonb,
        'conflict',true);
    else raise;
    end if;
  end;
  v_preferences:=jsonb_build_object(
    'employeeId',p_employee_id,'month',v_month,
    'employee',jsonb_build_object(
      'MORNING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MORNING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'MIDDLE',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='MIDDLE'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL'),
      'EVENING',coalesce((select upper(preference.preference_value->>'level')
        from public.employee_preferences preference where preference.employee_id=p_employee_id
          and preference.status='ACTIVE' and preference.source='GRAFIK_PRO'
          and preference.preference_type='PREFERRED_SHIFT'
          and upper(preference.preference_value->>'period')='EVENING'
          and preference.valid_from<v_month+interval '1 month' and preference.valid_to>=v_month
        order by preference.created_at desc limit 1),'NEUTRAL')),
    'effective',coalesce(solver_private.alpha16_shift_rules_v2(p_employee_id,v_matrix,v_month)->'periods','{}'::jsonb),
    'managerOverrides','{}'::jsonb);
  return jsonb_build_object(
    'employee',jsonb_build_object('id',p_employee_id,'employeeNo',v_profile.employee_no,
      'firstName',v_profile.first_name,'lastName',v_profile.last_name,
      'primaryRole',coalesce((select role.name from public.matrix_employee_roles_v2 grant_row
        join public.matrix_roles_v2 role on role.id=grant_row.role_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active order by grant_row.is_primary desc,role.sort_order limit 1),'—'),
      'locations',coalesce((select jsonb_agg(jsonb_build_object('code',location.code,'name',location.name)
        order by location.sort_order) from public.matrix_employee_locations_v2 grant_row
        join public.matrix_locations_v2 location on location.id=grant_row.location_id
        where grant_row.matrix_version_id=v_matrix and grant_row.employee_id=p_employee_id
          and grant_row.active and (grant_row.standard_allowed or grant_row.overtime_allowed)),'[]'::jsonb)),
    'assignments',coalesce((select jsonb_agg(item.value order by item.value->>'startsAt')
      from jsonb_array_elements(coalesce(v_calendar->'assignments','[]'::jsonb)) item
      where item.value->>'employeeId'=p_employee_id::text),'[]'::jsonb),
    'standby',coalesce((select jsonb_agg(jsonb_build_object('id',standby.id,
      'date',standby.standby_date,'tier',standby.tier,'status',standby.status,
      'roleId',standby.role_id,'roleName',role.name,'activatedShiftId',standby.activated_shift_id)
      order by standby.standby_date,standby.tier)
      from public.published_standby_assignments_v2 standby
      join public.matrix_roles_v2 role on role.id=standby.role_id
      where standby.employee_id=p_employee_id and standby.month=v_month
        and standby.status in ('PLANNED','ACTIVATED','DECLINED')),'[]'::jsonb),
    'attendance','[]'::jsonb,
    'timeConstraints',solver_private.uat_master_employee_constraints_v2(
      p_employee_id,v_month,v_matrix,v_timezone),
    'shiftPreferences',v_preferences,'companyCalendar',v_calendar,
    'publicationConflict',v_publication_conflict,'masterPersona',true
  );
end;
$$;

revoke all on function public.uat_master_employee_portal_context_v2(uuid,date)
  from public,anon,authenticated;
grant execute on function public.uat_master_employee_portal_context_v2(uuid,date)
  to authenticated;

notify pgrst,'reload schema';
