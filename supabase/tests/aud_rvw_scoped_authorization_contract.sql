\set ON_ERROR_STOP on
begin;

do $$
begin
  if has_function_privilege(
      'anon','public.complete_workspace(date)','execute')
    or has_function_privilege(
      'anon','public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)','execute')
    or has_function_privilege(
      'anon','public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(uuid,bigint)','execute')
    or has_function_privilege(
      'anon','public.optimizer_emergency_assign_alpha16(uuid,bigint,uuid,boolean,text,boolean)','execute')
    or has_function_privilege(
      'anon','public.optimizer_request_before_nfjob_uat_v1(date,uuid,text,uuid,text,text,text)','execute')
    or has_function_privilege(
      'anon','public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)','execute')
    or has_function_privilege(
      'anon','public.optimizer_create_manual_leader_studio_uat_v1(date,uuid,text,uuid,text,text)','execute')
    or has_function_privilege(
      'anon','public.optimizer_create_leader_variant_uat_v1(uuid,uuid,text)','execute') then
    raise exception 'AUD_RVW_ANON_RPC_EXECUTE_ALLOWED';
  end if;
  if not has_function_privilege(
      'authenticated','public.optimizer_candidate_diagnostics_alpha16(uuid,bigint)','execute')
    or not has_function_privilege(
      'authenticated','public.optimizer_request_v2(date,uuid,text,uuid,text,text,text)','execute') then
    raise exception 'AUD_RVW_FINAL_USER_RPC_NOT_REACHABLE';
  end if;
  if has_function_privilege(
      'authenticated','public.complete_workspace_before_aud_rvw_scoped_authorization_uat_v1(date)','execute')
    or has_function_privilege(
      'service_role','public.optimizer_diag_before_aud_rvw_exact_issue_uat_v1(uuid,bigint)','execute')
    or has_function_privilege(
      'service_role','public.optimizer_emergency_assign_before_aud_rvw_exact_issue_uat_v1(uuid,bigint,uuid,boolean,text,boolean)','execute')
    or has_function_privilege(
      'service_role','public.optimizer_request_before_aud_rvw_category_scope_uat_v1(date,uuid,text,uuid,text,text,text)','execute')
    or has_function_privilege(
      'service_role','public.optimizer_create_manual_leader_studio_before_aud_rvw_uat_v1(date,uuid,text,uuid,text,text)','execute')
    or has_function_privilege(
      'service_role','public.optimizer_create_leader_variant_before_aud_rvw_uat_v1(uuid,uuid,text)','execute')
    or has_function_privilege(
      'authenticated','solver_private.can_edit_leader_variant_before_aud_rvw_uat_v1(uuid)','execute')
    or has_function_privilege(
      'authenticated','solver_private.can_access_run_before_aud_rvw_uat_v1(uuid)','execute') then
    raise exception 'AUD_RVW_INTERNAL_IMPLEMENTATION_REACHABLE';
  end if;
end $$;

insert into auth.users(
  instance_id,id,aud,role,email,encrypted_password,
  raw_app_meta_data,raw_user_meta_data,is_super_admin,created_at,updated_at
)
select '00000000-0000-0000-0000-000000000000',id,'authenticated',
  'authenticated',email,'',
  '{"provider":"email","providers":["email"]}'::jsonb,'{}'::jsonb,
  false,now(),now()
from (values
  ('a1400000-0000-4000-8000-000000000001'::uuid,'aud-rvw-owner@example.invalid'),
  ('a1400000-0000-4000-8000-000000000002'::uuid,'aud-rvw-manager@example.invalid'),
  ('a1400000-0000-4000-8000-000000000003'::uuid,'aud-rvw-location@example.invalid')
) fixture(id,email);

insert into public.user_permissions(auth_user_id,app_role) values
  ('a1400000-0000-4000-8000-000000000001','OWNER'),
  ('a1400000-0000-4000-8000-000000000002','ROLE_MANAGER'),
  ('a1400000-0000-4000-8000-000000000003','LOCATION_MANAGER');

