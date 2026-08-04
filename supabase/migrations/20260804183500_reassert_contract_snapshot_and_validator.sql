-- Keep the contract-aware workforce semantics in the final snapshot builder.
-- Later stand-by/event migrations replaced the builder and accidentally dropped
-- workTimePolicy, while the database validator interpreted zero flexible-contract
-- limits as literal zero.  The worker already treats these values as unlimited.

alter function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) rename to build_snapshot_payload_before_final_contract_v2;

create function solver_private.build_snapshot_payload_v2(
  p_run_id uuid,
  p_month date,
  p_matrix_version_id uuid,
  p_scenario_id uuid,
  p_scope_type text,
  p_scope_role_id uuid
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb;
  v_employees jsonb := '[]'::jsonb;
begin
  v_snapshot:=solver_private.build_snapshot_payload_before_final_contract_v2(
    p_run_id,p_month,p_matrix_version_id,p_scenario_id,
    p_scope_type,p_scope_role_id
  );

  select coalesce(jsonb_agg(
    case
      when upper(coalesce(rate.value->>'contractCode',employee.value->>'contractCode','OTHER'))
          in ('ZLECENIE','B2B')
        and coalesce(profile.work_time_policy,'CONTRACT_DEFAULT')<>'CUSTOM'
      then employee.value||jsonb_build_object(
        'contractCode',upper(coalesce(
          rate.value->>'contractCode',employee.value->>'contractCode','OTHER'
        )),
        'workTimePolicy','CONTRACT_DEFAULT',
        'baseHourlyRateMinor',coalesce(
          nullif(rate.value->>'baseRateMinor','')::bigint,
          nullif(employee.value->>'baseHourlyRateMinor','')::bigint,
          0
        ),
        'nominalMonthlyMinutes',0,
        'maximumMonthlyMinutes',0,
        'maximumWeeklyMinutes',0,
        'maximumConsecutiveDays',31,
        'minimumRestMinutes',0
      )
      else employee.value||jsonb_build_object(
        'contractCode',upper(coalesce(
          rate.value->>'contractCode',employee.value->>'contractCode','OTHER'
        )),
        'workTimePolicy',coalesce(profile.work_time_policy,'CONTRACT_DEFAULT'),
        'baseHourlyRateMinor',coalesce(
          nullif(rate.value->>'baseRateMinor','')::bigint,
          nullif(employee.value->>'baseHourlyRateMinor','')::bigint,
          0
        )
      )
    end
    order by employee.ordinality
  ),'[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(v_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality)
  left join public.matrix_employee_profiles_v2 profile
    on profile.matrix_version_id=p_matrix_version_id
    and profile.employee_id=(employee.value->>'id')::uuid
  left join lateral (
    select period.value
    from jsonb_array_elements(coalesce(employee.value->'payRatePeriods','[]'::jsonb)) period
    where p_month>=(period.value->>'validFrom')::date
      and (nullif(period.value->>'validTo','') is null
        or p_month<=(period.value->>'validTo')::date)
    order by (period.value->>'validFrom')::date desc
    limit 1
  ) rate on true;

  return jsonb_set(v_snapshot,'{employees}',v_employees,true);
end;
$$;

alter function solver_private.validate_variant_v2(jsonb,jsonb)
  rename to validate_variant_before_final_contract_v2;

create function solver_private.validate_variant_v2(
  p_snapshot jsonb,
  p_variant jsonb
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_snapshot jsonb:=p_snapshot;
  v_employees jsonb:='[]'::jsonb;
begin
  -- The legacy validator compares numeric limits literally.  Give flexible
  -- contracts defensive upper bounds for validation only; overlap, availability,
  -- role, location, duty and hard-block checks remain unchanged and mandatory.
  select coalesce(jsonb_agg(
    case
      when upper(coalesce(employee.value->>'contractCode','OTHER'))
          in ('ZLECENIE','B2B')
        and upper(coalesce(employee.value->>'workTimePolicy','CONTRACT_DEFAULT'))<>'CUSTOM'
      then employee.value||jsonb_build_object(
        'maximumMonthlyMinutes',2147483647,
        'maximumWeeklyMinutes',2147483647,
        'maximumConsecutiveDays',2147483647,
        'minimumRestMinutes',0
      )
      else employee.value
    end
    order by employee.ordinality
  ),'[]'::jsonb)
  into v_employees
  from jsonb_array_elements(coalesce(p_snapshot->'employees','[]'::jsonb))
    with ordinality employee(value,ordinality);

  v_snapshot:=jsonb_set(v_snapshot,'{employees}',v_employees,true);
  return solver_private.validate_variant_before_final_contract_v2(
    v_snapshot,p_variant
  );
end;
$$;

revoke all on function solver_private.build_snapshot_payload_before_final_contract_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
revoke all on function solver_private.validate_variant_before_final_contract_v2(
  jsonb,jsonb
) from public,anon,authenticated;
revoke all on function solver_private.validate_variant_v2(
  jsonb,jsonb
) from public,anon,authenticated;

grant execute on function solver_private.build_snapshot_payload_before_final_contract_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;
grant execute on function solver_private.validate_variant_before_final_contract_v2(
  jsonb,jsonb
) to service_role;
grant execute on function solver_private.validate_variant_v2(
  jsonb,jsonb
) to service_role;
