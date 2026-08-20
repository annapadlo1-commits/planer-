-- Executable UAT contract. All fixture and configuration mutations roll back.
begin;

do $$
declare v_definition text;
begin
  if not exists(select 1 from information_schema.columns where table_schema='public' and table_name='matrix_shift_templates_v2' and column_name='color') then
    raise exception 'B4F118_SHIFT_COLOR_COLUMN_MISSING';
  end if;
  if not exists(select 1 from pg_trigger where tgrelid='public.matrix_shift_templates_v2'::regclass and tgname='matrix_shift_color_preserve_on_clone_uat_v1' and tgenabled<>'D') then
    raise exception 'B4F118_CLONE_COLOR_TRIGGER_MISSING';
  end if;
  v_definition:=pg_get_functiondef('public.matrix_v2_publication_readiness_uat_v2(date,date)'::regprocedure);
  if position('SHIFT_BASE_STAFFING_REQUIRED' in v_definition)=0 or position('uzupełnij obsadę albo wyłącz zmianę' in v_definition)=0 then
    raise exception 'B4F115_EXACT_READINESS_BLOCKER_MISSING';
  end if;
  if has_function_privilege('anon','public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)','execute')
    or not has_function_privilege('authenticated','public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)','execute') then
    raise exception 'B4F118_ADMIN_SAVE_GRANTS_INVALID';
  end if;
end;
$$;

do $$
declare v_owner uuid;
begin
  select auth_user_id into v_owner from public.user_permissions where app_role in ('OWNER','ADMIN') order by case app_role when 'OWNER' then 0 else 1 end,auth_user_id limit 1;
  if v_owner is null then raise exception 'B4F115_B4F118_UAT_FIXTURE_MISSING'; end if;
  perform set_config('b4f.contract_owner',v_owner::text,true);
end;
$$;

select set_config('request.jwt.claim.sub',current_setting('b4f.contract_owner'),true);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

select set_config('b4f.contract_draft',public.matrix_v2_create_draft('B4F-115/B4F-118 contract')::text,true);

do $$
declare v_draft uuid:=current_setting('b4f.contract_draft')::uuid;v_shift public.matrix_shift_templates_v2%rowtype;v_result jsonb;v_message text;
begin
  select * into v_shift from public.matrix_shift_templates_v2
  where matrix_version_id=v_draft and active order by sort_order,id limit 1;
  if v_shift.id is null then raise exception 'B4F118_DRAFT_SHIFT_FIXTURE_MISSING'; end if;
  v_result:=public.matrix_v2_admin_save_alpha16('SHIFT',v_shift.id,jsonb_build_object(
    'locationId',v_shift.location_id,'code',v_shift.code,'name',v_shift.name,
    'startsAt',to_char(v_shift.starts_at,'HH24:MI'),'endsAt',to_char(v_shift.ends_at,'HH24:MI'),
    'endsNextDay',v_shift.ends_next_day,'days',to_jsonb(v_shift.day_mask),'sortOrder',v_shift.sort_order,
    'active',v_shift.active,'shiftPeriod',v_shift.shift_period,'color','#C96F54'
  ));
  if not exists(select 1 from public.matrix_shift_templates_v2 where id=(v_result->>'id')::uuid and color='#C96F54') then
    raise exception 'B4F118_ADMIN_SAVE_DID_NOT_PERSIST_COLOR';
  end if;
  begin
    perform public.matrix_v2_admin_save_alpha16('SHIFT',v_shift.id,jsonb_build_object(
      'locationId',v_shift.location_id,'code',v_shift.code,'name',v_shift.name,
      'startsAt',to_char(v_shift.starts_at,'HH24:MI'),'endsAt',to_char(v_shift.ends_at,'HH24:MI'),
      'endsNextDay',v_shift.ends_next_day,'days',to_jsonb(v_shift.day_mask),'sortOrder',v_shift.sort_order,
      'active',v_shift.active,'shiftPeriod',v_shift.shift_period,'color','purple'
    ));
    raise exception 'B4F118_INVALID_COLOR_ACCEPTED';
  exception when others then
    get stacked diagnostics v_message=message_text;
    if position('INVALID_SHIFT_COLOR' in v_message)=0 then raise; end if;
  end;
  perform set_config('b4f.contract_shift',v_shift.id::text,true);
end;
$$;

reset role;
do $$
declare v_source public.matrix_shift_templates_v2%rowtype;v_source_location public.matrix_locations_v2%rowtype;v_clone_matrix uuid;v_clone_location uuid;v_clone_shift uuid;
begin
  select * into v_source from public.matrix_shift_templates_v2 where id=current_setting('b4f.contract_shift')::uuid;
  select * into v_source_location from public.matrix_locations_v2 where id=v_source.location_id;
  insert into public.matrix_versions(version,name,status,effective_from,settings,created_by,schema_version,base_version_id)
  select max(version)+100000,'B4F-118 trigger clone','DRAFT',current_date,'{}'::jsonb,current_setting('b4f.contract_owner')::uuid,2,current_setting('b4f.contract_draft')::uuid
  from public.matrix_versions returning id into v_clone_matrix;
  insert into public.matrix_locations_v2(matrix_version_id,logical_id,code,name,timezone,sort_order,active)
  values(v_clone_matrix,v_source_location.logical_id,v_source_location.code,v_source_location.name,v_source_location.timezone,v_source_location.sort_order,true)
  returning id into v_clone_location;
  insert into public.matrix_shift_templates_v2(matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,ends_next_day,day_mask,sort_order,active,shift_period)
  values(v_clone_matrix,v_source.logical_id,v_clone_location,v_source.code,v_source.name,v_source.starts_at,v_source.ends_at,v_source.ends_next_day,v_source.day_mask,v_source.sort_order,true,v_source.shift_period)
  returning id into v_clone_shift;
  if (select color from public.matrix_shift_templates_v2 where id=v_clone_shift)<>'#C96F54' then
    raise exception 'B4F118_COLOR_NOT_PRESERVED_ON_CLONE';
  end if;
  delete from public.matrix_versions where id=v_clone_matrix;
end;
$$;
delete from public.matrix_staffing_rules_v2
where matrix_version_id=current_setting('b4f.contract_draft')::uuid
  and shift_template_id=current_setting('b4f.contract_shift')::uuid;
set local role authenticated;

do $$
declare v_readiness jsonb;
begin
  v_readiness:=public.matrix_v2_publication_readiness_uat_v2(current_date,date_trunc('month',current_date)::date);
  if not exists(select 1 from jsonb_array_elements(v_readiness->'blockers') blocker
    where blocker.value->>'code'='SHIFT_BASE_STAFFING_REQUIRED'
      and blocker.value->>'shiftTemplateId'=current_setting('b4f.contract_shift')) then
    raise exception 'B4F115_EXACT_SHIFT_BLOCKER_NOT_RETURNED:%',v_readiness;
  end if;
end;
$$;

rollback;
