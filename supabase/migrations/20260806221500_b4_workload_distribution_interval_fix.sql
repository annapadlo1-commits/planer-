-- Correct the already-deployed UAT function without changing its API. Fresh
-- environments receive the corrected definition from the preceding migration.
do $fix$
declare
  v_definition text;
begin
  v_definition:=pg_get_functiondef(
    'public.optimizer_variant_workload_distribution_uat_v1(uuid)'::regprocedure
  );
  v_definition:=replace(
    v_definition,
    'interval ''1 month-1 day''',
    'interval ''1 month''-interval ''1 day'''
  );
  if position('1 month-1 day' in v_definition)>0 then
    raise exception 'WORKLOAD_DISTRIBUTION_INTERVAL_FIX_FAILED';
  end if;
  execute v_definition;
end;
$fix$;

notify pgrst,'reload schema';
