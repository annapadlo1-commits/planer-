-- B4F-166 follow-up: PostgreSQL rejects a {0,499} repetition count before
-- evaluating the value. Keep the same 500-character boundary as an explicit
-- length check and leave the character whitelist as an unbounded regex.

do $repair$
declare
  v_definition text;
  v_frontend_bad constant text :=
    'p_frontend_version is null
    or p_frontend_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$''';
  v_frontend_good constant text :=
    'length(coalesce(p_frontend_version,'''')) not between 1 and 500
    or p_frontend_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]*$''';
  v_gateway_bad constant text :=
    'p_gateway_version is null
    or p_gateway_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]{0,499}$''';
  v_gateway_good constant text :=
    'length(coalesce(p_gateway_version,'''')) not between 1 and 500
    or p_gateway_version !~ ''^[A-Za-z0-9][A-Za-z0-9._:@/-]*$''';
begin
  select pg_get_functiondef(
    to_regprocedure('public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)')
  ) into v_definition;
  if v_definition is null or position(v_frontend_bad in v_definition)=0 then
    raise exception 'B4F166_FRONTEND_VALIDATOR_SOURCE_MISMATCH';
  end if;
  execute replace(v_definition,v_frontend_bad,v_frontend_good);

  select pg_get_functiondef(
    to_regprocedure('public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)')
  ) into v_definition;
  if v_definition is null or position(v_gateway_bad in v_definition)=0 then
    raise exception 'B4F166_GATEWAY_VALIDATOR_SOURCE_MISMATCH';
  end if;
  execute replace(v_definition,v_gateway_bad,v_gateway_good);
end;
$repair$;

notify pgrst,'reload schema';

do $verify$
declare
  v_request_definition text := pg_get_functiondef(
    to_regprocedure('public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)')
  );
  v_save_definition text := pg_get_functiondef(
    to_regprocedure('public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)')
  );
begin
  if position('{0,499}' in v_request_definition)>0
    or position('length(coalesce(p_frontend_version,'''')) not between 1 and 500'
      in v_request_definition)=0 then
    raise exception 'B4F166_FRONTEND_VALIDATOR_REPAIR_FAILED';
  end if;
  if position('{0,499}' in v_save_definition)>0
    or position('length(coalesce(p_gateway_version,'''')) not between 1 and 500'
      in v_save_definition)=0 then
    raise exception 'B4F166_GATEWAY_VALIDATOR_REPAIR_FAILED';
  end if;
end;
$verify$;
