-- GRAFIK PRO 3.0 — one authoritative publication model for each month.
--
-- Standalone role publications remain immediately visible to their employees.
-- A company publication cannot silently replace them.  The only compatible
-- company summary is a ROLE_COMPOSITE containing exactly the currently
-- published role variants for every active role in the Matrix.

create or replace function solver_private.publication_authority_guard_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_company public.published_schedules_v2%rowtype;
begin
  if tg_table_name='published_schedules_v2' and new.status='PUBLISHED' then
    if new.source_type='COMPANY' and exists(
      select 1 from public.published_role_schedules_v2 role_schedule
      where role_schedule.month=new.month and role_schedule.status='PUBLISHED'
    ) then
      raise exception 'COMPANY_PUBLICATION_CONFLICTS_WITH_PUBLISHED_ROLES';
    end if;
    return new;
  end if;

  if tg_table_name='published_role_schedules_v2' and new.status='PUBLISHED' then
    select schedule.* into v_company
    from public.published_schedules_v2 schedule
    where schedule.month=new.month and schedule.status='PUBLISHED'
    order by schedule.published_at desc,schedule.id desc limit 1
    for update;
    if v_company.id is not null and v_company.source_type='COMPANY' then
      raise exception 'ROLE_PUBLICATION_CONFLICTS_WITH_COMPANY_SCHEDULE';
    end if;
    -- Replacing one role invalidates a previously assembled composite.  Keep
    -- its immutable history, but do not let owners and employees read two
    -- different effective revisions while a new composite is pending.
    if v_company.id is not null and v_company.source_type='ROLE_COMPOSITE' and not exists(
      select 1 from public.published_schedule_variants_v2 link
      where link.schedule_id=v_company.id and link.role_id=new.role_id
        and link.variant_id=new.variant_id
    ) then
      update public.published_schedules_v2 schedule set
        status='ARCHIVED',archived_at=now(),archived_by=auth.uid()
      where schedule.id=v_company.id;
      insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
      values(auth.uid(),'published_schedule_v2',v_company.id::text,
        'ARCHIVE_STALE_ROLE_COMPOSITE',jsonb_build_object(
          'roleId',new.role_id,'replacementVariantId',new.variant_id
        ));
    end if;
    return new;
  end if;
  return new;
end;
$$;

drop trigger if exists published_schedule_authority_guard
  on public.published_schedules_v2;
create trigger published_schedule_authority_guard
before insert or update of status on public.published_schedules_v2
for each row execute function solver_private.publication_authority_guard_v2();

drop trigger if exists published_role_schedule_authority_guard
  on public.published_role_schedules_v2;
create trigger published_role_schedule_authority_guard
before insert or update of status,variant_id on public.published_role_schedules_v2
for each row execute function solver_private.publication_authority_guard_v2();

create or replace function solver_private.role_composite_consistency_guard_v2()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_schedule public.published_schedules_v2%rowtype;
begin
  select schedule.* into v_schedule
  from public.published_schedules_v2 schedule
  where schedule.id=coalesce(new.schedule_id,old.schedule_id);
  if v_schedule.source_type<>'ROLE_COMPOSITE' or v_schedule.status<>'PUBLISHED' then
    return null;
  end if;
  if exists(
    select 1 from public.published_schedule_variants_v2 link
    where link.schedule_id=v_schedule.id and (
      link.role_id is null or not exists(
        select 1 from public.published_role_schedules_v2 role_schedule
        where role_schedule.month=v_schedule.month
          and role_schedule.role_id=link.role_id
          and role_schedule.variant_id=link.variant_id
          and role_schedule.status='PUBLISHED'
      )
    )
  ) then
    raise exception 'ROLE_COMPOSITE_CONTAINS_NONCURRENT_ROLE_VARIANT';
  end if;
  if exists(
    select 1 from public.matrix_roles_v2 role
    where role.matrix_version_id=v_schedule.matrix_version_id and role.active
      and not exists(
        select 1 from public.published_schedule_variants_v2 link
        where link.schedule_id=v_schedule.id and link.role_id=role.id
      )
  ) then
    raise exception 'ROLE_COMPOSITE_REQUIRES_EVERY_ACTIVE_ROLE';
  end if;
  return null;
end;
$$;

drop trigger if exists role_composite_consistency_guard
  on public.published_schedule_variants_v2;
create constraint trigger role_composite_consistency_guard
after insert or update or delete on public.published_schedule_variants_v2
deferrable initially deferred
for each row execute function solver_private.role_composite_consistency_guard_v2();

