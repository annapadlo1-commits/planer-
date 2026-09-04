-- AUD-2026-09-01-015: consolidate the 27 exact permissive SELECT overlaps
-- observed on UAT nhthrtpkfpmufmrmdyjg at 2026-09-04T23:13:47.420Z.
--
-- Each original FOR ALL policy also participated in SELECT. The effective SELECT
-- predicate is preserved as the OR of the previous read and write predicates,
-- while INSERT, UPDATE and DELETE receive command-specific policies with the
-- unchanged write predicates. This removes only redundant policy evaluation;
-- it does not broaden or narrow any role's effective row access.

alter policy "availability_read" on "public"."employee_availability"
  using ((((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id))) or (((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id))));

drop policy "availability_manage" on "public"."employee_availability";

create policy "availability_manage_insert" on "public"."employee_availability"
  for insert to "authenticated"
  with check (((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id)));

create policy "availability_manage_update" on "public"."employee_availability"
  for update to "authenticated"
  using (((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id)))
  with check (((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id)));

create policy "availability_manage_delete" on "public"."employee_availability"
  for delete to "authenticated"
  using (((EXISTS ( SELECT 1
   FROM public.employees employee
  WHERE ((employee.id = employee_availability.employee_id) AND (employee.auth_user_id = (select auth.uid()))))) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_resource_uat_v1(NULL::uuid, NULL::uuid, employee_id)));

alter policy "hr_read" on "public"."employee_hr_profiles"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role) OR (EXISTS ( SELECT 1
   FROM public.employees e
  WHERE ((e.id = employee_hr_profiles.employee_id) AND (e.auth_user_id = (select auth.uid()))))))) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role))));

drop policy "hr_write" on "public"."employee_hr_profiles";

create policy "hr_write_insert" on "public"."employee_hr_profiles"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "hr_write_update" on "public"."employee_hr_profiles"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "hr_write_delete" on "public"."employee_hr_profiles"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

alter policy "employee_pay_rates_v2_read" on "public"."employee_pay_rates_v2"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role))) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role))));

drop policy "employee_pay_rates_v2_write" on "public"."employee_pay_rates_v2";

create policy "employee_pay_rates_v2_write_insert" on "public"."employee_pay_rates_v2"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "employee_pay_rates_v2_write_update" on "public"."employee_pay_rates_v2"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "employee_pay_rates_v2_write_delete" on "public"."employee_pay_rates_v2"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

alter policy "matrix_v2_read" on "public"."matrix_duties_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_duties_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_duties_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_duties_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_duties_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "workforce_v2_read" on "public"."matrix_employee_duties_v2"
  using (((public.matrix_v2_can_manage_employee(employee_id) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "workforce_v2_admin_write" on "public"."matrix_employee_duties_v2";

create policy "workforce_v2_admin_write_insert" on "public"."matrix_employee_duties_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_update" on "public"."matrix_employee_duties_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_delete" on "public"."matrix_employee_duties_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "workforce_v2_read" on "public"."matrix_employee_locations_v2"
  using (((public.matrix_v2_can_manage_employee(employee_id) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "workforce_v2_admin_write" on "public"."matrix_employee_locations_v2";

create policy "workforce_v2_admin_write_insert" on "public"."matrix_employee_locations_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_update" on "public"."matrix_employee_locations_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_delete" on "public"."matrix_employee_locations_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "workforce_v2_read" on "public"."matrix_employee_roles_v2"
  using (((public.matrix_v2_can_manage_employee(employee_id) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "workforce_v2_admin_write" on "public"."matrix_employee_roles_v2";

create policy "workforce_v2_admin_write_insert" on "public"."matrix_employee_roles_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_update" on "public"."matrix_employee_roles_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "workforce_v2_admin_write_delete" on "public"."matrix_employee_roles_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_employee_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_locations_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_locations_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_locations_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_locations_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_locations_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_pay_rule_duties_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_pay_rule_duties_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_pay_rule_duties_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_pay_rule_duties_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_pay_rule_duties_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_pay_rule_locations_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_pay_rule_locations_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_pay_rule_locations_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_pay_rule_locations_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_pay_rule_locations_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_locations_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_pay_rule_roles_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_pay_rule_roles_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_pay_rule_roles_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_pay_rule_roles_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_pay_rule_roles_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_pay_rule_shifts_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_pay_rule_shifts_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_pay_rule_shifts_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_pay_rule_shifts_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_pay_rule_shifts_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rule_shifts_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_pay_rules_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_pay_rules_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_pay_rules_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_pay_rules_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_pay_rules_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_pay_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_role_duties_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_role_duties_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_role_duties_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_role_duties_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_role_duties_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_role_duties_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_roles_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_roles_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_roles_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_roles_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_roles_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_roles_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_scenario_budgets_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_scenario_budgets_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_scenario_budgets_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_scenario_budgets_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_scenario_budgets_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_budgets_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "finance_matrix_v2_read" on "public"."matrix_scenario_pay_rule_overrides_v2"
  using ((((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "finance_matrix_v2_write" on "public"."matrix_scenario_pay_rule_overrides_v2";

create policy "finance_matrix_v2_write_insert" on "public"."matrix_scenario_pay_rule_overrides_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_update" on "public"."matrix_scenario_pay_rule_overrides_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "finance_matrix_v2_write_delete" on "public"."matrix_scenario_pay_rule_overrides_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_pay_rule_overrides_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_scenario_strategies_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_scenario_strategies_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_scenario_strategies_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_scenario_strategies_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_scenario_strategies_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenario_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_scenarios_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_scenarios_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_scenarios_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_scenarios_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_scenarios_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_scenarios_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_scope_grants_v2_read" on "public"."matrix_scope_grants_v2"
  using ((((auth_user_id = ( SELECT auth.uid() AS uid)) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))));

drop policy "matrix_scope_grants_v2_write" on "public"."matrix_scope_grants_v2";

create policy "matrix_scope_grants_v2_write_insert" on "public"."matrix_scope_grants_v2"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));

create policy "matrix_scope_grants_v2_write_update" on "public"."matrix_scope_grants_v2"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));

create policy "matrix_scope_grants_v2_write_delete" on "public"."matrix_scope_grants_v2"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));

alter policy "matrix_v2_read" on "public"."matrix_shift_templates_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_shift_templates_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_shift_templates_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_shift_templates_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_shift_templates_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_shift_templates_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_staffing_rules_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_staffing_rules_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_staffing_rules_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_staffing_rules_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_staffing_rules_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_staffing_rules_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_strategies_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_strategies_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_strategies_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_strategies_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_strategies_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategies_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "matrix_v2_read" on "public"."matrix_strategy_objectives_v2"
  using (((EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND ((mv.status = 'ACTIVE'::text) OR public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))))) or (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text)))))));

