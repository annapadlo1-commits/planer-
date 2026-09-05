-- AUD-2026-09-01-014: add only the five evidence-backed FK indexes whose
-- tables are active in the UAT configuration/solver path. The remaining
-- advisor entries are intentionally not indexed mechanically.

create index if not exists matrix_employee_profiles_v2_employee_id_fk_idx
  on public.matrix_employee_profiles_v2 (employee_id);

create index if not exists matrix_roles_v2_category_fk_idx
  on public.matrix_roles_v2 (matrix_version_id, category_id);

create index if not exists matrix_staffing_rules_v2_role_fk_idx
  on public.matrix_staffing_rules_v2 (matrix_version_id, role_id);

create index if not exists matrix_staffing_rules_v2_duty_fk_idx
  on public.matrix_staffing_rules_v2 (matrix_version_id, duty_id);

create index if not exists matrix_strategy_objectives_v2_strategy_fk_idx
  on public.matrix_strategy_objectives_v2 (matrix_version_id, strategy_id);
