-- Authoritative date guardrails for every caller, including imports and RPCs.

create or replace function public.matrix_employee_profile_date_guard_uat_v2()
returns trigger language plpgsql set search_path=''
as $$
begin
  if new.employment_start is not null and (
    new.employment_start < current_date - interval '50 years'
    or new.employment_start > current_date + interval '2 years'
  ) then raise exception 'EMPLOYMENT_START_OUTSIDE_ALLOWED_HORIZON'; end if;
  if new.employment_end is not null and (
    new.employment_end < coalesce(new.employment_start,new.employment_end)
    or new.employment_end > current_date + interval '10 years'
  ) then raise exception 'EMPLOYMENT_END_OUTSIDE_ALLOWED_HORIZON'; end if;
  return new;
end;
$$;

drop trigger if exists matrix_employee_profile_date_guard_uat_v2
  on public.matrix_employee_profiles_v2;
create trigger matrix_employee_profile_date_guard_uat_v2
before insert or update of employment_start,employment_end
on public.matrix_employee_profiles_v2
for each row execute function public.matrix_employee_profile_date_guard_uat_v2();

create or replace function public.employee_pay_rate_date_guard_uat_v2()
returns trigger language plpgsql set search_path=''
as $$
declare v_start date; v_end date;
begin
  select profile.employment_start,profile.employment_end into v_start,v_end
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version on version.id=profile.matrix_version_id
  where profile.employee_id=new.employee_id
  order by (version.status='DRAFT') desc,version.version desc limit 1;
  if not found then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;
  if new.valid_from < current_date - interval '50 years'
    or new.valid_from > current_date + interval '2 years' then
    raise exception 'PAY_RATE_DATE_OUTSIDE_ALLOWED_HORIZON';
  end if;
  if v_start is not null and new.valid_from<v_start then
    raise exception 'PAY_RATE_BEFORE_EMPLOYMENT';
  end if;
  if v_end is not null and (
    new.valid_from>v_end or new.valid_to is null or new.valid_to>v_end
  ) then raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT'; end if;
  if new.valid_to is not null and (
    new.valid_to<new.valid_from
    or new.valid_to>current_date + interval '10 years'
  ) then raise exception 'PAY_RATE_END_OUTSIDE_ALLOWED_HORIZON'; end if;
  return new;
end;
$$;

drop trigger if exists employee_pay_rate_date_guard_uat_v2
  on public.employee_pay_rates_v2;
create trigger employee_pay_rate_date_guard_uat_v2
before insert or update of employee_id,valid_from,valid_to
on public.employee_pay_rates_v2
for each row execute function public.employee_pay_rate_date_guard_uat_v2();

revoke all on function public.matrix_employee_profile_date_guard_uat_v2()
  from public,anon,authenticated;
revoke all on function public.employee_pay_rate_date_guard_uat_v2()
  from public,anon,authenticated;

notify pgrst,'reload schema';
