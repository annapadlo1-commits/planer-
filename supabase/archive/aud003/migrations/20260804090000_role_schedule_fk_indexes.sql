-- Cover role-schedule foreign keys used by publication history, owner
-- analytics and archive cleanup. The partial current-month uniqueness index
-- intentionally has month as its leading column and therefore does not cover
-- lookups that start from role_id.

create index published_role_schedules_v2_matrix_version_idx
  on public.published_role_schedules_v2(matrix_version_id);

create index published_role_schedules_v2_scenario_month_idx
  on public.published_role_schedules_v2(scenario_id,month);

create index published_role_schedules_v2_role_month_idx
  on public.published_role_schedules_v2(role_id,month);

create index published_role_schedules_v2_archived_by_idx
  on public.published_role_schedules_v2(archived_by)
  where archived_by is not null;