set local session_replication_role=replica;
insert into public.matrix_versions(
  id,version,name,status,effective_from,settings,schema_version,
  content_hash,workforce_hash,workforce_count
) values(
  'a1400000-0000-4000-8000-000000000010',140001,'AUD RVW matrix',
  'ACTIVE',date_trunc('month',current_date)::date,
  '{"companyBoundaryId":"a0080000-0000-4000-8000-000000000001"}'::jsonb,
  2,repeat('1',64),repeat('2',64),0
);

insert into public.matrix_role_categories_v2(
  id,matrix_version_id,logical_id,code,name,sort_order,active
) values
  ('a1400000-0000-4000-8000-000000000020','a1400000-0000-4000-8000-000000000010','a1400000-0000-4000-8000-000000000120','CAT_A','Kategoria A',1,true),
  ('a1400000-0000-4000-8000-000000000021','a1400000-0000-4000-8000-000000000010','a1400000-0000-4000-8000-000000000121','CAT_B','Kategoria B',2,true);

insert into public.matrix_roles_v2(
  id,matrix_version_id,logical_id,code,name,sort_order,active,category_id
) values
  ('a1400000-0000-4000-8000-000000000030','a1400000-0000-4000-8000-000000000010','a1400000-0000-4000-8000-000000000130','ROLE_A','Rola A',1,true,'a1400000-0000-4000-8000-000000000020'),
  ('a1400000-0000-4000-8000-000000000031','a1400000-0000-4000-8000-000000000010','a1400000-0000-4000-8000-000000000131','ROLE_B','Rola B',2,true,'a1400000-0000-4000-8000-000000000020'),
  ('a1400000-0000-4000-8000-000000000032','a1400000-0000-4000-8000-000000000010','a1400000-0000-4000-8000-000000000132','ROLE_C','Rola C',3,true,'a1400000-0000-4000-8000-000000000021');

insert into public.matrix_scope_grants_v2(
  auth_user_id,app_role,role_logical_id,active,created_by
) values(
  'a1400000-0000-4000-8000-000000000002','ROLE_MANAGER',
  'a1400000-0000-4000-8000-000000000130',true,
  'a1400000-0000-4000-8000-000000000001'
);
insert into public.matrix_scope_grants_v2(
  auth_user_id,app_role,location_logical_id,active,created_by
) values(
  'a1400000-0000-4000-8000-000000000003','LOCATION_MANAGER',
  'a1400000-0000-4000-8000-000000000140',true,
  'a1400000-0000-4000-8000-000000000001'
);
insert into public.employees(
  id,auth_user_id,employee_no,first_name,last_name,email,
  monthly_nominal_minutes,active
) values
  ('a1400000-0000-4000-8000-000000000150','a1400000-0000-4000-8000-000000000002','GP-A140-M','Audyt','Manager','aud-rvw-manager@example.invalid',9600,true),
  ('a1400000-0000-4000-8000-000000000151',null,'GP-A140-O','Audyt','Inna osoba','aud-rvw-other@example.invalid',9600,true);

insert into public.optimization_runs_v2(
  id,idempotency_key,month,matrix_version_id,scenario_id,scope_type,
  scope_role_id,name,status,phase,progress,requested_by,
  snapshot_schema_version,snapshot_hash,solver_version,request_engine,
  attempt_count,max_attempts,created_at,queued_at,updated_at,version_stamp
) values(
  'a1400000-0000-4000-8000-000000000041','aud-rvw-run-001',
  date_trunc('month',current_date)::date,
  'a1400000-0000-4000-8000-000000000010',
  'a1400000-0000-4000-8000-000000000051','ROLE',
  'a1400000-0000-4000-8000-000000000030','AUD RVW run',
  'READY','READY',100,'a1400000-0000-4000-8000-000000000002',
  2,repeat('4',64),'aud-rvw-solver','ORTOOLS_V2',0,1,
  now(),now(),now(),'{}'::jsonb
);

