-- Strip obsolete Alpha genetic-algorithm metadata when cloning a v2 draft.
-- Historical Matrix versions remain untouched; future drafts contain only
-- options understood by the CP-SAT contract.

do $$
declare
  v_definition text:=pg_get_functiondef(
    'public.matrix_v2_create_draft(text)'::regprocedure
  );
  v_old text:='    s.solver_code,s.solver_options,s.legacy_weights,s.sort_order,s.active';
  v_new text:='    s.solver_code,s.solver_options-array[
      ''legacyPopulationSize'',''legacyGenerations'',''legacyMutationRate''
    ],s.legacy_weights,s.sort_order,s.active';
begin
  if position(v_old in v_definition)>0 then
    execute replace(v_definition,v_old,v_new);
  elsif position('legacyPopulationSize' in v_definition)=0 then
    raise exception 'MATRIX_DRAFT_SOLVER_OPTION_PATCH_NOT_FOUND';
  end if;
end;
$$;
