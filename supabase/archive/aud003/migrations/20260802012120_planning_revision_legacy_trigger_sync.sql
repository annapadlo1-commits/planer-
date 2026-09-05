-- Synchronize legacy planning inputs that were added to the final foundation
-- list after the disposable branch had already applied its first revision.

do $$
declare
  v_table text;
begin
  foreach v_table in array array[
    'employee_availability','locations','monthly_budgets'
  ] loop
    if to_regclass(format('public.%I',v_table)) is null then
      raise exception 'PLANNING_REVISION_TABLE_MISSING: %',v_table;
    end if;
    execute format(
      'drop trigger if exists planning_revision_v2_bump on public.%I',v_table
    );
    execute format(
      'create trigger planning_revision_v2_bump '
      'before insert or update or delete or truncate on public.%I '
      'for each statement execute function solver_private.bump_planning_revision_v2()',
      v_table
    );
  end loop;
end;
$$;
