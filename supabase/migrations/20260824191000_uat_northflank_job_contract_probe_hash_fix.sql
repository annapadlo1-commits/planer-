-- Keep the Gate A probe strict: use the same canonical slot-to-employee map
-- hash as validate_variant_v2 instead of a probe-only placeholder.
do $repair$
declare
  v_oid regprocedure:=
    'public.solver_contract_parity_probe_uat_v1(jsonb,text)'::regprocedure;
  v_definition text;
  v_original text;
begin
  select pg_get_functiondef(v_oid) into v_definition;
  if position('v_solution_hash text;' in v_definition)=0 then
    v_definition:=replace(
      v_definition,
      'v_snapshot_hash text;',
      'v_snapshot_hash text;
  v_solution_hash text;'
    );
  end if;

  if position('solver_private.canonical_json_v2(payload)' in v_definition)=0 then
    v_original:=v_definition;
    v_definition:=replace(
      v_definition,
      'from jsonb_array_elements(v_snapshot->''slots'')
      with ordinality slot(value,ordinality);',
      'from jsonb_array_elements(v_snapshot->''slots'')
      with ordinality slot(value,ordinality);

    with slots as (
      select value->>''slotId'' slot_id
      from jsonb_array_elements(v_snapshot->''slots'')
    ), selected_map as (
      select jsonb_object_agg(
        slot_id,to_jsonb(null::text) order by slot_id
      ) payload from slots
    )
    select encode(extensions.digest(convert_to(
      solver_private.canonical_json_v2(payload),''UTF8''
    ),''sha256''),''hex'') into v_solution_hash
    from selected_map;'
    );
    if v_definition=v_original then
      raise exception 'NFJOB_CONTRACT_PROBE_HASH_INSERT_MISMATCH';
    end if;
  end if;

  if position('v_run_id::text||''|''||v_index::text' in v_definition)>0 then
    v_definition:=replace(
      v_definition,
      '''solutionHash'',encode(extensions.digest(convert_to(
          v_run_id::text||''|''||v_index::text,''UTF8''
        ),''sha256''),''hex''),',
      '''solutionHash'',v_solution_hash,'
    );
  end if;
  if position('''solutionHash'',v_solution_hash' in v_definition)=0 then
    raise exception 'NFJOB_CONTRACT_PROBE_HASH_SOURCE_MISMATCH';
  end if;
  execute v_definition;
end;
$repair$;

notify pgrst,'reload schema';
