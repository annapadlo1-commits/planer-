-- GRAFIK PRO 3.0 -- retire Alpha 15 runtime writes.
--
-- Historical functions stay in the schema so old migrations remain replayable
-- and a database-owner rollback is still possible. They are no longer part of
-- the application API. Read-only plan_workspace/complete_workspace and
-- employee_portal_workspace remain temporarily available to display schedules
-- published before the controlled OR-Tools cutover.

revoke all on function
  public.generate_plan(date,text,text,text,text),
  public.publish_plan(uuid),
  public.shift_candidates(uuid,public.employee_role),
  public.emergency_assign(uuid,uuid,public.employee_role,boolean),
  public.create_operational_event(
    public.location_code,text,text,text,timestamptz,timestamptz,integer,
    public.event_status,jsonb
  ),
  public.employee_archive(uuid,text),
  public.employee_restore(uuid),
  public.employee_update(uuid,jsonb),
  public.employee_availability_save_month(date,jsonb,boolean),
  public.attendance_clock(text,text,numeric,numeric),
  public.preference_save(uuid,date,date,text,jsonb),
  public.budget_update(date,numeric,integer,boolean),
  public.matrix_workspace(date),
  public.matrix_create_draft(text),
  public.matrix_save_item(text,uuid,jsonb),
  public.matrix_save_shift(uuid,jsonb),
  public.matrix_save_demand(uuid,uuid,integer,text),
  public.matrix_publish_draft(date),
  public.matrix_import_apply(text,jsonb,jsonb),
  public.generate_role_plan(date,uuid,text,text,text,text),
  public.create_role_plan_section(date,uuid,text,text,text,text),
  public.role_plan_workspace(uuid),
  public.transition_role_plan(uuid,text),
  public.role_plan_assignment_save(uuid,uuid,jsonb),
  public.role_plan_assignment_delete(uuid,uuid),
  public.assemble_role_plans(date,text),
  public.kadromierz_import_preferences(text,jsonb),
  public.kadromierz_export(date),
  public.optimizer_prepare(date,text,text,integer),
  public.optimizer_commit(uuid,text,jsonb),
  public.optimizer_prepare_v2(date,text,text,integer),
  public.optimizer_checkpoint_v2(uuid,integer,jsonb,jsonb),
  public.optimizer_run_state_v2(uuid),
  public.optimizer_finalize_v2(uuid,text,jsonb),
  public.optimizer_save_state_v3(uuid,integer,jsonb,jsonb),
  public.optimizer_fail_v3(uuid,text),
  public.optimizer_save_init_v4(uuid,integer,jsonb,jsonb),
  public.optimizer_materialize_candidate_v3(uuid,text,jsonb),
  public.optimizer_finalize_v3(uuid,text,jsonb),
  public.optimizer_variants_v3(date),
  public.optimizer_materialize_candidate_v4(uuid,text,jsonb),
  public.optimizer_begin_finalize_v4(uuid,text,jsonb),
  public.optimizer_materialize_next_v4(uuid),
  public.optimizer_complete_finalize_v4(uuid),
  public.optimizer_abort_finalize_v4(uuid,text),
  public.optimizer_publish_company_variant_v2(uuid,uuid,text,text)
from public,anon,authenticated;

comment on function public.generate_plan(date,text,text,text,text) is
  'Retired Alpha 15 write. Kept only for immutable migration history and owner-level rollback.';
comment on function public.optimizer_prepare_v2(date,text,text,integer) is
  'Retired Alpha 15 Edge-function entrypoint; not the OR-Tools optimizer_request_v2 API.';
comment on function public.matrix_save_item(text,uuid,jsonb) is
  'Retired Alpha 15 Matrix write. Matrix v2 is the only administrative source of truth.';
comment on function public.emergency_assign(uuid,uuid,public.employee_role,boolean) is
  'Retired Alpha 15 override. Use optimizer_emergency_assign_alpha16 with diagnostics.';
comment on function public.optimizer_publish_company_variant_v2(uuid,uuid,text,text) is
  'Internal Alpha 16 publication implementation. Clients must use the audited optimizer_publish_company_variant_alpha16 boundary.';