insert into public.plan_variants_v2(
  id,run_id,run_strategy_id,strategy_id,name,status,solver_status,
  solution_hash,snapshot_hash,variant_kind
) values(
  'a1400000-0000-4000-8000-000000000040',
  'a1400000-0000-4000-8000-000000000041',
  'a1400000-0000-4000-8000-000000000042',
  'a1400000-0000-4000-8000-000000000043','AUD RVW variant',
  'READY','FEASIBLE',repeat('3',64),repeat('4',64),'LEADER_COPY'
);
insert into public.published_schedules_v2(
  id,idempotency_key,month,matrix_version_id,scenario_id,source_type,name,
  status,publication_hash,validation_snapshot_hash,created_by
) values(
  'a1400000-0000-4000-8000-000000000050','aud-rvw-published-001',
  date_trunc('month',current_date)::date,
  'a1400000-0000-4000-8000-000000000010',
  'a1400000-0000-4000-8000-000000000051','COMPANY','AUD RVW schedule',
  'PUBLISHED',repeat('5',64),repeat('6',64),
  'a1400000-0000-4000-8000-000000000001'
);
insert into public.published_schedule_variants_v2(
  schedule_id,variant_id,role_id,ordinal
) values(
  'a1400000-0000-4000-8000-000000000050',
  'a1400000-0000-4000-8000-000000000040',
  'a1400000-0000-4000-8000-000000000030',1
);
insert into public.plan_issues_v2(
  id,variant_id,issue_code,severity,role_id,required_count,assigned_count,message
) overriding system value values
  (140001,'a1400000-0000-4000-8000-000000000040','UNDERSTAFFED','WARNING','a1400000-0000-4000-8000-000000000030',1,0,'Rola A'),
  (140002,'a1400000-0000-4000-8000-000000000040','UNDERSTAFFED','WARNING','a1400000-0000-4000-8000-000000000032',1,0,'Rola C');
set local session_replication_role=origin;

create or replace function pg_temp.aud_rvw_can_request(
  p_month date,p_scope_type text,p_scope_role_id uuid
) returns boolean
language sql stable security definer set search_path=''
as $function$
  select solver_private.aud_rvw_can_request_optimizer_scope_uat_v1(
    p_month,p_scope_type,p_scope_role_id
  )
$function$;
create or replace function pg_temp.aud_rvw_can_manage_issue(
  p_schedule_id uuid,p_issue_id bigint
) returns boolean
language sql stable security definer set search_path=''
as $function$
  select solver_private.aud_rvw_can_manage_schedule_issue_uat_v1(
    p_schedule_id,p_issue_id
  )