drop policy "matrix_v2_admin_write" on "public"."matrix_strategy_objectives_v2";

create policy "matrix_v2_admin_write_insert" on "public"."matrix_strategy_objectives_v2"
  for insert to "authenticated"
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_update" on "public"."matrix_strategy_objectives_v2"
  for update to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))))
  with check (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

create policy "matrix_v2_admin_write_delete" on "public"."matrix_strategy_objectives_v2"
  for delete to "authenticated"
  using (((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)) AND (EXISTS ( SELECT 1
   FROM public.matrix_versions mv
  WHERE ((mv.id = matrix_strategy_objectives_v2.matrix_version_id) AND (mv.status = 'DRAFT'::text))))));

alter policy "authenticated_reads_budgets" on "public"."monthly_budgets"
  using ((true) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role))));

drop policy "managers_manage_budgets" on "public"."monthly_budgets";

create policy "managers_manage_budgets_insert" on "public"."monthly_budgets"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "managers_manage_budgets_update" on "public"."monthly_budgets"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

create policy "managers_manage_budgets_delete" on "public"."monthly_budgets"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.has_app_role('HR_FINANCE'::public.app_role)));

alter policy "authenticated_reads_events" on "public"."operational_events"
  using ((true) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_legacy_resource_uat_v1(NULL::text, location_id, NULL::uuid))));

drop policy "managers_manage_events" on "public"."operational_events";

create policy "managers_manage_events_insert" on "public"."operational_events"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_legacy_resource_uat_v1(NULL::text, location_id, NULL::uuid)));

create policy "managers_manage_events_update" on "public"."operational_events"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_legacy_resource_uat_v1(NULL::text, location_id, NULL::uuid)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_legacy_resource_uat_v1(NULL::text, location_id, NULL::uuid)));

create policy "managers_manage_events_delete" on "public"."operational_events"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role) OR public.matrix_v2_can_manage_legacy_resource_uat_v1(NULL::text, location_id, NULL::uuid)));

alter policy "solver_feature_flags_read" on "public"."solver_feature_flags"
  using ((true) or ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role))));

drop policy "solver_feature_flags_write" on "public"."solver_feature_flags";

create policy "solver_feature_flags_write_insert" on "public"."solver_feature_flags"
  for insert to "authenticated"
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));

create policy "solver_feature_flags_write_update" on "public"."solver_feature_flags"
  for update to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)))
  with check ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));

create policy "solver_feature_flags_write_delete" on "public"."solver_feature_flags"
  for delete to "authenticated"
  using ((public.has_app_role('OWNER'::public.app_role) OR public.has_app_role('ADMIN'::public.app_role)));
