-- UAT-only repair for PostgreSQL's bounded-repetition limit. The full source
-- migration already contains the replay-safe form; this migration repairs the
-- function installed before Gate A exposed the legacy {0,499} expression.
do $repair$
declare
  v_oid regprocedure:=
    'public.solver_save_variant_before_b4f168(uuid,uuid,uuid,jsonb,text)'::regprocedure;
  v_definition text;
  v_legacy text:=
    'p_gateway_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$''';
  v_safe text:=
    'p_gateway_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]*$''';
begin
  select pg_get_functiondef(v_oid) into v_definition;
  if position(v_legacy in v_definition)>0 then
    execute replace(v_definition,v_legacy,v_safe);
  elsif position(v_safe in v_definition)=0 then
    raise exception 'NFJOB_GATEWAY_REGEX_REPAIR_SOURCE_MISMATCH';
  end if;
end;
$repair$;

notify pgrst,'reload schema';
