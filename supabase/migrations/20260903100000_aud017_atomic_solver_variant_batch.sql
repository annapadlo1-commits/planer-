-- AUD-2026-09-01-017.
-- Future deployment target: UAT nhthrtpkfpmufmrmdyjg only; never production.
-- One PostgreSQL function call is one transaction: any nested validation or
-- persistence error rolls the complete three-variant batch back.

begin;

create or replace function public.solver_save_variants_v2(
  p_run_id uuid,
  p_attempt_id uuid,
  p_lease_token uuid,
  p_variants jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_variant jsonb;
  v_results jsonb:='[]'::jsonb;
  v_count integer;
  v_distinct_count integer;
  v_canonical_count integer;
begin
  if jsonb_typeof(p_variants)<>'array' then
    raise exception 'VARIANT_BATCH_INVALID';
  end if;

  select
    count(*),
    count(distinct upper(item.value->>'strategyCode')),
    count(*) filter (
      where upper(item.value->>'strategyCode')
        in ('BALANCED','MIN_COST','PREFERENCES')
    )
  into v_count,v_distinct_count,v_canonical_count
  from jsonb_array_elements(p_variants) item(value);

  if v_count<>3 or v_distinct_count<>3 or v_canonical_count<>3 then
    raise exception 'STRATEGY_SET_MISMATCH';
  end if;

  for v_variant in
    select item.value
    from jsonb_array_elements(p_variants) with ordinality item(value,ordinality)
    order by item.ordinality
  loop
    v_results:=v_results||jsonb_build_array(
      public.solver_save_variant_v2(
        p_run_id,
        p_attempt_id,
        p_lease_token,
        v_variant,
        p_gateway_version
      )
    );
  end loop;

  return jsonb_build_object(
    'savedVariantCount',jsonb_array_length(v_results),
    'results',v_results
  );
end;
$$;

alter function public.solver_save_variants_v2(uuid,uuid,uuid,jsonb,text)
  owner to postgres;
revoke all on function public.solver_save_variants_v2(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variants_v2(
  uuid,uuid,uuid,jsonb,text
) to service_role;

comment on function public.solver_save_variants_v2(
  uuid,uuid,uuid,jsonb,text
) is
  'AUD-017 atomically validates and persists the exact three solver variants.';

notify pgrst,'reload schema';

commit;
