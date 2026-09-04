-- UAT only: one user-facing source of role semantics.
-- Exactly one active primary role is required at publication. Every active
-- non-primary role is normalized to BACKUP regardless of the legacy payload.

create or replace function solver_private.matrix_employee_role_semantics_uat_v1()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.is_primary then
    new.assignment_mode := 'STANDARD';
    new.backup_priority := greatest(1, least(999, coalesce(new.backup_priority, 100)));
  else
    new.assignment_mode := 'BACKUP';
    new.backup_priority := greatest(1, least(999, coalesce(new.backup_priority, 100)));
  end if;
  return new;
end;
$$;

revoke all on function solver_private.matrix_employee_role_semantics_uat_v1()
  from public, anon, authenticated;

drop trigger if exists matrix_employee_role_semantics_uat_v1
  on public.matrix_employee_roles_v2;
create trigger matrix_employee_role_semantics_uat_v1
before insert or update of is_primary, assignment_mode, backup_priority
on public.matrix_employee_roles_v2
for each row execute function solver_private.matrix_employee_role_semantics_uat_v1();

-- Do not rewrite published history. The current working configuration is the
-- only version being prepared for the owner's next UAT cycle.
update public.matrix_employee_roles_v2 role_link
set assignment_mode = case when role_link.is_primary then 'STANDARD' else 'BACKUP' end,
    backup_priority = greatest(1, least(999, coalesce(role_link.backup_priority, 100))),
    updated_at = now()
from public.matrix_versions version_row
where version_row.id = role_link.matrix_version_id
  and version_row.status = 'DRAFT'
  and role_link.assignment_mode is distinct from
    case when role_link.is_primary then 'STANDARD' else 'BACKUP' end;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'matrix_employee_roles_v2_primary_or_fallback_check'
      and conrelid = 'public.matrix_employee_roles_v2'::regclass
  ) then
    alter table public.matrix_employee_roles_v2
      add constraint matrix_employee_roles_v2_primary_or_fallback_check
      check (
        (is_primary and assignment_mode = 'STANDARD')
        or (not is_primary and assignment_mode = 'BACKUP')
      ) not valid;
  end if;
end;
$$;

alter function public.matrix_v2_publication_readiness_uat_v2(date,date)
  rename to matrix_v2_publication_readiness_before_simple_roles_uat_v1;

create function public.matrix_v2_publication_readiness_uat_v2(
  p_effective_from date,
  p_schedule_month date
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_base jsonb;
  v_matrix uuid;
  v_extra jsonb := '[]'::jsonb;
  v_blockers jsonb := '[]'::jsonb;
begin
  v_base := public.matrix_v2_publication_readiness_before_simple_roles_uat_v1(
    p_effective_from,
    p_schedule_month
  );
  v_matrix := nullif(v_base->>'matrixVersionId','')::uuid;

  select coalesce(jsonb_agg(problem order by employee_no),'[]'::jsonb)
  into v_extra
  from (
    select employee.employee_no,
      jsonb_build_object(
        'code','EMPLOYEE_PRIMARY_ROLE_REQUIRED',
        'employeeId',profile.employee_id,
        'employeeNo',employee.employee_no,
        'employeeName',trim(employee.first_name||' '||employee.last_name),
        'message',format(
          '%s (%s) nie ma dokładnie jednej aktywnej roli podstawowej. Przejdź do Zespół → Role i wybierz rolę podstawową.',
          trim(employee.first_name||' '||employee.last_name),
          employee.employee_no
        )
      ) problem
    from public.matrix_employee_profiles_v2 profile
    join public.employees employee on employee.id = profile.employee_id
    where profile.matrix_version_id = v_matrix
      and profile.active
      and profile.archived_at is null
      and (
        select count(*)
        from public.matrix_employee_roles_v2 role_link
        where role_link.matrix_version_id = profile.matrix_version_id
          and role_link.employee_id = profile.employee_id
          and role_link.active
          and role_link.is_primary
      ) <> 1
  ) invalid_profiles;

  v_blockers := coalesce(v_base->'blockers','[]'::jsonb) || v_extra;
  return v_base || jsonb_build_object(
    'ready',jsonb_array_length(v_blockers) = 0,
    'blockers',v_blockers
  );
end;
$$;

revoke all on function public.matrix_v2_publication_readiness_uat_v2(date,date)
  from public, anon, authenticated;
grant execute on function public.matrix_v2_publication_readiness_uat_v2(date,date)
  to authenticated;

comment on constraint matrix_employee_roles_v2_primary_or_fallback_check
  on public.matrix_employee_roles_v2 is
  'Primary role is STANDARD; every additional role is BACKUP. Added NOT VALID so published history remains immutable.';

notify pgrst, 'reload schema';
