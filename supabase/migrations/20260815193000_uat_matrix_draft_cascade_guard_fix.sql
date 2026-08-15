-- UAT repair: deleting a draft parent cascades into versioned child tables.
-- PostgreSQL removes the parent row before firing child DELETE guards, so the
-- guard must allow only this orphan-free DELETE path while still rejecting
-- INSERT/UPDATE operations whose matrix version does not exist.

create or replace function solver_private.guard_matrix_child_immutable_v2()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_matrix_id uuid;
  v_status text;
begin
  if tg_op='UPDATE' and old.matrix_version_id<>new.matrix_version_id then
    raise exception 'MATRIX_VERSION_REPARENT_FORBIDDEN';
  end if;

  v_matrix_id:=case when tg_op='DELETE'
    then old.matrix_version_id else new.matrix_version_id end;

  select mv.status into v_status
  from public.matrix_versions mv
  where mv.id=v_matrix_id
  for share;

  if v_status is null then
    -- A parent DELETE with ON DELETE CASCADE reaches child triggers after the
    -- parent row is no longer visible. Direct orphaning remains impossible by
    -- foreign keys; INSERT and UPDATE keep failing closed below.
    if tg_op='DELETE' then return old; end if;
    raise exception 'MATRIX_VERSION_NOT_FOUND';
  end if;

  if v_status<>'DRAFT' then raise exception 'MATRIX_VERSION_IMMUTABLE'; end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end;
$$;

comment on function solver_private.guard_matrix_child_immutable_v2() is
  'Protects immutable published matrix children and permits FK cascade deletes of draft children.';

notify pgrst,'reload schema';
