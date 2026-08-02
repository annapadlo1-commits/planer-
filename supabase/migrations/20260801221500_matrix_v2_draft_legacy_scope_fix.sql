-- Restrict legacy compatibility cloning to the selected base Matrix version.
-- Earlier drafts joined matrix_role_functions and matrix_demand across every
-- historical version, so the second publish/create cycle could duplicate all
-- demand rows. The source migration is fixed for clean installs; this guarded
-- replacement repairs development databases that already ran the old body.

do $$
declare
  v_definition text;
  v_old text;
  v_new text;
begin
  v_definition:=pg_get_functiondef(
    'public.matrix_v2_create_draft(text)'::regprocedure
  );

  if position(
    'where old_role.matrix_version_id=v_active.id' in v_definition
  )=0 then
    v_old:='    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code;

  insert into public.matrix_demand(';
    v_new:='    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_role.matrix_version_id=v_active.id
    and old_function.matrix_version_id=v_active.id;

  insert into public.matrix_demand(';
    if position(v_old in v_definition)=0 then
      raise exception 'MATRIX_DRAFT_ROLE_FUNCTION_SCOPE_PATCH_NOT_FOUND';
    end if;
    v_definition:=replace(v_definition,v_old,v_new);
  end if;

  if position(
    'where old_shift.matrix_version_id=v_active.id' in v_definition
  )=0 then
    v_old:='  left join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code;

  insert into public.matrix_employee_roles(';
    v_new:='  left join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_shift.matrix_version_id=v_active.id
    and old_role.matrix_version_id=v_active.id
    and (old_function.id is null
      or old_function.matrix_version_id=v_active.id);

  insert into public.matrix_employee_roles(';
    if position(v_old in v_definition)=0 then
      raise exception 'MATRIX_DRAFT_DEMAND_SCOPE_PATCH_NOT_FOUND';
    end if;
    v_definition:=replace(v_definition,v_old,v_new);
  end if;

  v_old:='    s.solver_code,s.solver_options,s.legacy_weights,s.sort_order,s.active';
  if position(v_old in v_definition)>0 then
    v_new:='    s.solver_code,s.solver_options-array[
      ''legacyPopulationSize'',''legacyGenerations'',''legacyMutationRate''
    ],s.legacy_weights,s.sort_order,s.active';
    v_definition:=replace(v_definition,v_old,v_new);
  end if;

  execute v_definition;
end;
$$;

comment on function public.matrix_v2_create_draft(text) is
  'Creates one editable Matrix v2 draft by cloning only the selected active version.';