create or replace function public.schedule_publication_status_uat_v2(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_month date:=date_trunc('month',p_month)::date;
  v_company public.published_schedules_v2%rowtype;
  v_conflicts jsonb:='[]'::jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  select schedule.* into v_company
  from public.published_schedules_v2 schedule
  where schedule.month=v_month and schedule.status='PUBLISHED'
  order by schedule.published_at desc,schedule.id desc limit 1;
  if v_company.id is not null then
    select coalesce(jsonb_agg(jsonb_build_object(
      'roleId',role_schedule.role_id,'roleName',role.name,
      'roleScheduleId',role_schedule.id,'roleVariantId',role_schedule.variant_id,
      'companyScheduleId',v_company.id,'companySourceType',v_company.source_type,
      'reason',case
        when v_company.source_type='COMPANY' then 'COMPANY_AND_ROLE_ACTIVE'
        when not exists(select 1 from public.published_schedule_variants_v2 link
          where link.schedule_id=v_company.id and link.role_id=role_schedule.role_id
            and link.variant_id=role_schedule.variant_id)
          then 'ROLE_VARIANT_DIFFERS_FROM_COMPOSITE'
        else null end
    ) order by role.sort_order,role.name),'[]'::jsonb) into v_conflicts
    from public.published_role_schedules_v2 role_schedule
    join public.matrix_roles_v2 role on role.id=role_schedule.role_id
    where role_schedule.month=v_month and role_schedule.status='PUBLISHED'
      and (v_company.source_type='COMPANY' or not exists(
        select 1 from public.published_schedule_variants_v2 link
        where link.schedule_id=v_company.id and link.role_id=role_schedule.role_id
          and link.variant_id=role_schedule.variant_id
      ));
  end if;
  return jsonb_build_object(
    'month',v_month,'conflict',jsonb_array_length(v_conflicts)>0,
    'conflicts',v_conflicts,
    'company',case when v_company.id is null then null else jsonb_build_object(
      'id',v_company.id,'name',v_company.name,'sourceType',v_company.source_type,
      'publishedAt',v_company.published_at
    ) end,
    'roles',coalesce((select jsonb_agg(jsonb_build_object(
      'id',role_schedule.id,'roleId',role_schedule.role_id,
      'roleName',role.name,'variantId',role_schedule.variant_id,
      'name',role_schedule.name,'publishedAt',role_schedule.published_at
    ) order by role.sort_order,role.name)
      from public.published_role_schedules_v2 role_schedule
      join public.matrix_roles_v2 role on role.id=role_schedule.role_id
      where role_schedule.month=v_month and role_schedule.status='PUBLISHED'
    ),'[]'::jsonb)
  );
end;
$$;

create or replace function public.optimizer_employee_schedule_uat_v3(p_month date)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_status jsonb;
begin
  v_status:=public.schedule_publication_status_uat_v2(p_month);
  if coalesce((v_status->>'conflict')::boolean,false) then
    raise exception 'SCHEDULE_PUBLICATION_CONFLICT_REQUIRES_OWNER_RESOLUTION';
  end if;
  return public.optimizer_employee_schedule_uat_v2(p_month);
end;
$$;

create or replace function public.schedule_publication_resolve_uat_v2(
  p_month date,
  p_keep_source text,
  p_reason text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor uuid:=auth.uid();
  v_month date:=date_trunc('month',p_month)::date;
  v_keep text:=upper(trim(coalesce(p_keep_source,'')));
  v_archived_company integer:=0;
  v_archived_roles integer:=0;
begin
  if v_actor is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'PUBLICATION_RESOLUTION_OWNER_REQUIRED';
  end if;
  if v_keep not in ('COMPANY','ROLES') then
    raise exception 'INVALID_PUBLICATION_RESOLUTION';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'PUBLICATION_RESOLUTION_REASON_REQUIRED';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(
    'publish-v2-month:'||v_month::text,0
  ));
  if v_keep='COMPANY' then
    update public.published_role_schedules_v2 publication set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where publication.month=v_month and publication.status='PUBLISHED';
    get diagnostics v_archived_roles=row_count;
    if not exists(select 1 from public.published_schedules_v2 schedule
      where schedule.month=v_month and schedule.status='PUBLISHED') then
      raise exception 'COMPANY_PUBLICATION_NOT_FOUND';
    end if;
  else
    update public.published_schedules_v2 schedule set
      status='ARCHIVED',archived_at=now(),archived_by=v_actor
    where schedule.month=v_month and schedule.status='PUBLISHED';
    get diagnostics v_archived_company=row_count;
    if not exists(select 1 from public.published_role_schedules_v2 publication
      where publication.month=v_month and publication.status='PUBLISHED') then
      raise exception 'ROLE_PUBLICATIONS_NOT_FOUND';
    end if;
  end if;
  insert into public.audit_log(actor_id,entity_type,entity_id,action,new_data)
  values(v_actor,'schedule_publication_authority_v2',v_month::text,'RESOLVE',
    jsonb_build_object(
      'keptSource',v_keep,'reason',trim(p_reason),
      'archivedCompanySchedules',v_archived_company,
      'archivedRoleSchedules',v_archived_roles
    ));
  return public.schedule_publication_status_uat_v2(v_month)||jsonb_build_object(
    'resolved',true,'keptSource',v_keep,
    'archivedCompanySchedules',v_archived_company,
    'archivedRoleSchedules',v_archived_roles
  );
end;
$$;

revoke all on function solver_private.publication_authority_guard_v2(),
  solver_private.role_composite_consistency_guard_v2()
  from public,anon,authenticated;
revoke all on function public.schedule_publication_status_uat_v2(date),
  public.optimizer_employee_schedule_uat_v3(date),
  public.schedule_publication_resolve_uat_v2(date,text,text)
  from public,anon,authenticated;
grant execute on function public.schedule_publication_status_uat_v2(date),
  public.optimizer_employee_schedule_uat_v3(date),
  public.schedule_publication_resolve_uat_v2(date,text,text)
  to authenticated;

comment on function public.schedule_publication_status_uat_v2(date) is
  'Reports competing publication sources; no timestamp or UI view silently chooses a winner.';
