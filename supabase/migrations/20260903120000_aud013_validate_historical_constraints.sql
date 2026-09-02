-- AUD-2026-09-01-013.
-- Future deployment target: UAT nhthrtpkfpmufmrmdyjg only; never production.
-- Validation is forward-only and does not rewrite historical data. The
-- transaction fails before either ALTER if a violating row is present.

begin;

do $$
begin
  if exists(
    select 1
    from public.matrix_employee_roles_v2 role_link
    where not (
      (role_link.is_primary and role_link.assignment_mode='STANDARD')
      or (not role_link.is_primary and role_link.assignment_mode='BACKUP')
    )
  ) then
    raise exception 'AUD013_ROLE_SEMANTICS_VIOLATIONS';
  end if;

  if exists(
    select 1
    from public.matrix_staffing_rules_v2 rule_row
    where rule_row.active and rule_row.operation='SET'
      and rule_row.count_value<1
  ) then
    raise exception 'AUD013_STAFFING_RULE_VIOLATIONS';
  end if;
end;
$$;

alter table public.matrix_employee_roles_v2
  validate constraint matrix_employee_roles_v2_primary_or_fallback_check;

alter table public.matrix_staffing_rules_v2
  validate constraint matrix_staffing_active_set_positive_uat006;

do $$
begin
  if (
    select count(*)
    from pg_catalog.pg_constraint constraint_row
    where constraint_row.convalidated
      and (
        (
          constraint_row.conname=
            'matrix_employee_roles_v2_primary_or_fallback_check'
          and constraint_row.conrelid=
            'public.matrix_employee_roles_v2'::regclass
        )
        or (
          constraint_row.conname='matrix_staffing_active_set_positive_uat006'
          and constraint_row.conrelid=
            'public.matrix_staffing_rules_v2'::regclass
        )
      )
  )<>2 then
    raise exception 'AUD013_CONSTRAINT_VALIDATION_INCOMPLETE';
  end if;
end;
$$;

commit;
