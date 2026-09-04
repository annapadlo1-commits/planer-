-- B4F-168 follow-up: keep the B4F-166 database component stamp current after
-- publishing Matrix v20. The underlying validator/objectives are unchanged.

alter function public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)
  rename to solver_save_variant_before_b4f168;

create function public.solver_save_variant_v2(
  p_run_id uuid,
  p_attempt_id uuid,
  p_lease_token uuid,
  p_variant jsonb,
  p_gateway_version text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_result jsonb;
  v_variant_id uuid;
  v_version_stamp jsonb;
begin
  v_result:=public.solver_save_variant_before_b4f168(
    p_run_id,p_attempt_id,p_lease_token,p_variant,p_gateway_version
  );
  v_variant_id:=nullif(v_result->>'variantId','')::uuid;
  if v_variant_id is null then raise exception 'VARIANT_ID_MISSING'; end if;

  select v.version_stamp into v_version_stamp
  from public.plan_variants_v2 v
  where v.id=v_variant_id and v.run_id=p_run_id;
  if v_version_stamp is null then raise exception 'VERSION_STAMP_MISSING'; end if;

  v_version_stamp:=jsonb_set(
    v_version_stamp,
    '{database,schemaVersion}',
    to_jsonb('20260822203000_b4f168_database_stamp'::text),
    true
  );

  update public.plan_variants_v2 v
  set version_stamp=v_version_stamp
  where v.id=v_variant_id and v.run_id=p_run_id;

  update public.optimization_runs_v2 r
  set version_stamp=v_version_stamp,
      updated_at=now()
  where r.id=p_run_id;

  return jsonb_set(v_result,'{versionStamp}',v_version_stamp,true);
end;
$$;

revoke all on function public.solver_save_variant_before_b4f168(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
revoke all on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) from public,anon,authenticated,service_role;
grant execute on function public.solver_save_variant_v2(
  uuid,uuid,uuid,jsonb,text
) to service_role;

-- Runs created from B4F168_V1 necessarily started after Matrix v20 was
-- published. Correct their immutable audit stamp without touching assignments,
-- objectives, metrics or historical Matrix versions.
update public.plan_variants_v2 v
set version_stamp=jsonb_set(
  v.version_stamp,
  '{database,schemaVersion}',
  to_jsonb('20260822203000_b4f168_database_stamp'::text),
  true
)
from public.optimization_runs_v2 r
join public.matrix_versions mv on mv.id=r.matrix_version_id
where v.run_id=r.id
  and mv.settings->>'strategySemanticsVersion'='B4F168_V1';

update public.optimization_runs_v2 r
set version_stamp=jsonb_set(
      r.version_stamp,
      '{database,schemaVersion}',
      to_jsonb('20260822203000_b4f168_database_stamp'::text),
      true
    ),
    updated_at=now()
from public.matrix_versions mv
where mv.id=r.matrix_version_id
  and mv.settings->>'strategySemanticsVersion'='B4F168_V1';

do $$
begin
  if has_function_privilege(
    'service_role',
    'public.solver_save_variant_before_b4f168(uuid,uuid,uuid,jsonb,text)',
    'EXECUTE'
  ) then raise exception 'B4F168_PRIOR_SAVE_WRAPPER_STILL_EXPOSED'; end if;
  if not has_function_privilege(
    'service_role',
    'public.solver_save_variant_v2(uuid,uuid,uuid,jsonb,text)',
    'EXECUTE'
  ) then raise exception 'B4F168_CURRENT_SAVE_WRAPPER_NOT_EXPOSED'; end if;
end;
$$;

notify pgrst,'reload schema';
