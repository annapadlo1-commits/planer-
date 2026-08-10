-- B4/B5 UAT corrective migration: the recovery candidate list must enforce
-- the same Matrix-driven daily-shift and first/last sequence rules as the
-- final leader-variant validator. A green candidate must be genuinely savable.

create or replace function solver_private.recovery_candidate_snapshot_uat_v1(
  p_month date,p_shift_id uuid,p_role_id uuid,p_duty_id uuid,p_excluded_employee_id uuid
) returns jsonb language sql stable security definer set search_path=''
as $$
  with target as (
    select shift.*,role.matrix_version_id
    from public.plan_shifts_v2 shift
    join public.matrix_roles_v2 role on role.id=p_role_id
    where shift.id=p_shift_id
  ), candidates as (
    select profile.employee_id,profile.employee_no,
      trim(concat(profile.first_name,' ',profile.last_name)) name,
      profile.nominal_monthly_minutes,profile.maximum_monthly_minutes,profile.maximum_weekly_minutes,
      coalesce(standby.tier,10) priority,standby.tier,
      standby.id is not null standby_candidate,
      exists(select 1 from public.matrix_employee_locations_v2 location_grant,target
        where location_grant.matrix_version_id=profile.matrix_version_id
          and location_grant.employee_id=profile.employee_id
          and location_grant.location_id=target.location_id and location_grant.active
          and location_grant.standard_allowed) location_ok,
      (p_duty_id is null or exists(select 1 from public.matrix_employee_duties_v2 duty_grant
        where duty_grant.matrix_version_id=profile.matrix_version_id
          and duty_grant.employee_id=profile.employee_id and duty_grant.duty_id=p_duty_id
          and duty_grant.active)) duty_ok,
      exists(select 1 from public.employee_time_constraints_v2 constraint_row,target
        where constraint_row.employee_id=profile.employee_id and constraint_row.status='ACTIVE'
          and constraint_row.constraint_kind in ('UNAVAILABLE','LEAVE','SICKNESS')
          and constraint_row.time_range && tstzrange(target.starts_at,target.ends_at,'[)')) hard_blocked,
      exists(select 1 from public.plan_assignments_v2 existing
        join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and tstzrange(existing_shift.starts_at,existing_shift.ends_at,'[)') && tstzrange(target.starts_at,target.ends_at,'[)')) has_overlap,
      solver_private.variant_primary_conflict_reasons_uat_v2(
        target.variant_id,profile.employee_id,target.id
      ) primary_conflicts,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        where existing.employee_id=profile.employee_id),0) month_minutes,
      coalesce((select sum(extract(epoch from (existing_shift.ends_at-existing_shift.starts_at))/60)::integer
        from public.plan_assignments_v2 existing join public.plan_shifts_v2 existing_shift on existing_shift.id=existing.shift_id
        join solver_private.recovery_published_variants_uat_v1(p_month) published on published.variant_id=existing.variant_id
        cross join target where existing.employee_id=profile.employee_id
          and extract(isoyear from existing_shift.shift_date)=extract(isoyear from target.shift_date)
          and extract(week from existing_shift.shift_date)=extract(week from target.shift_date)),0) week_minutes,
      coalesce((select rate.contract_type from public.employee_pay_rates_v2 rate,target
        where rate.employee_id=profile.employee_id and rate.active and rate.valid_from<=target.shift_date
          and (rate.valid_to is null or rate.valid_to>=target.shift_date)
        order by rate.valid_from desc limit 1),
        (select hr.contract_type from public.employee_hr_profiles hr
          where hr.employee_id=profile.employee_id),'INNE') contract_type
    from public.matrix_employee_profiles_v2 profile
    cross join target
    join public.matrix_employee_roles_v2 role_grant on role_grant.matrix_version_id=profile.matrix_version_id
      and role_grant.employee_id=profile.employee_id and role_grant.role_id=p_role_id and role_grant.active
    left join public.published_standby_assignments_v2 standby on standby.month=date_trunc('month',p_month)::date
      and standby.standby_date=target.shift_date and standby.role_id=p_role_id
      and standby.employee_id=profile.employee_id and standby.status='PLANNED'
    where profile.matrix_version_id=target.matrix_version_id and profile.active and profile.archived_at is null
      and (profile.employment_start is null or profile.employment_start<=target.shift_date)
      and (profile.employment_end is null or profile.employment_end>=target.shift_date)
      and profile.employee_id is distinct from p_excluded_employee_id
  ), evaluated as (
    select *,location_ok and duty_ok and not hard_blocked and not has_overlap
      and not (primary_conflicts && array['ONE_PRIMARY_SHIFT_PER_DAY','CONSECUTIVE_SHIFT_SEQUENCE']::text[]) eligible,
      to_jsonb(array_remove(array[
        case when not location_ok then 'Brak uprawnienia do lokalu' end,
        case when not duty_ok then 'Brak wymaganego obowiązku' end,
        case when hard_blocked then 'Twarda niedostępność, urlop lub L4' end,
        case when has_overlap then 'Ma już zmianę w tym czasie' end,
        case when 'ONE_PRIMARY_SHIFT_PER_DAY'=any(primary_conflicts) then
          'Osiągnięty dzienny limit zmian z konfiguracji firmy' end,
        case when 'CONSECUTIVE_SHIFT_SEQUENCE'=any(primary_conflicts) then
          'Niedozwolona sekwencja ostatnia zmiana dnia → pierwsza zmiana następnego dnia' end,
        case when maximum_weekly_minutes>0 and week_minutes>=maximum_weekly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit tygodniowy UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit tygodniowy — wymaga świadomego wyjątku' end end,
        case when maximum_monthly_minutes>0 and month_minutes>=maximum_monthly_minutes then
          case when contract_type in ('UMOWA_O_PRACE','CZESC_ETATU')
            then 'Osiągnięty limit miesięczny UoP — wymaga zgody pracownika, potwierdzenia właściciela i kontroli zgodności czasu pracy'
            else 'Osiągnięty uzgodniony limit miesięczny — wymaga świadomego wyjątku' end end
      ]::text[],null)) reasons
    from candidates
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'employeeId',employee_id,'employeeNo',employee_no,'name',name,
    'source',case when standby_candidate then 'STANDBY' else 'ACTIVE_TEAM' end,
    'tier',tier,'priority',case when eligible then priority else 50 end,'eligible',eligible,
    'locationOk',location_ok,'dutyOk',duty_ok,'hardBlocked',hard_blocked,'overlaps',has_overlap,
    'primaryConflicts',to_jsonb(primary_conflicts),'reasons',reasons,'contractType',contract_type,
    'monthMinutes',month_minutes,'weekMinutes',week_minutes,
    'nominalMonthlyMinutes',nominal_monthly_minutes,'maximumMonthlyMinutes',maximum_monthly_minutes,
    'maximumWeeklyMinutes',maximum_weekly_minutes
  ) order by eligible desc,case when standby_candidate then tier else 10 end,
    abs(nominal_monthly_minutes-month_minutes),name),'[]'::jsonb)
  from (select * from evaluated order by eligible desc,priority,name limit 24) ranked
$$;

revoke all on function solver_private.recovery_candidate_snapshot_uat_v1(date,uuid,uuid,uuid,uuid)
  from public,anon,authenticated;

comment on function solver_private.recovery_candidate_snapshot_uat_v1(date,uuid,uuid,uuid,uuid) is
  'Recovery candidate snapshot with the same daily and adjacent-sequence hard rules as leader-variant validation.';

notify pgrst,'reload schema';
