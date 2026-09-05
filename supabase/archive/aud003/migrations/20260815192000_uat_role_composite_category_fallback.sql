-- Local UAT fix candidate. Do not deploy without explicit approval.
-- If a category-aware candidate lookup loses its source-version anchors, use
-- the already published teams for that exact month and scenario as merge input.

alter function public.optimizer_role_composite_candidates_v2(date,uuid)
  rename to optimizer_role_composite_candidates_before_publication_fallback_uat_v1;

create function public.optimizer_role_composite_candidates_v2(
  p_month date,
  p_scenario_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_raw jsonb;
  v_overview jsonb;
  v_roles jsonb;
begin
  v_raw:=public.optimizer_role_composite_candidates_before_publication_fallback_uat_v1(
    p_month,p_scenario_id
  );
  if jsonb_array_length(coalesce(v_raw->'roles','[]'::jsonb))>0 then
    return v_raw;
  end if;

  v_overview:=public.optimizer_role_publication_overview_uat_v2(p_month);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id',item.value->'role'->>'id',
    'name',item.value->'role'->>'name',
    'sortOrder',item.ordinality,
    'variant',jsonb_build_object('id',item.value->>'variantId')
  ) order by item.ordinality),'[]'::jsonb)
  into v_roles
  from jsonb_array_elements(coalesce(v_overview->'roles','[]'::jsonb))
    with ordinality item(value,ordinality)
  where item.value->'scenario'->>'id'=p_scenario_id::text
    and nullif(item.value->>'variantId','') is not null;

  if jsonb_array_length(v_roles)=0 then return v_raw; end if;
  return jsonb_set(
    jsonb_set(
      jsonb_set(v_raw,'{roles}',v_roles,true),
      '{missingRoleIds}','[]'::jsonb,true
    ),
    '{ready}','true'::jsonb,true
  );
end;
$$;

revoke all on function public.optimizer_role_composite_candidates_v2(date,uuid)
  from public,anon;
revoke all on function public.optimizer_role_composite_candidates_before_publication_fallback_uat_v1(date,uuid)
  from public,anon,authenticated;
grant execute on function public.optimizer_role_composite_candidates_v2(date,uuid)
  to authenticated;

notify pgrst,'reload schema';
