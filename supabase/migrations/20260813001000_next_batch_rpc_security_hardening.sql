-- UAT next batch: close anonymous access inherited by category-aware wrappers.
-- Authenticated execution remains the intentional application boundary; every
-- function performs its existing role and scope checks internally.

revoke all on function public.matrix_v2_workspace(date) from public,anon;
revoke all on function public.optimizer_role_composite_candidates_v2(date,uuid) from public,anon;
revoke all on function public.optimizer_role_publication_overview_uat_v2(date) from public,anon;
revoke all on function public.optimizer_role_categories_uat_v1(date) from public,anon;
revoke all on function public.matrix_v2_employee_save_uat_v4(uuid,jsonb) from public,anon;
revoke all on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) from public,anon;

grant execute on function public.matrix_v2_workspace(date) to authenticated;
grant execute on function public.optimizer_role_composite_candidates_v2(date,uuid) to authenticated;
grant execute on function public.optimizer_role_publication_overview_uat_v2(date) to authenticated;
grant execute on function public.optimizer_role_categories_uat_v1(date) to authenticated;
grant execute on function public.matrix_v2_employee_save_uat_v4(uuid,jsonb) to authenticated;
grant execute on function public.matrix_v2_admin_save_alpha16(text,uuid,jsonb) to authenticated;

notify pgrst,'reload schema';