$function$;
create or replace function pg_temp.aud_rvw_can_access_run(p_run_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $function$
  select solver_private.can_access_run_v2(p_run_id)
$function$;
create or replace function pg_temp.aud_rvw_can_edit_variant(p_variant_id uuid)
returns boolean
language sql stable security definer set search_path=''
as $function$
  select solver_private.can_edit_leader_variant_uat_v1(p_variant_id)
$function$;
grant execute on function pg_temp.aud_rvw_can_request(date,text,uuid),
  pg_temp.aud_rvw_can_manage_issue(uuid,bigint),
  pg_temp.aud_rvw_can_access_run(uuid),
  pg_temp.aud_rvw_can_edit_variant(uuid)
to authenticated,anon;

select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a1400000-0000-4000-8000-000000000002',true);

do $$
declare
  v_workspace jsonb;
  v_runs_before bigint;
  v_variants_before bigint;
  v_audit_before bigint;
  v_overrides_before bigint;
  v_notifications_before bigint;
  v_override_digest_before text;
  v_notification_digest_before text;
  v_audit_digest_before text;
begin
  if pg_temp.aud_rvw_can_request(
    current_date,'COMPANY',null
  ) then raise exception 'AUD_RVW_MANAGER_COMPANY_SCOPE_ALLOWED'; end if;
  if pg_temp.aud_rvw_can_request(
    current_date,'ROLE','a1400000-0000-4000-8000-000000000030'
  ) then raise exception 'AUD_RVW_PARTIAL_CATEGORY_GRANT_ALLOWED'; end if;
  if pg_temp.aud_rvw_can_edit_variant(
    'a1400000-0000-4000-8000-000000000040'
  ) then raise exception 'AUD_RVW_PARTIAL_CATEGORY_LEADER_EDIT_ALLOWED'; end if;
  if pg_temp.aud_rvw_can_access_run(
    'a1400000-0000-4000-8000-000000000041'
  ) then raise exception 'AUD_RVW_PARTIAL_CATEGORY_RUN_ACCESS_ALLOWED'; end if;
  select count(*) into v_runs_before from public.optimization_runs_v2;
  select count(*) into v_variants_before from public.plan_variants_v2;
  select count(*) into v_audit_before from public.audit_log;
  select count(*),md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
  into v_overrides_before,v_override_digest_before
  from public.operational_assignment_overrides_v2 row_data;
  select count(*),md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
  into v_notifications_before,v_notification_digest_before
  from public.notifications row_data;
  select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
  into v_audit_digest_before from public.audit_log row_data;
  begin
    perform public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
      'a1400000-0000-4000-8000-000000000050',140002
    );
    raise exception 'AUD_RVW_FOREIGN_ROLE_DIAGNOSTICS_ALLOWED';
  exception when others then
    if sqlerrm<>'FORBIDDEN' then raise; end if;
  end;
  begin
    perform public.optimizer_emergency_assign_alpha16(
      'a1400000-0000-4000-8000-000000000050',140002,
      'a1400000-0000-4000-8000-000000000151',true,
      'Niedozwolona obca rola',true
    );
    raise exception 'AUD_RVW_FOREIGN_ROLE_EMERGENCY_ALLOWED';
  exception when others then
    if sqlerrm<>'FORBIDDEN' then raise; end if;
  end;
  begin
    perform public.optimizer_candidate_diagnostics_before_primary_rules_alpha16(
      'a1400000-0000-4000-8000-000000000050',140001
    );
  exception when others then
    if sqlerrm='FORBIDDEN' then
      raise exception 'AUD_RVW_EXACT_ROLE_PUBLIC_DIAGNOSTICS_DENIED';
    end if;
    if sqlerrm<>'UNFILLED_ISSUE_NOT_FOUND' then raise; end if;
  end;
  begin
    perform public.optimizer_create_manual_leader_studio_uat_v1(
      current_date,'a1400000-0000-4000-8000-000000000051','ROLE',
      'a1400000-0000-4000-8000-000000000030','Niedozwolone studio','aud-rvw'
    );
    raise exception 'AUD_RVW_PARTIAL_CATEGORY_MANUAL_STUDIO_ALLOWED';
  exception when others then
    if sqlerrm<>'OPTIMIZER_SCOPE_FORBIDDEN' then raise; end if;
  end;
  begin
    perform public.optimizer_create_leader_variant_uat_v1(
      'a1400000-0000-4000-8000-000000000041',
      'a1400000-0000-4000-8000-000000000099','Niedozwolona kopia'
    );
    raise exception 'AUD_RVW_PARTIAL_CATEGORY_LEADER_COPY_ALLOWED';
  exception when others then
    if sqlerrm<>'LEADER_VARIANT_FORBIDDEN' then raise; end if;
  end;
  if (select count(*) from public.optimization_runs_v2)<>v_runs_before
    or (select count(*) from public.plan_variants_v2)<>v_variants_before
    or (select count(*) from public.operational_assignment_overrides_v2)<>v_overrides_before
    or (select count(*) from public.notifications)<>v_notifications_before
    or (select count(*) from public.audit_log)<>v_audit_before
    or (select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
        from public.operational_assignment_overrides_v2 row_data)<>v_override_digest_before
    or (select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
        from public.notifications row_data)<>v_notification_digest_before
    or (select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),''))
        from public.audit_log row_data)<>v_audit_digest_before then
    raise exception 'AUD_RVW_REJECTED_RPC_LEFT_SIDE_EFFECTS';
  end if;
  if not pg_temp.aud_rvw_can_manage_issue(
    'a1400000-0000-4000-8000-000000000050',140001
  ) then raise exception 'AUD_RVW_EXACT_ROLE_ISSUE_DENIED'; end if;
  if pg_temp.aud_rvw_can_manage_issue(
    'a1400000-0000-4000-8000-000000000050',140002
  ) then raise exception 'AUD_RVW_FOREIGN_ROLE_ISSUE_ALLOWED'; end if;
  v_workspace:=public.complete_workspace(current_date);
  if jsonb_array_length(coalesce(v_workspace->'employees','[]'::jsonb))<>1
    or v_workspace#>>'{employees,0,id}'<>'a1400000-0000-4000-8000-000000000150'
    or v_workspace->'plan'<>'null'::jsonb
    or jsonb_array_length(coalesce(v_workspace->'preferences','[]'::jsonb))<>0
    or jsonb_array_length(coalesce(v_workspace->'timeRecords','[]'::jsonb))<>0 then
    raise exception 'AUD_RVW_SCOPED_WORKSPACE_LEAK:%',v_workspace;
  end if;
