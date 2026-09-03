-- UAT repair: employee-profile rows have an additional immutable guard.
-- During a legitimate matrix-version DELETE ... ON DELETE CASCADE, PostgreSQL
-- removes the parent before the profile DELETE trigger can read its status.
-- Permit only that DELETE path. INSERT and UPDATE still fail closed when the
-- parent is missing, and every operation remains blocked for non-draft parents.

create or replace function solver_private.guard_matrix_employee_profile_v2()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_matrix_id uuid:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;
  v_status text;
begin
  select mv.status into v_status
  from public.matrix_versions mv
  where mv.id=v_matrix_id;

  if v_status is null then
    -- A parent DELETE with ON DELETE CASCADE reaches this trigger after the
    -- parent row disappears. Foreign keys still prevent a direct orphan.
    if tg_op='DELETE' then return old; end if;
    raise exception 'MATRIX_WORKFORCE_VERSION_NOT_FOUND';
  end if;

  if v_status<>'DRAFT' then
    raise exception 'MATRIX_WORKFORCE_VERSION_IMMUTABLE';
  end if;

  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

comment on function solver_private.guard_matrix_employee_profile_v2() is
  'Protects immutable workforce profiles and permits FK cascade deletes of draft profiles.';

notify pgrst,'reload schema';
