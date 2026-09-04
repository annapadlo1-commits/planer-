-- B4F-101: close legacy SECURITY DEFINER read routes around the configurable
-- finance visibility policy. Redaction happens before JSON leaves PostgreSQL.

alter function public.complete_workspace(date)
  rename to complete_workspace_before_b4f101_uat_v1;

create function public.complete_workspace(p_month date default current_date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_payload jsonb;
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_employee jsonb;
  v_employees jsonb:='[]'::jsonb;
  v_budget jsonb;
begin
  v_payload:=public.complete_workspace_before_b4f101_uat_v1(p_month);
  if v_visibility='FULL' then return v_payload; end if;
  for v_employee in select value from jsonb_array_elements(coalesce(v_payload->'employees','[]'::jsonb)) loop
    v_employees:=v_employees||jsonb_build_array(v_employee-'finance');
  end loop;
  v_payload:=jsonb_set(v_payload,'{employees}',v_employees,true);
  if v_visibility='AGGREGATE' then return v_payload; end if;
  if v_visibility='BUDGET_ONLY' then
    v_budget:=v_payload->'budget';
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget is not null and v_budget<>'{}'::jsonb,
      'hardLimit',case when v_budget is null or v_budget='{}'::jsonb then null else v_budget->'hard_limit' end
    ),true);
    return v_payload;
  end if;
  return v_payload-'budget';
end;
$$;

alter function public.employer_cost_workspace_uat_v1(date)
  rename to employer_cost_workspace_before_b4f101_uat_v1;

create function public.employer_cost_workspace_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare v_visibility text:=public.application_finance_visibility_current_uat_v1();
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN') or public.has_app_role('HR_FINANCE')
    or public.has_app_role('ROLE_MANAGER') or public.has_app_role('LOCATION_MANAGER')) then raise exception 'FORBIDDEN'; end if;
  if v_visibility<>'FULL' then
    return jsonb_build_object('month',date_trunc('month',p_month)::date,
      'components','[]'::jsonb,'financeVisibility',v_visibility);
  end if;
  return public.employer_cost_workspace_before_b4f101_uat_v1(p_month)
    ||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;

alter function public.recovery_center_workspace_uat_v1(date)
  rename to recovery_center_workspace_before_b4f101_uat_v1;

create function public.recovery_center_workspace_uat_v1(p_month date)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_payload jsonb:=public.recovery_center_workspace_before_b4f101_uat_v1(p_month);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_person jsonb;
  v_people jsonb:='[]'::jsonb;
  v_budget jsonb;
begin
  if v_visibility='FULL' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  for v_person in select value from jsonb_array_elements(coalesce(v_payload->'adHocPool','[]'::jsonb)) loop
    v_people:=v_people||jsonb_build_array(v_person-'rateMinor'-'currency');
  end loop;
  v_payload:=jsonb_set(v_payload,'{adHocPool}',v_people,true);
  if v_visibility='AGGREGATE' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  if v_visibility='BUDGET_ONLY' then
    v_budget:=v_payload->'budget';
    v_payload:=jsonb_set(v_payload,'{budget}',jsonb_build_object(
      'configured',v_budget is not null and coalesce((v_budget->>'amount')::numeric,0)>0,
      'hardLimit',v_budget->'hardLimit'
    ),true);
  else
    v_payload:=v_payload-'budget';
  end if;
  return v_payload||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;

alter function public.recovery_incident_detail_uat_v1(uuid)
  rename to recovery_incident_detail_before_b4f101_uat_v1;

create function public.recovery_incident_detail_uat_v1(p_incident_id uuid)
returns jsonb language plpgsql stable security definer set search_path=''
as $$
declare
  v_payload jsonb:=public.recovery_incident_detail_before_b4f101_uat_v1(p_incident_id);
  v_visibility text:=public.application_finance_visibility_current_uat_v1();
  v_rate jsonb;
  v_rates jsonb:='[]'::jsonb;
begin
  if v_visibility='FULL' then return v_payload||jsonb_build_object('financeVisibility',v_visibility); end if;
  for v_rate in select value from jsonb_array_elements(coalesce(v_payload->'incidentRates','[]'::jsonb)) loop
    v_rates:=v_rates||jsonb_build_array(v_rate-'proposedRateMinor'-'approvedRateMinor'-'currency');
  end loop;
  return jsonb_set(v_payload,'{incidentRates}',v_rates,true)
    ||jsonb_build_object('financeVisibility',v_visibility);
end;
$$;

revoke all on function public.complete_workspace_before_b4f101_uat_v1(date),
  public.employer_cost_workspace_before_b4f101_uat_v1(date),
  public.recovery_center_workspace_before_b4f101_uat_v1(date),
  public.recovery_incident_detail_before_b4f101_uat_v1(uuid) from public,anon,authenticated;
revoke all on function public.complete_workspace(date),public.employer_cost_workspace_uat_v1(date),
  public.recovery_center_workspace_uat_v1(date),public.recovery_incident_detail_uat_v1(uuid)
  from public,anon,authenticated;
grant execute on function public.complete_workspace(date),public.employer_cost_workspace_uat_v1(date),
  public.recovery_center_workspace_uat_v1(date),public.recovery_incident_detail_uat_v1(uuid) to authenticated;

comment on function public.complete_workspace(date) is 'B4F-101 legacy workspace with server-side finance redaction.';
comment on function public.employer_cost_workspace_uat_v1(date) is 'B4F-101 employer-cost configuration visible only with FULL finance permission.';
notify pgrst,'reload schema';