end $$;

create temporary table aud_rvw_final_rpc_snapshot on commit drop as
select jsonb_build_object(
  'runs',(select count(*) from public.optimization_runs_v2),
  'variants',(select count(*) from public.plan_variants_v2),
  'overrides',(select count(*) from public.operational_assignment_overrides_v2),
  'notifications',(select count(*) from public.notifications),
  'audit',(select count(*) from public.audit_log),
  'runDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.optimization_runs_v2 row_data),
  'overrideDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.operational_assignment_overrides_v2 row_data),
  'notificationDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.notifications row_data),
  'auditDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.audit_log row_data)
) snapshot;

set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a1400000-0000-4000-8000-000000000002',true);
do $$
begin
  begin
    perform public.optimizer_candidate_diagnostics_alpha16(
      'a1400000-0000-4000-8000-000000000050',140002
    );
    raise exception 'AUD_RVW_FINAL_FOREIGN_ROLE_DIAGNOSTICS_ALLOWED';
  exception when others then
    if sqlerrm<>'FORBIDDEN' then raise; end if;
  end;
  begin
    perform public.optimizer_request_v2(
      current_date,'a1400000-0000-4000-8000-000000000051','ROLE',
      'a1400000-0000-4000-8000-000000000030','Niedozwolony request',
      'aud-rvw-final-request-negative','aud-rvw-contract'
    );
    raise exception 'AUD_RVW_FINAL_PARTIAL_CATEGORY_REQUEST_ALLOWED';
  exception when others then
    if sqlerrm<>'OPTIMIZER_SCOPE_FORBIDDEN' then raise; end if;
  end;
end $$;
reset role;

do $$
declare
  v_before jsonb;
  v_after jsonb;
begin
  select snapshot into strict v_before from aud_rvw_final_rpc_snapshot;
  select jsonb_build_object(
    'runs',(select count(*) from public.optimization_runs_v2),
    'variants',(select count(*) from public.plan_variants_v2),
    'overrides',(select count(*) from public.operational_assignment_overrides_v2),
    'notifications',(select count(*) from public.notifications),
    'audit',(select count(*) from public.audit_log),
    'runDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.optimization_runs_v2 row_data),
    'overrideDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.operational_assignment_overrides_v2 row_data),
    'notificationDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.notifications row_data),
    'auditDigest',(select md5(coalesce(string_agg(to_jsonb(row_data)::text,'|' order by id::text),'')) from public.audit_log row_data)
  ) into v_after;
  if v_after is distinct from v_before then
    raise exception 'AUD_RVW_FINAL_REJECTED_RPC_LEFT_SIDE_EFFECTS';
  end if;
end $$;

insert into public.matrix_scope_grants_v2(
  auth_user_id,app_role,role_logical_id,active,created_by
) values(
  'a1400000-0000-4000-8000-000000000002','ROLE_MANAGER',
  'a1400000-0000-4000-8000-000000000131',true,
  'a1400000-0000-4000-8000-000000000001'
);

