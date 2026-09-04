-- F4 / P0: one database invariant protects both directions of the
-- employment-period <-> pay-rate relationship.  UI/RPC checks remain useful
-- for early feedback, but table triggers are the authoritative boundary for
-- RPCs, imports and privileged direct writes.

create or replace function solver_private.assert_employment_pay_rate_period_uat_v1(
  p_employee_id uuid,
  p_employment_start date,
  p_employment_end date,
  p_rate_valid_from date,
  p_rate_valid_to date
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_employee_id is null then
    raise exception 'EMPLOYEE_REQUIRED';
  end if;

  -- A non-null rate start selects the rate -> employment direction.
  if p_rate_valid_from is not null then
    if (p_employment_start is not null
        and p_rate_valid_from < p_employment_start)
      or (p_employment_end is not null and (
        p_rate_valid_from > p_employment_end
        or p_rate_valid_to is null
        or p_rate_valid_to > p_employment_end
      )) then
      raise exception 'PAY_RATE_OUTSIDE_EMPLOYMENT';
    end if;
    return;
  end if;

  -- A null rate start selects the employment -> all stored rates direction.
  -- Inactive rows are deliberate history and must remain internally valid too.
  if exists(
    select 1
    from public.employee_pay_rates_v2 rate
    where rate.employee_id = p_employee_id
      and (
        (p_employment_start is not null
          and rate.valid_from < p_employment_start)
        or (p_employment_end is not null and (
          rate.valid_from > p_employment_end
          or rate.valid_to is null
          or rate.valid_to > p_employment_end
        ))
      )
  ) then
    raise exception 'EMPLOYMENT_DATES_CONFLICT_PAY_RATES';
  end if;
end;
$$;

revoke all on function
  solver_private.assert_employment_pay_rate_period_uat_v1(
    uuid,date,date,date,date
  ) from public, anon, authenticated, service_role;

-- Abort instead of installing a guard over already-invalid data.  The active
-- Matrix draft is authoritative while it exists; otherwise the newest active
-- or archived Matrix profile is used, matching the established finance path.
do $$
declare
  v_employee record;
begin
  if exists(
    select 1
    from public.employee_pay_rates_v2 rate
    where not exists(
      select 1
      from public.matrix_employee_profiles_v2 profile
      where profile.employee_id = rate.employee_id
    )
  ) then
    raise exception 'EMPLOYEE_PROFILE_REQUIRED';
  end if;

  for v_employee in
    select employee.id, current_profile.employment_start,
      current_profile.employment_end
    from public.employees employee
    join lateral (
      select profile.employment_start, profile.employment_end
      from public.matrix_employee_profiles_v2 profile
      join public.matrix_versions version
        on version.id = profile.matrix_version_id
      where profile.employee_id = employee.id
      order by case version.status
        when 'DRAFT' then 0
        when 'ACTIVE' then 1
        else 2
      end, version.version desc
      limit 1
    ) current_profile on true
    where exists(
      select 1 from public.employee_pay_rates_v2 rate
      where rate.employee_id = employee.id
    )
  loop
    perform solver_private.assert_employment_pay_rate_period_uat_v1(
      v_employee.id,
      v_employee.employment_start,
      v_employee.employment_end,
      null,
      null
    );
  end loop;
end;
$$;

create or replace function solver_private.guard_employee_pay_rate_employment_uat_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_employment_start date;
  v_employment_end date;
begin
  if new.valid_from < current_date - interval '50 years'
    or new.valid_from > current_date + interval '2 years' then
    raise exception 'PAY_RATE_DATE_OUTSIDE_ALLOWED_HORIZON';
  end if;
  if new.valid_to is not null and (
    new.valid_to < new.valid_from
    or new.valid_to > current_date + interval '10 years'
  ) then
    raise exception 'PAY_RATE_END_OUTSIDE_ALLOWED_HORIZON';
  end if;

  -- Both directions serialize on the stable employee identity.  This prevents
  -- a concurrent rate write and employment-date edit from passing on stale
  -- observations of each other.
  perform 1
  from public.employees employee
  where employee.id = new.employee_id
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  select profile.employment_start, profile.employment_end
  into v_employment_start, v_employment_end
  from public.matrix_employee_profiles_v2 profile
  join public.matrix_versions version
    on version.id = profile.matrix_version_id
  where profile.employee_id = new.employee_id
  order by case version.status
    when 'DRAFT' then 0
    when 'ACTIVE' then 1
    else 2
  end, version.version desc
  limit 1;
  if not found then raise exception 'EMPLOYEE_PROFILE_REQUIRED'; end if;

  perform solver_private.assert_employment_pay_rate_period_uat_v1(
    new.employee_id,
    v_employment_start,
    v_employment_end,
    new.valid_from,
    new.valid_to
  );
  return new;
end;
$$;

create or replace function solver_private.guard_employee_profile_pay_rates_uat_v1()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.employment_start is not null and (
    new.employment_start < current_date - interval '50 years'
    or new.employment_start > current_date + interval '2 years'
  ) then
    raise exception 'EMPLOYMENT_START_OUTSIDE_ALLOWED_HORIZON';
  end if;
  if new.employment_end is not null and (
    new.employment_end < coalesce(new.employment_start,new.employment_end)
    or new.employment_end > current_date + interval '10 years'
  ) then
    raise exception 'EMPLOYMENT_END_OUTSIDE_ALLOWED_HORIZON';
  end if;

  perform 1
  from public.employees employee
  where employee.id = new.employee_id
  for update;
  if not found then raise exception 'EMPLOYEE_NOT_FOUND'; end if;

  perform solver_private.assert_employment_pay_rate_period_uat_v1(
    new.employee_id,
    new.employment_start,
    new.employment_end,
    null,
    null
  );
  return new;
end;
$$;

revoke all on function
  solver_private.guard_employee_pay_rate_employment_uat_v1(),
  solver_private.guard_employee_profile_pay_rates_uat_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists employee_pay_rate_date_guard_uat_v2
  on public.employee_pay_rates_v2;
drop trigger if exists employee_pay_rate_employment_guard_uat_v1
  on public.employee_pay_rates_v2;
create trigger employee_pay_rate_employment_guard_uat_v1
before insert or update of employee_id,valid_from,valid_to
on public.employee_pay_rates_v2
for each row execute function
  solver_private.guard_employee_pay_rate_employment_uat_v1();

drop trigger if exists matrix_employee_profile_date_guard_uat_v2
  on public.matrix_employee_profiles_v2;
drop trigger if exists matrix_employee_profile_pay_rate_guard_uat_v1
  on public.matrix_employee_profiles_v2;
create trigger matrix_employee_profile_pay_rate_guard_uat_v1
before insert or update of employee_id,employment_start,employment_end
on public.matrix_employee_profiles_v2
for each row execute function
  solver_private.guard_employee_profile_pay_rates_uat_v1();

drop function if exists public.employee_pay_rate_date_guard_uat_v2();
drop function if exists public.matrix_employee_profile_date_guard_uat_v2();

-- The application writes through matrix_v2_employee_save_uat_v4.  Alpha16 is
-- retained only as an internal compatibility implementation for newer
-- SECURITY DEFINER wrappers, and is no longer a remotely callable write API.
revoke all on function public.matrix_v2_employee_save_alpha16(uuid,jsonb)
  from public, anon, authenticated, service_role;
comment on function public.matrix_v2_employee_save_alpha16(uuid,jsonb) is
  'Internal legacy employee writer. Remote callers must use matrix_v2_employee_save_uat_v4; F4 employment/pay-rate integrity is enforced by table triggers.';

notify pgrst, 'reload schema';
