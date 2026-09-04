-- Candidate summaries are about the role required by the empty seat.  Do not
-- attach stand-by reservations from unrelated roles to people who already fail
-- the required-role check.

alter function public.optimizer_variant_issue_diagnostics_uat_v2(uuid,bigint)
  rename to optimizer_variant_issue_diagnostics_before_role_scope_uat_v2;

create function public.optimizer_variant_issue_diagnostics_uat_v2(
  p_variant_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_candidates jsonb;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_variant_issue_diagnostics_before_role_scope_uat_v2(
    p_variant_id,p_issue_id
  );
  select coalesce(jsonb_agg(case
    when coalesce((candidate.value->>'roleMatch')::boolean,false) then candidate.value
    else jsonb_set(candidate.value,'{reasons}','["ROLE_REQUIRED"]'::jsonb,true)
  end order by candidate.ordinality),'[]'::jsonb)
  into v_candidates
  from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb))
    with ordinality candidate(value,ordinality);

  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where jsonb_array_length(candidate.value->'reasons')=0),
    'blocked',count(*) filter(where jsonb_array_length(candidate.value->'reasons')>0),
    'reasons',coalesce((
      select jsonb_agg(jsonb_build_object('code',grouped.reason,'count',grouped.amount)
        order by grouped.amount desc,grouped.reason)
      from (
        select reason,count(*) amount
        from jsonb_array_elements(v_candidates) item
        cross join lateral jsonb_array_elements_text(item.value->'reasons') reason
        group by reason
      ) grouped
    ),'[]'::jsonb)
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;

  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;

alter function public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)
  rename to optimizer_candidate_diagnostics_before_role_scope_alpha16;

create function public.optimizer_candidate_diagnostics_alpha16(
  p_schedule_id uuid,
  p_issue_id bigint
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_candidates jsonb:='[]'::jsonb;
  v_candidate jsonb;
  v_hard text[];
  v_classification text;
  v_summary jsonb;
begin
  v_payload:=public.optimizer_candidate_diagnostics_before_role_scope_alpha16(
    p_schedule_id,p_issue_id
  );
  for v_candidate in
    select candidate.value
    from jsonb_array_elements(coalesce(v_payload->'candidates','[]'::jsonb)) candidate
  loop
    select coalesce(array_agg(reason),array[]::text[]) into v_hard
    from jsonb_array_elements_text(coalesce(v_candidate->'hardReasons','[]'::jsonb)) reason;
    if 'ROLE_REQUIRED'=any(v_hard) then
      v_hard:=array_remove(v_hard,'STANDBY_TIER_1_RESERVED');
      v_hard:=array_remove(v_hard,'STANDBY_TIER_2_RESERVED');
    end if;
    v_classification:=case
      when cardinality(v_hard)>0 then 'BLOCKED'
      when jsonb_array_length(coalesce(v_candidate->'softReasons','[]'::jsonb))>0 then 'WARNING'
      else 'ELIGIBLE'
    end;
    v_candidate:=jsonb_set(v_candidate,'{hardReasons}',to_jsonb(v_hard),true);
    v_candidate:=jsonb_set(v_candidate,'{classification}',to_jsonb(v_classification),true);
    v_candidates:=v_candidates||jsonb_build_array(v_candidate);
  end loop;
  select jsonb_build_object(
    'considered',jsonb_array_length(v_candidates),
    'eligible',count(*) filter(where candidate.value->>'classification'='ELIGIBLE'),
    'warning',count(*) filter(where candidate.value->>'classification'='WARNING'),
    'blocked',count(*) filter(where candidate.value->>'classification'='BLOCKED')
  ) into v_summary
  from jsonb_array_elements(v_candidates) candidate;
  return jsonb_set(
    jsonb_set(v_payload,'{candidates}',v_candidates,true),
    '{summary}',v_summary,true
  );
end;
$$;

revoke all on function public.optimizer_variant_issue_diagnostics_before_role_scope_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_candidate_diagnostics_before_role_scope_alpha16(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) from public,anon,authenticated;
revoke all on function public.optimizer_candidate_diagnostics_alpha16(
  uuid,bigint
) from public,anon,authenticated;
grant execute on function public.optimizer_variant_issue_diagnostics_uat_v2(
  uuid,bigint
) to authenticated;
grant execute on function public.optimizer_candidate_diagnostics_alpha16(
  uuid,bigint
) to authenticated;