do $$
begin
  if not pg_temp.aud_rvw_can_request(
    current_date,'ROLE','a1400000-0000-4000-8000-000000000030'
  ) then raise exception 'AUD_RVW_COMPLETE_CATEGORY_GRANT_DENIED'; end if;
  if not pg_temp.aud_rvw_can_access_run(
    'a1400000-0000-4000-8000-000000000041'
  ) or not pg_temp.aud_rvw_can_edit_variant(
    'a1400000-0000-4000-8000-000000000040'
  ) then raise exception 'AUD_RVW_COMPLETE_CATEGORY_EXISTING_RUN_DENIED'; end if;
end $$;

reset role;
delete from public.matrix_scope_grants_v2
where auth_user_id='a1400000-0000-4000-8000-000000000002'
  and role_logical_id='a1400000-0000-4000-8000-000000000131';
set local role authenticated;
select set_config('request.jwt.claim.role','authenticated',true);
select set_config('request.jwt.claim.sub','a1400000-0000-4000-8000-000000000002',true);

do $$
declare
  v_selected_before boolean;
  v_status_before text;
begin
  select selected into strict v_selected_before
  from public.plan_variants_v2
  where id='a1400000-0000-4000-8000-000000000040';
  select status into strict v_status_before
  from public.optimization_runs_v2
  where id='a1400000-0000-4000-8000-000000000041';
  if pg_temp.aud_rvw_can_access_run(
    'a1400000-0000-4000-8000-000000000041'
  ) or pg_temp.aud_rvw_can_edit_variant(
    'a1400000-0000-4000-8000-000000000040'
  ) then raise exception 'AUD_RVW_REVOKED_CATEGORY_ACCESS_RETAINED'; end if;
  begin
    perform public.optimizer_variants_v2(
      'a1400000-0000-4000-8000-000000000041'
    );
    raise exception 'AUD_RVW_REVOKED_CATEGORY_READ_ALLOWED';
  exception when others then
    if sqlerrm<>'RUN_NOT_FOUND' then raise; end if;
  end;
  begin
    perform public.optimizer_request_cancel_v2(
      'a1400000-0000-4000-8000-000000000041'
    );
    raise exception 'AUD_RVW_REVOKED_CATEGORY_CANCEL_ALLOWED';
  exception when others then
    if sqlerrm<>'RUN_NOT_FOUND' then raise; end if;
  end;
  if (select selected from public.plan_variants_v2
      where id='a1400000-0000-4000-8000-000000000040')
      is distinct from v_selected_before then
    raise exception 'AUD_RVW_REVOKED_CATEGORY_VARIANT_STATE_CHANGED';
  end if;
  if (select status from public.optimization_runs_v2
      where id='a1400000-0000-4000-8000-000000000041')
      is distinct from v_status_before then
    raise exception 'AUD_RVW_REVOKED_CATEGORY_RUN_STATE_CHANGED';
  end if;
end $$;

select set_config('request.jwt.claim.sub','a1400000-0000-4000-8000-000000000003',true);
do $$
begin
  if pg_temp.aud_rvw_can_request(
    current_date,'ROLE','a1400000-0000-4000-8000-000000000030'
  ) or pg_temp.aud_rvw_can_manage_issue(
    'a1400000-0000-4000-8000-000000000050',140001
  ) then raise exception 'AUD_RVW_LOCATION_MANAGER_SOLVER_SCOPE_ALLOWED'; end if;
end $$;

select set_config('request.jwt.claim.sub','a1400000-0000-4000-8000-000000000001',true);
do $$
begin
  if not pg_temp.aud_rvw_can_request(
    current_date,'COMPANY',null
  ) then raise exception 'AUD_RVW_OWNER_COMPANY_SCOPE_DENIED'; end if;
end $$;

select set_config('request.jwt.claim.sub','',true);
select set_config('request.jwt.claim.role','anon',true);
do $$
begin
  if pg_temp.aud_rvw_can_request(
    current_date,'COMPANY',null
  ) or pg_temp.aud_rvw_can_manage_issue(
    'a1400000-0000-4000-8000-000000000050',140001
  ) then raise exception 'AUD_RVW_ANON_HELPER_ALLOWED'; end if;
end $$;

rollback;
