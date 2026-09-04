-- Repair the projected rank metadata consumed by the consecutive-sequence check.
do $$
declare
  v_definition text;
begin
  v_definition:=pg_get_functiondef(
    'solver_private.validate_variant_v2(jsonb,jsonb)'::regprocedure
  );
  if position('assigned.*,ranked.first_rank,ranked.last_rank,ranked.template_count' in v_definition)=0 then
    v_definition:=replace(
      v_definition,
      'assigned.*,ranked.first_rank,ranked.last_rank',
      'assigned.*,ranked.first_rank,ranked.last_rank,ranked.template_count'
    );
    execute v_definition;
  end if;
end;
$$;
