select
  current_database() as database_name,
  current_user as database_user,
  current_setting('app.settings.project_ref', true) as project_ref,
  to_regprocedure('public.matrix_v2_admin_save_alpha16(text,uuid,jsonb)') is not null as has_matrix_save,
  to_regprocedure('public.optimizer_leader_assignment_save_uat_v2(uuid,uuid,bigint,uuid,text,boolean,uuid)') is not null as has_leader_save_v2,
  to_regprocedure('solver_private.generate_standby_for_variant_uat_v2(uuid,date,uuid,uuid,uuid,uuid)') is not null as has_standby_generator,
  to_regclass('public.published_standby_assignments_v2') is not null as has_standby_table;
