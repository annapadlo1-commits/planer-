-- Fail a deployment instead of silently exposing an incomplete role workflow.
-- The objects are defined in 20260803120000_contract_aware_availability_v2.sql;
-- this final guard makes their presence, RLS and API grants an explicit part of
-- the deployable Alpha 16 contract after later snapshot wrappers.

do $$
begin
  if to_regclass('public.published_role_schedules_v2') is null then
    raise exception 'MISSING_PUBLISHED_ROLE_SCHEDULES_V2';
  end if;
  if to_regprocedure(
    'public.optimizer_publish_role_variant_uat_v2(uuid,uuid,text,text)'
  ) is null then
    raise exception 'MISSING_ROLE_PUBLICATION_RPC_V2';
  end if;
  if to_regprocedure(
    'public.optimizer_employee_schedule_uat_v2(date)'
  ) is null then
    raise exception 'MISSING_EMPLOYEE_SCHEDULE_RPC_V2';
  end if;
  if to_regprocedure(
    'solver_private.build_snapshot_payload_v2(uuid,date,uuid,uuid,text,uuid)'
  ) is null then
    raise exception 'MISSING_CANONICAL_SNAPSHOT_BUILDER_V2';
  end if;
end;
$$;

create unique index if not exists published_role_schedules_v2_current_role_month
  on public.published_role_schedules_v2(month,role_id)
  where status='PUBLISHED';
create index if not exists published_role_schedules_v2_variant_idx
  on public.published_role_schedules_v2(variant_id);

alter table public.published_role_schedules_v2 enable row level security;
drop policy if exists published_role_schedules_v2_manager_read
  on public.published_role_schedules_v2;
create policy published_role_schedules_v2_manager_read
on public.published_role_schedules_v2 for select to authenticated
using (
  (select public.has_app_role('OWNER'))
  or (select public.has_app_role('ADMIN'))
  or exists(
    select 1 from public.matrix_roles_v2 role
    join public.matrix_scope_grants_v2 grant_row
      on grant_row.role_logical_id is null
      or grant_row.role_logical_id=role.logical_id
    where role.id=published_role_schedules_v2.role_id
      and grant_row.auth_user_id=(select auth.uid())
      and grant_row.active and grant_row.app_role='ROLE_MANAGER'
  )
);

revoke all on table public.published_role_schedules_v2
  from public,anon,authenticated;
grant select on table public.published_role_schedules_v2 to authenticated;
grant all on table public.published_role_schedules_v2 to service_role;

revoke all on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) from public,anon,authenticated;
grant execute on function public.optimizer_publish_role_variant_uat_v2(
  uuid,uuid,text,text
) to authenticated;

revoke all on function public.optimizer_employee_schedule_uat_v2(date)
  from public,anon,authenticated;
grant execute on function public.optimizer_employee_schedule_uat_v2(date)
  to authenticated;

revoke all on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function solver_private.build_snapshot_payload_v2(
  uuid,date,uuid,uuid,text,uuid
) to service_role;

notify pgrst,'reload schema';
