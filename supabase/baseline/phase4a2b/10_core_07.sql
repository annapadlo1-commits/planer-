-- Generated Phase 4A.2B neutral schema baseline.
-- Apply only to a fresh, isolated Supabase project through the reviewed runner.

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET transaction_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: FUNCTION "solver_contract_parity_probe_uat_v1"("p_variant_templates" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_contract_parity_probe_uat_v1"("p_variant_templates" "jsonb", "p_gateway_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_contract_parity_probe_uat_v1"("p_variant_templates" "jsonb", "p_gateway_version" "text") TO "service_role";


--
-- Name: FUNCTION "solver_dispatch_inspect_uat_v1"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_dispatch_inspect_uat_v1"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_dispatch_inspect_uat_v1"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "solver_dispatch_reserve_uat_v1"("p_dispatcher_version" "text", "p_lease_seconds" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_dispatch_reserve_uat_v1"("p_dispatcher_version" "text", "p_lease_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_dispatch_reserve_uat_v1"("p_dispatcher_version" "text", "p_lease_seconds" integer) TO "service_role";


--
-- Name: FUNCTION "solver_dispatch_result_uat_v1"("p_run_id" "uuid", "p_dispatch_lease_token" "uuid", "p_outcome" "text", "p_northflank_run_id" "text", "p_http_status" integer, "p_error_code" "text", "p_error_message" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_dispatch_result_uat_v1"("p_run_id" "uuid", "p_dispatch_lease_token" "uuid", "p_outcome" "text", "p_northflank_run_id" "text", "p_http_status" integer, "p_error_code" "text", "p_error_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_dispatch_result_uat_v1"("p_run_id" "uuid", "p_dispatch_lease_token" "uuid", "p_outcome" "text", "p_northflank_run_id" "text", "p_http_status" integer, "p_error_code" "text", "p_error_message" "text") TO "service_role";


--
-- Name: FUNCTION "solver_fail_attempt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_fail_attempt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) FROM PUBLIC;


--
-- Name: FUNCTION "solver_fail_attempt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_fail_attempt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_fail_attempt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_error_code" "text", "p_error_message" "text", "p_retryable" boolean) TO "service_role";


--
-- Name: FUNCTION "solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."solver_feature_flag_set"("p_engine" "text", "p_config" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "solver_finalize_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_finalize_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "solver_finalize_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_finalize_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_finalize_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") TO "service_role";


--
-- Name: FUNCTION "solver_heartbeat_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_heartbeat_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "solver_heartbeat_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_heartbeat_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_heartbeat_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_progress" "jsonb") TO "service_role";


--
-- Name: FUNCTION "solver_interrupt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_interrupt_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") FROM PUBLIC;


--
-- Name: FUNCTION "solver_interrupt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_interrupt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_interrupt_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "solver_job_contract_probe_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_job_contract_probe_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_job_contract_probe_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "solver_job_dispatcher_control_uat_v1"("p_enabled" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_job_dispatcher_control_uat_v1"("p_enabled" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_job_dispatcher_control_uat_v1"("p_enabled" boolean) TO "service_role";


--
-- Name: FUNCTION "solver_job_reconcile_candidates_uat_v1"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_job_reconcile_candidates_uat_v1"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_job_reconcile_candidates_uat_v1"("p_limit" integer) TO "service_role";


--
-- Name: FUNCTION "solver_job_reconcile_uat_v1"("p_run_id" "uuid", "p_northflank_run_id" "text", "p_northflank_status" "text", "p_container_started_at" timestamp with time zone, "p_job_finished_at" timestamp with time zone, "p_peak_rss_mb" numeric, "p_average_rss_mb" numeric, "p_peak_cpu_percent" numeric, "p_failure_code" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_job_reconcile_uat_v1"("p_run_id" "uuid", "p_northflank_run_id" "text", "p_northflank_status" "text", "p_container_started_at" timestamp with time zone, "p_job_finished_at" timestamp with time zone, "p_peak_rss_mb" numeric, "p_average_rss_mb" numeric, "p_peak_cpu_percent" numeric, "p_failure_code" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_job_reconcile_uat_v1"("p_run_id" "uuid", "p_northflank_run_id" "text", "p_northflank_status" "text", "p_container_started_at" timestamp with time zone, "p_job_finished_at" timestamp with time zone, "p_peak_rss_mb" numeric, "p_average_rss_mb" numeric, "p_peak_cpu_percent" numeric, "p_failure_code" "text") TO "service_role";


--
-- Name: FUNCTION "solver_job_watchdog_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_job_watchdog_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_job_watchdog_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "solver_load_snapshot_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_load_snapshot_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_load_snapshot_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid") TO "service_role";


--
-- Name: FUNCTION "solver_save_variant_before_b4f168"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_before_b4f168"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") FROM PUBLIC;


--
-- Name: FUNCTION "solver_save_variant_before_b4f169"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_before_b4f169"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") FROM PUBLIC;


--
-- Name: FUNCTION "solver_save_variant_before_b4f170"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_before_b4f170"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") FROM PUBLIC;


--
-- Name: FUNCTION "solver_save_variant_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_before_nfjob_uat_v1"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") FROM PUBLIC;


--
-- Name: FUNCTION "solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_save_variant_v2"("p_run_id" "uuid", "p_attempt_id" "uuid", "p_lease_token" "uuid", "p_variant" "jsonb", "p_gateway_version" "text") TO "service_role";


--
-- Name: FUNCTION "standby_activate_before_phase1_uat_v1"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."standby_activate_before_phase1_uat_v1"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."standby_activate_before_phase1_uat_v1"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."standby_activate_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."standby_activate_uat_v3"("p_standby_id" "uuid", "p_original_assignment_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."standby_decline_self_uat_v2"("p_standby_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "transition_role_plan"("p_section_id" "uuid", "p_status" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."transition_role_plan"("p_section_id" "uuid", "p_status" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."transition_role_plan"("p_section_id" "uuid", "p_status" "text") TO "service_role";


--
-- Name: FUNCTION "uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_master_employee_availability_days_save_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_master_employee_portal_context_v2"("p_employee_id" "uuid", "p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_master_employee_shift_preferences_save_v2"("p_employee_id" "uuid", "p_month" "date", "p_preferences" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "uat_master_persona_preview_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_master_persona_preview_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_master_persona_preview_v2"() TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_master_persona_preview_v2"() TO "authenticated";


--
-- Name: FUNCTION "uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_master_persona_select_v2"("p_persona" "text", "p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "uat_matrix_workforce_reset_preview_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_matrix_workforce_reset_preview_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_matrix_workforce_reset_preview_v2"() TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_matrix_workforce_reset_preview_v2"() TO "authenticated";


--
-- Name: FUNCTION "uat_matrix_workforce_reset_v2"("p_confirmation" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."uat_matrix_workforce_reset_v2"("p_confirmation" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."uat_matrix_workforce_reset_v2"("p_confirmation" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."uat_matrix_workforce_reset_v2"("p_confirmation" "text") TO "authenticated";


--
-- Name: FUNCTION "workforce_calendar_context_base_b4f89"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_context_base_b4f89"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_base_b4f89"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "workforce_calendar_context_base_uat006"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_context_base_uat006"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_base_uat006"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "workforce_calendar_context_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_context_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "workforce_calendar_context_uat_v3"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_context_uat_v3"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v3"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v3"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "workforce_calendar_context_uat_v4"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."workforce_calendar_context_uat_v4"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "workforce_calendar_event_range_save_before_phase1_uat_v1"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_event_range_save_before_phase1_uat_v1"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_range_save_before_phase1_uat_v1"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "service_role";


--
-- Name: FUNCTION "workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_range_save_uat_v2"("p_month" "date", "p_start_date" "date", "p_end_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "workforce_calendar_event_save_before_phase1_uat_v1"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_event_save_before_phase1_uat_v1"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_save_before_phase1_uat_v1"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "service_role";


--
-- Name: FUNCTION "workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."workforce_calendar_event_save_uat_v2"("p_event_id" "uuid", "p_month" "date", "p_event_date" "date", "p_event_kind" "text", "p_title" "text", "p_description" "text", "p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "activate_matrix_employee_profiles_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."activate_matrix_employee_profiles_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."activate_matrix_employee_profiles_v2"() TO "service_role";


--
-- Name: FUNCTION "active_ortools_solver_version_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."active_ortools_solver_version_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."active_ortools_solver_version_v2"() TO "service_role";


--
-- Name: FUNCTION "alpha16_can_manage_schedule_v2"("p_schedule_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."alpha16_can_manage_schedule_v2"("p_schedule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."alpha16_can_manage_schedule_v2"("p_schedule_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "alpha16_enrich_workspace_issues_v2"("p_workspace" "jsonb", "p_variant_ids" "uuid"[]); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."alpha16_enrich_workspace_issues_v2"("p_workspace" "jsonb", "p_variant_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."alpha16_enrich_workspace_issues_v2"("p_workspace" "jsonb", "p_variant_ids" "uuid"[]) TO "service_role";


--
-- Name: FUNCTION "alpha16_preference_level_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_period" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."alpha16_preference_level_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_period" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."alpha16_preference_level_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_period" "text") TO "service_role";


--
-- Name: FUNCTION "alpha16_shift_period_default_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."alpha16_shift_period_default_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."alpha16_shift_period_default_v2"() TO "service_role";


--
-- Name: FUNCTION "alpha16_shift_rules_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."alpha16_shift_rules_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."alpha16_shift_rules_v2"("p_employee_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date") TO "service_role";


--
-- Name: FUNCTION "apply_integer_operations_v2"("p_operations" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."apply_integer_operations_v2"("p_operations" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."apply_integer_operations_v2"("p_operations" "jsonb") TO "service_role";


--
-- Name: FUNCTION "apply_strategy_semantics_b4f165"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."apply_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "apply_strategy_semantics_b4f168"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."apply_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "apply_strategy_semantics_b4f169"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."apply_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "apply_strategy_semantics_b4f170"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."apply_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "archive_current_publication_v2"("p_month" "date", "p_keep_variant_ids" "uuid"[], "p_actor" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."archive_current_publication_v2"("p_month" "date", "p_keep_variant_ids" "uuid"[], "p_actor" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."archive_current_publication_v2"("p_month" "date", "p_keep_variant_ids" "uuid"[], "p_actor" "uuid") TO "service_role";


--
-- Name: FUNCTION "assert_configuration_v2"("p_condition" boolean, "p_error" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."assert_configuration_v2"("p_condition" boolean, "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."assert_configuration_v2"("p_condition" boolean, "p_error" "text") TO "service_role";


--
-- Name: FUNCTION "assert_employment_pay_rate_period_uat_v1"("p_employee_id" "uuid", "p_employment_start" "date", "p_employment_end" "date", "p_rate_valid_from" "date", "p_rate_valid_to" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."assert_employment_pay_rate_period_uat_v1"("p_employee_id" "uuid", "p_employment_start" "date", "p_employment_end" "date", "p_rate_valid_from" "date", "p_rate_valid_to" "date") FROM PUBLIC;


--
-- Name: FUNCTION "assert_materialized_variant_metadata_v2"("p_variant_id" "uuid", "p_snapshot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."assert_materialized_variant_metadata_v2"("p_variant_id" "uuid", "p_snapshot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."assert_materialized_variant_metadata_v2"("p_variant_id" "uuid", "p_snapshot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "assert_uat_master_persona_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."assert_uat_master_persona_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "assignment_is_currently_published_v2"("p_assignment_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."assignment_is_currently_published_v2"("p_assignment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."assignment_is_currently_published_v2"("p_assignment_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_run_version_stamp_uat_v1"("p_run_id" "uuid", "p_frontend_commit" "text", "p_execution_mode" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_run_version_stamp_uat_v1"("p_run_id" "uuid", "p_frontend_commit" "text", "p_execution_mode" "text") FROM PUBLIC;


--
-- Name: FUNCTION "build_snapshot_payload_before_alpha16_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_alpha16_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_alpha16_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_authoritative_external_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_authoritative_external_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_authoritative_external_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_b4_settings_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4_settings_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4_settings_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f165"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_b4f169"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f169"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "build_snapshot_payload_before_b4f170"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f170"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "build_snapshot_payload_before_b4f88_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f88_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f88_uat_v1"("p_matrix_version_id" "uuid", "p_month" "date", "p_scenario_id" "uuid", "p_scope_role_id" "uuid", "p_scope_type" "text", "p_actor" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_b4f91_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_categories_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_categories_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_categories_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_category_employee_guard_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_category_employee_guard_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_category_employee_guard_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_explicit_roles_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_explicit_roles_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_explicit_roles_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_final_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_final_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_final_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_final_slot_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_final_slot_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_final_slot_contract_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_monthly_budget_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_monthly_budget_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_monthly_budget_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_occurrence_id_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_occurrence_id_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_occurrence_id_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_overtime_pricing_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_overtime_pricing_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_overtime_pricing_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_overtime_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_overtime_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_overtime_uat_v1"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_primary_shift_invariants_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_primary_shift_invariants_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_primary_shift_invariants_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_before_slot_contract_fix_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_slot_contract_fix_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_before_slot_contract_fix_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "build_snapshot_payload_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."build_snapshot_payload_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."build_snapshot_payload_v2"("p_run_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "bump_planning_revision_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."bump_planning_revision_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "can_access_run_v2"("p_run_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."can_access_run_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."can_access_run_v2"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "can_edit_leader_variant_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."can_edit_leader_variant_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "canonical_json_v2"("p_value" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."canonical_json_v2"("p_value" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."canonical_json_v2"("p_value" "jsonb") TO "service_role";


--
-- Name: FUNCTION "capture_leader_variant_history_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."capture_leader_variant_history_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "changed_variant_employees_uat_v1"("p_old_variant_ids" "uuid"[], "p_new_variant_ids" "uuid"[]); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."changed_variant_employees_uat_v1"("p_old_variant_ids" "uuid"[], "p_new_variant_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."changed_variant_employees_uat_v1"("p_old_variant_ids" "uuid"[], "p_new_variant_ids" "uuid"[]) TO "service_role";


--
-- Name: FUNCTION "employee_pay_rate_covers_period_v2"("p_employee_id" "uuid", "p_from" "date", "p_to" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."employee_pay_rate_covers_period_v2"("p_employee_id" "uuid", "p_from" "date", "p_to" "date") FROM PUBLIC;


--
-- Name: FUNCTION "employee_weekly_pattern_allows_uat_v1"("p_employee_id" "uuid", "p_shift_date" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_role_id" "uuid", "p_location_id" "uuid", "p_timezone" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."employee_weekly_pattern_allows_uat_v1"("p_employee_id" "uuid", "p_shift_date" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_role_id" "uuid", "p_location_id" "uuid", "p_timezone" "text") FROM PUBLIC;


--
-- Name: FUNCTION "enforce_run_version_stamp_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."enforce_run_version_stamp_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "expected_pay_components_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."expected_pay_components_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."expected_pay_components_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "generate_published_standby_trigger_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."generate_published_standby_trigger_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "generate_standby_before_shortage_guard_uat_v1"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."generate_standby_before_shortage_guard_uat_v1"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."generate_standby_before_shortage_guard_uat_v1"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "generate_standby_for_variant_before_b4_default_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."generate_standby_for_variant_before_b4_default_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "generate_standby_for_variant_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."generate_standby_for_variant_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."generate_standby_for_variant_uat_v2"("p_variant_id" "uuid", "p_month" "date", "p_matrix_version_id" "uuid", "p_role_id" "uuid", "p_source_schedule_id" "uuid", "p_source_role_schedule_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "guard_active_variant_selection_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_active_variant_selection_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_active_variant_selection_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_employee_pay_rate_employment_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_employee_pay_rate_employment_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "guard_employee_profile_pay_rates_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_employee_profile_pay_rates_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "guard_leader_variant_publication_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_leader_variant_publication_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "guard_legacy_plan_publication_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_legacy_plan_publication_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_legacy_plan_publication_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_matrix_child_immutable_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_matrix_child_immutable_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_matrix_child_immutable_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_matrix_employee_profile_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_matrix_employee_profile_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_matrix_employee_profile_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_matrix_version_immutable_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_matrix_version_immutable_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_matrix_version_immutable_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_production_variant_link_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_production_variant_link_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_production_variant_link_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_publication_variant_link_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_publication_variant_link_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_publication_variant_link_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_published_variant_assignment_child_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_published_variant_direct_child_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_published_variant_direct_child_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_published_variant_direct_child_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_published_variant_row_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_published_variant_row_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_published_variant_row_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_run_provenance_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_run_provenance_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."guard_run_provenance_v2"() TO "service_role";


--
-- Name: FUNCTION "guard_strategy_semantics_b4f165"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."guard_strategy_semantics_b4f165"() FROM PUBLIC;


--
-- Name: FUNCTION "jsonb_deep_merge_array_v2"("p_values" "jsonb"[]); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."jsonb_deep_merge_array_v2"("p_values" "jsonb"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."jsonb_deep_merge_array_v2"("p_values" "jsonb"[]) TO "service_role";


--
-- Name: FUNCTION "jsonb_deep_merge_v2"("p_base" "jsonb", "p_override" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."jsonb_deep_merge_v2"("p_base" "jsonb", "p_override" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."jsonb_deep_merge_v2"("p_base" "jsonb", "p_override" "jsonb") TO "service_role";


--
-- Name: FUNCTION "leader_overtime_candidate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."leader_overtime_candidate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."leader_overtime_candidate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "leader_variant_snapshot_v2"("p_variant_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."leader_variant_snapshot_v2"("p_variant_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "lock_planning_revision_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."lock_planning_revision_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."lock_planning_revision_v2"() TO "service_role";


--
-- Name: FUNCTION "materialized_variant_payload_v2"("p_variant_ids" "uuid"[], "p_snapshot" "jsonb", "p_strategy_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."materialized_variant_payload_v2"("p_variant_ids" "uuid"[], "p_snapshot" "jsonb", "p_strategy_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."materialized_variant_payload_v2"("p_variant_ids" "uuid"[], "p_snapshot" "jsonb", "p_strategy_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."matrix_covers_planning_month_uat_v1"("p_effective_from" "date", "p_month" "date") TO "service_role";


--
-- Name: FUNCTION "matrix_employee_role_semantics_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_employee_role_semantics_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_assert_workbook_identity_uat_v1"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_assert_workbook_identity_uat_v1"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_discard_decision_uat_v1"("p_draft_count" integer, "p_active_count" integer); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_discard_decision_uat_v1"("p_draft_count" integer, "p_active_count" integer) FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_full_finance_payload_uat_v1"("p_finance" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_finance_payload_uat_v1"("p_finance" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_full_import_configuration_uat_v2"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_configuration_uat_v2"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_full_import_phase_before_categories_uat_v1"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_categories_uat_v1"("p_configuration" "jsonb", "p_phase" "text") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v"("p_configuration" "jsonb", "p_phase" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_empty_dictionary_guard_uat_v"("p_configuration" "jsonb", "p_phase" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_full_import_phase_before_explicit_roles_uat_v1"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_explicit_roles_uat_v1"("p_configuration" "jsonb", "p_phase" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_explicit_roles_uat_v1"("p_configuration" "jsonb", "p_phase" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_full_import_phase_before_overtime_uat_v1"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_overtime_uat_v1"("p_configuration" "jsonb", "p_phase" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_before_overtime_uat_v1"("p_configuration" "jsonb", "p_phase" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_full_import_phase_raw_uat_v1"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_raw_uat_v1"("p_configuration" "jsonb", "p_phase" "text") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_full_import_phase_uat_v1"("p_configuration" "jsonb", "p_phase" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON FUNCTION "solver_private"."matrix_v2_full_import_phase_uat_v1"("p_configuration" "jsonb", "p_phase" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_import_normalize_uat_v3"("p_payload" "jsonb", "p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_import_normalize_uat_v3"("p_payload" "jsonb", "p_matrix_version_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."matrix_v2_import_normalize_uat_v3"("p_payload" "jsonb", "p_matrix_version_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_reconnect_preserved_profiles_uat_v1"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_import_shifts_uat_v1"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_import_shifts_uat_v1"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_required_defaults_before_b4f165"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f165"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_required_defaults_before_b4f168"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f168"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_required_defaults_before_b4f169"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f169"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_required_defaults_before_b4f170"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_required_defaults_before_b4f170"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_seed_required_defaults_uat_v1"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_seed_required_defaults_uat_v1"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_team_configuration_uat_v1"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_team_import_configuration_uat_v2"("p_configuration" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."matrix_v2_team_import_configuration_uat_v2"("p_configuration" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "mx_k10_legacy_role_duty_payload_v1"("p_row" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."mx_k10_legacy_role_duty_payload_v1"("p_row" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "normalize_initial_matrix_month_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."normalize_initial_matrix_month_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "normalize_personal_notification_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."normalize_personal_notification_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."optimizer_publish_company_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."optimizer_publish_role_composite_pre_version_fence_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_request_stamped_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text", "p_execution_mode" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."optimizer_request_stamped_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text", "p_execution_mode" "text") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_select_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."optimizer_select_variant_pre_version_fence_v2"("p_run_id" "uuid", "p_variant_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "pay_condition_matches_v2"("p_condition" "jsonb", "p_snapshot" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."pay_condition_matches_v2"("p_condition" "jsonb", "p_snapshot" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."pay_condition_matches_v2"("p_condition" "jsonb", "p_snapshot" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "pay_rule_billable_minutes_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_slot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."pay_rule_billable_minutes_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_slot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."pay_rule_billable_minutes_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_slot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "pay_rule_matches_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."pay_rule_matches_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."pay_rule_matches_v2"("p_snapshot" "jsonb", "p_rule" "jsonb", "p_employee" "jsonb", "p_slot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "publication_authority_guard_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."publication_authority_guard_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "publication_snapshot_basis_v2"("p_snapshot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."publication_snapshot_basis_v2"("p_snapshot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."publication_snapshot_basis_v2"("p_snapshot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "publication_snapshot_hash_v2"("p_snapshot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."publication_snapshot_hash_v2"("p_snapshot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."publication_snapshot_hash_v2"("p_snapshot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "publication_static_input_hash_v2"("p_snapshot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."publication_static_input_hash_v2"("p_snapshot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."publication_static_input_hash_v2"("p_snapshot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "published_variant_is_frozen_v2"("p_variant_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."published_variant_is_frozen_v2"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."published_variant_is_frozen_v2"("p_variant_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "rebuild_standby_month_v2"("p_month" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."rebuild_standby_month_v2"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "record_leader_variant_history_v2"("p_variant_id" "uuid", "p_revision" integer, "p_label" "text", "p_actor" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."record_leader_variant_history_v2"("p_variant_id" "uuid", "p_revision" integer, "p_label" "text", "p_actor" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "recover_expired_solver_runs_v2"("p_limit" integer); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."recover_expired_solver_runs_v2"("p_limit" integer) FROM PUBLIC;


--
-- Name: FUNCTION "recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."recovery_candidate_snapshot_uat_v1"("p_month" "date", "p_shift_id" "uuid", "p_role_id" "uuid", "p_duty_id" "uuid", "p_excluded_employee_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."recovery_clone_published_variant_uat_v1"("p_source_variant_id" "uuid", "p_name" "text") FROM PUBLIC;


--
-- Name: FUNCTION "redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."redact_workspace_finance_uat_v1"("p_payload" "jsonb", "p_visibility" "text") FROM PUBLIC;


--
-- Name: FUNCTION "refresh_leader_variant_uat_v1"("p_variant_id" "uuid", "p_actor" "uuid", "p_reason" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."refresh_leader_variant_uat_v1"("p_variant_id" "uuid", "p_actor" "uuid", "p_reason" "text") FROM PUBLIC;


--
-- Name: FUNCTION "replace_time_constraint_v2"("p_employee_id" "uuid", "p_kind" "text", "p_time_range" "tstzrange", "p_source" "text", "p_source_record_key" "text", "p_note" "text", "p_actor" "uuid", "p_updated_at" timestamp with time zone); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."replace_time_constraint_v2"("p_employee_id" "uuid", "p_kind" "text", "p_time_range" "tstzrange", "p_source" "text", "p_source_record_key" "text", "p_note" "text", "p_actor" "uuid", "p_updated_at" timestamp with time zone) FROM PUBLIC;


--
-- Name: FUNCTION "requote_variant_payload_v2"("p_snapshot" "jsonb", "p_payload" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."requote_variant_payload_v2"("p_snapshot" "jsonb", "p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."requote_variant_payload_v2"("p_snapshot" "jsonb", "p_payload" "jsonb") TO "service_role";


--
-- Name: FUNCTION "reset_retry_outputs_v2"("p_run_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."reset_retry_outputs_v2"("p_run_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "resolve_budget_operations_v2"("p_operations" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."resolve_budget_operations_v2"("p_operations" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."resolve_budget_operations_v2"("p_operations" "jsonb") TO "service_role";


--
-- Name: FUNCTION "resolved_budgets_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."resolved_budgets_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."resolved_budgets_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."resolved_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "resolved_matrix_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."resolved_matrix_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."resolved_matrix_demand_v2"("p_month" "date", "p_matrix_version_id" "uuid", "p_scenario_id" "uuid", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean) TO "service_role";


--
-- Name: FUNCTION "revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean, "p_validate_hard" boolean); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean, "p_validate_hard" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."revalidate_materialized_variant_v2"("p_variant_id" "uuid", "p_neutralize_external" boolean, "p_validate_hard" boolean) TO "service_role";


--
-- Name: FUNCTION "role_composite_consistency_guard_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."role_composite_consistency_guard_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "run_status_payload_v2"("p_run_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."run_status_payload_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."run_status_payload_v2"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "schedule_primary_conflict_reasons_uat_v2"("p_schedule_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."schedule_primary_conflict_reasons_uat_v2"("p_schedule_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "seed_matrix_employee_profiles_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."seed_matrix_employee_profiles_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."seed_matrix_employee_profiles_v2"() TO "service_role";


--
-- Name: FUNCTION "shift_swap_personal_notifications_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."shift_swap_personal_notifications_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "shift_template_is_sequence_edge_uat_v2"("p_matrix_version_id" "uuid", "p_shift_template_id" "uuid", "p_shift_date" "date", "p_edge" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."shift_template_is_sequence_edge_uat_v2"("p_matrix_version_id" "uuid", "p_shift_template_id" "uuid", "p_shift_date" "date", "p_edge" "text") FROM PUBLIC;


--
-- Name: FUNCTION "slot_timezone_v2"("p_snapshot" "jsonb", "p_slot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."slot_timezone_v2"("p_snapshot" "jsonb", "p_slot" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."slot_timezone_v2"("p_snapshot" "jsonb", "p_slot" "jsonb") TO "service_role";


--
-- Name: FUNCTION "staffing_duty_link_guard_uat006"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."staffing_duty_link_guard_uat006"() FROM PUBLIC;


--
-- Name: FUNCTION "standby_activation_reasons_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."standby_activation_reasons_uat_v2"("p_standby_id" "uuid", "p_original_assignment_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "standby_candidates_for_group_day_uat_v1"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_ids" "uuid"[], "p_date" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."standby_candidates_for_group_day_uat_v1"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_ids" "uuid"[], "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."standby_candidates_for_group_day_uat_v1"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_ids" "uuid"[], "p_date" "date") TO "service_role";


--
-- Name: FUNCTION "standby_candidates_for_role_day_uat_v3"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_id" "uuid", "p_date" "date"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."standby_candidates_for_role_day_uat_v3"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_id" "uuid", "p_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."standby_candidates_for_role_day_uat_v3"("p_variant_id" "uuid", "p_matrix_version_id" "uuid", "p_month" "date", "p_role_id" "uuid", "p_date" "date") TO "service_role";


--
-- Name: FUNCTION "strategy_config_hash_uat_v1"("p_snapshot" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."strategy_config_hash_uat_v1"("p_snapshot" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "strip_temporal_json_uat_v1"("p_value" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."strip_temporal_json_uat_v1"("p_value" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "supersede_standby_with_source_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."supersede_standby_with_source_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "swap_alternate_duty_coverage_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."swap_alternate_duty_coverage_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "swap_candidate_reasons_direct_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."swap_candidate_reasons_direct_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."swap_candidate_reasons_direct_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "swap_candidate_reasons_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."swap_candidate_reasons_uat_v2"("p_request_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "swap_history_coverage_uat006"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."swap_history_coverage_uat006"() FROM PUBLIC;


--
-- Name: FUNCTION "sync_employee_availability_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."sync_employee_availability_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "sync_employee_preference_v2"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."sync_employee_preference_v2"() FROM PUBLIC;


--
-- Name: FUNCTION "sync_leader_workflow_published_uat_v1"(); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."sync_leader_workflow_published_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "uat_master_employee_constraints_v2"("p_employee_id" "uuid", "p_month" "date", "p_matrix" "uuid", "p_timezone" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."uat_master_employee_constraints_v2"("p_employee_id" "uuid", "p_month" "date", "p_matrix" "uuid", "p_timezone" "text") FROM PUBLIC;


--
-- Name: FUNCTION "uat_master_save_employee_day_v2"("p_actor" "uuid", "p_employee_id" "uuid", "p_day" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."uat_master_save_employee_day_v2"("p_actor" "uuid", "p_employee_id" "uuid", "p_day" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") FROM PUBLIC;


--
-- Name: FUNCTION "validate_stage_proof_b4f166"("p_stage_proof" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_stage_proof_b4f166"("p_stage_proof" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "validate_strategy_semantics_b4f165"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_strategy_semantics_b4f165"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "validate_strategy_semantics_b4f168"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_strategy_semantics_b4f168"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "validate_strategy_semantics_b4f169"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_strategy_semantics_b4f169"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "validate_strategy_semantics_b4f170"("p_matrix_version_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_strategy_semantics_b4f170"("p_matrix_version_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "validate_variant_before_b4f164_overtime_policy_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_before_b4f164_overtime_policy_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_before_b4f164_overtime_policy_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "validate_variant_before_daily_limit_period_guard_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_before_daily_limit_period_guard_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_before_daily_limit_period_guard_uat_v1"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "validate_variant_before_final_contract_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_before_final_contract_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_before_final_contract_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "validate_variant_before_leader_limit_override_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_before_leader_limit_override_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_before_leader_limit_override_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "validate_variant_before_primary_shift_invariants_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_before_primary_shift_invariants_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_before_primary_shift_invariants_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."validate_variant_v2"("p_snapshot" "jsonb", "p_variant" "jsonb") TO "service_role";


--
-- Name: FUNCTION "variant_primary_conflict_reasons_uat_v2"("p_variant_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."variant_primary_conflict_reasons_uat_v2"("p_variant_id" "uuid", "p_employee_id" "uuid", "p_shift_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "variant_set_workspace_v2"("p_variant_ids" "uuid"[], "p_context" "jsonb", "p_can_view_finance" boolean); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."variant_set_workspace_v2"("p_variant_ids" "uuid"[], "p_context" "jsonb", "p_can_view_finance" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "solver_private"."variant_set_workspace_v2"("p_variant_ids" "uuid"[], "p_context" "jsonb", "p_can_view_finance" boolean) TO "service_role";


--
-- Name: FUNCTION "version_stamp_set_once_uat_v1"("p_stamp" "jsonb", "p_key" "text", "p_value" "jsonb"); Type: ACL; Schema: solver_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "solver_private"."version_stamp_set_once_uat_v1"("p_stamp" "jsonb", "p_key" "text", "p_value" "jsonb") FROM PUBLIC;


--
-- Name: TABLE "application_access_directory_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."application_access_directory_v1" TO "service_role";


--
-- Name: TABLE "application_finance_visibility_policy_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."application_finance_visibility_policy_v1" TO "service_role";


--
-- Name: TABLE "assignments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."assignments" TO "anon";
GRANT ALL ON TABLE "public"."assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."assignments" TO "service_role";


--
-- Name: TABLE "attendance_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."attendance_events" TO "anon";
GRANT ALL ON TABLE "public"."attendance_events" TO "authenticated";
GRANT ALL ON TABLE "public"."attendance_events" TO "service_role";


--
-- Name: TABLE "audit_log"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."audit_log" TO "service_role";


--
-- Name: SEQUENCE "audit_log_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."audit_log_id_seq" TO "service_role";


--
-- Name: TABLE "availability_exception_reviews_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."availability_exception_reviews_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."availability_exception_reviews_v2" TO "authenticated";


--
-- Name: TABLE "business_app_integrations_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."business_app_integrations_v1" TO "service_role";


--
-- Name: TABLE "composite_schedules"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."composite_schedules" TO "anon";
GRANT ALL ON TABLE "public"."composite_schedules" TO "authenticated";
GRANT ALL ON TABLE "public"."composite_schedules" TO "service_role";


--
-- Name: TABLE "demand_rules"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."demand_rules" TO "anon";
GRANT ALL ON TABLE "public"."demand_rules" TO "authenticated";
GRANT ALL ON TABLE "public"."demand_rules" TO "service_role";


--
-- Name: TABLE "employee_availability"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_availability" TO "anon";
GRANT ALL ON TABLE "public"."employee_availability" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_availability" TO "service_role";


--
-- Name: TABLE "employee_availability_history"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_availability_history" TO "anon";
GRANT ALL ON TABLE "public"."employee_availability_history" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_availability_history" TO "service_role";


--
-- Name: TABLE "employee_capabilities"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_capabilities" TO "anon";
GRANT ALL ON TABLE "public"."employee_capabilities" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_capabilities" TO "service_role";


--
-- Name: TABLE "employee_hr_profiles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_hr_profiles" TO "anon";
GRANT ALL ON TABLE "public"."employee_hr_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_hr_profiles" TO "service_role";


--
-- Name: TABLE "employee_locations"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_locations" TO "anon";
GRANT ALL ON TABLE "public"."employee_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_locations" TO "service_role";


--
-- Name: TABLE "employee_pay_rates_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_pay_rates_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."employee_pay_rates_v2" TO "authenticated";


--
-- Name: TABLE "employee_preferences"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_preferences" TO "anon";
GRANT ALL ON TABLE "public"."employee_preferences" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_preferences" TO "service_role";


--
-- Name: TABLE "employee_requests_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_requests_v1" TO "service_role";
GRANT SELECT ON TABLE "public"."employee_requests_v1" TO "authenticated";


--
-- Name: TABLE "employee_time_constraints_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_time_constraints_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."employee_time_constraints_v2" TO "authenticated";


--
-- Name: TABLE "employee_weekly_work_patterns_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employee_weekly_work_patterns_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."employee_weekly_work_patterns_v2" TO "service_role";


--
-- Name: TABLE "employees"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employees" TO "anon";
GRANT ALL ON TABLE "public"."employees" TO "authenticated";
GRANT ALL ON TABLE "public"."employees" TO "service_role";


--
-- Name: TABLE "employer_cost_components_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."employer_cost_components_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."employer_cost_components_v2" TO "authenticated";


--
-- Name: TABLE "event_demand_changes"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."event_demand_changes" TO "anon";
GRANT ALL ON TABLE "public"."event_demand_changes" TO "authenticated";
GRANT ALL ON TABLE "public"."event_demand_changes" TO "service_role";


--
-- Name: TABLE "integration_runs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."integration_runs" TO "anon";
GRANT ALL ON TABLE "public"."integration_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."integration_runs" TO "service_role";


--
-- Name: TABLE "locations"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."locations" TO "anon";
GRANT ALL ON TABLE "public"."locations" TO "authenticated";
GRANT ALL ON TABLE "public"."locations" TO "service_role";


--
-- Name: TABLE "matrix_conflicts"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_conflicts" TO "anon";
GRANT ALL ON TABLE "public"."matrix_conflicts" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_conflicts" TO "service_role";


--
-- Name: TABLE "matrix_demand"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_demand" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_demand" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_demand" TO "service_role";


--
-- Name: TABLE "matrix_duties_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_duties_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_duties_v2" TO "authenticated";


--
-- Name: TABLE "matrix_employee_duties_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_employee_duties_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_employee_duties_v2" TO "authenticated";


--
-- Name: TABLE "matrix_employee_locations_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_employee_locations_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_employee_locations_v2" TO "authenticated";


--
-- Name: TABLE "matrix_employee_profiles_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_employee_profiles_v2" TO "service_role";


--
-- Name: TABLE "matrix_employee_roles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_employee_roles" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_employee_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_employee_roles" TO "service_role";


--
-- Name: TABLE "matrix_employee_roles_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_employee_roles_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_employee_roles_v2" TO "authenticated";


--
-- Name: TABLE "matrix_functions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_functions" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_functions" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_functions" TO "service_role";


--
-- Name: TABLE "matrix_import_runs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_import_runs" TO "anon";
GRANT ALL ON TABLE "public"."matrix_import_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_import_runs" TO "service_role";


--
-- Name: TABLE "matrix_locations"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_locations" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_locations" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_locations" TO "service_role";


--
-- Name: TABLE "matrix_locations_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_locations_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_locations_v2" TO "authenticated";


--
-- Name: TABLE "matrix_pay_rule_duties_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_pay_rule_duties_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_pay_rule_duties_v2" TO "authenticated";


--
-- Name: TABLE "matrix_pay_rule_locations_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_pay_rule_locations_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_pay_rule_locations_v2" TO "authenticated";


--
-- Name: TABLE "matrix_pay_rule_roles_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_pay_rule_roles_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_pay_rule_roles_v2" TO "authenticated";


--
-- Name: TABLE "matrix_pay_rule_shifts_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_pay_rule_shifts_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_pay_rule_shifts_v2" TO "authenticated";


--
-- Name: TABLE "matrix_pay_rules_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_pay_rules_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_pay_rules_v2" TO "authenticated";


--
-- Name: TABLE "matrix_role_categories_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_role_categories_v2" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_role_categories_v2" TO "service_role";


--
-- Name: TABLE "matrix_role_duties_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_role_duties_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_role_duties_v2" TO "authenticated";


--
-- Name: TABLE "matrix_role_functions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_role_functions" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_role_functions" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_role_functions" TO "service_role";


--
-- Name: TABLE "matrix_roles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_roles" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_roles" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_roles" TO "service_role";


--
-- Name: TABLE "matrix_roles_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_roles_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_roles_v2" TO "authenticated";


--
-- Name: TABLE "matrix_scenario_budgets_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_scenario_budgets_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_scenario_budgets_v2" TO "authenticated";


--
-- Name: TABLE "matrix_scenario_pay_rule_overrides_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_scenario_pay_rule_overrides_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_scenario_pay_rule_overrides_v2" TO "authenticated";


--
-- Name: TABLE "matrix_scenario_strategies_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_scenario_strategies_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_scenario_strategies_v2" TO "authenticated";


--
-- Name: TABLE "matrix_scenarios"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_scenarios" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_scenarios" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_scenarios" TO "service_role";


--
-- Name: TABLE "matrix_scenarios_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_scenarios_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_scenarios_v2" TO "authenticated";


--
-- Name: TABLE "matrix_scope_grants_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_scope_grants_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_scope_grants_v2" TO "authenticated";


--
-- Name: TABLE "matrix_shift_templates"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_shift_templates" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_shift_templates" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_shift_templates" TO "service_role";


--
-- Name: TABLE "matrix_shift_templates_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_shift_templates_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_shift_templates_v2" TO "authenticated";


--
-- Name: TABLE "matrix_staffing_rules_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_staffing_rules_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_staffing_rules_v2" TO "authenticated";


--
-- Name: TABLE "matrix_strategies_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_strategies_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_strategies_v2" TO "authenticated";


--
-- Name: TABLE "matrix_strategy_objectives_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."matrix_strategy_objectives_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."matrix_strategy_objectives_v2" TO "authenticated";


--
-- Name: TABLE "matrix_versions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_versions" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."matrix_versions" TO "authenticated";
GRANT ALL ON TABLE "public"."matrix_versions" TO "service_role";


--
-- Name: TABLE "monthly_budget_lines_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."monthly_budget_lines_v2" TO "service_role";


--
-- Name: TABLE "monthly_budget_revisions_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."monthly_budget_revisions_v2" TO "service_role";


--
-- Name: TABLE "monthly_budgets"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."monthly_budgets" TO "anon";
GRANT ALL ON TABLE "public"."monthly_budgets" TO "authenticated";
GRANT ALL ON TABLE "public"."monthly_budgets" TO "service_role";


--
-- Name: TABLE "notifications"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."notifications" TO "anon";
GRANT SELECT,REFERENCES,TRIGGER,TRUNCATE,MAINTAIN ON TABLE "public"."notifications" TO "authenticated";
GRANT ALL ON TABLE "public"."notifications" TO "service_role";


--
-- Name: TABLE "operational_assignment_overrides_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_assignment_overrides_v2" TO "service_role";


--
-- Name: TABLE "operational_assignment_replacements_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_assignment_replacements_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."operational_assignment_replacements_v2" TO "authenticated";


--
-- Name: TABLE "operational_events"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_events" TO "anon";
GRANT ALL ON TABLE "public"."operational_events" TO "authenticated";
GRANT ALL ON TABLE "public"."operational_events" TO "service_role";


--
-- Name: TABLE "operational_program_audience_rules_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_audience_rules_v1" TO "service_role";


--
-- Name: TABLE "operational_program_audit_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_audit_v1" TO "service_role";


--
-- Name: SEQUENCE "operational_program_audit_v1_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."operational_program_audit_v1_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."operational_program_audit_v1_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."operational_program_audit_v1_id_seq" TO "service_role";


--
-- Name: TABLE "operational_program_checklist_items_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_checklist_items_v1" TO "service_role";


--
-- Name: TABLE "operational_program_events_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_events_v1" TO "service_role";


--
-- Name: TABLE "operational_program_inventory_links_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_inventory_links_v1" TO "service_role";


--
-- Name: TABLE "operational_program_participants_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."operational_program_participants_v1" TO "service_role";


--
-- Name: TABLE "optimization_candidates"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."optimization_candidates" TO "anon";
GRANT ALL ON TABLE "public"."optimization_candidates" TO "authenticated";
GRANT ALL ON TABLE "public"."optimization_candidates" TO "service_role";


--
-- Name: TABLE "optimization_run_strategies_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."optimization_run_strategies_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."optimization_run_strategies_v2" TO "authenticated";


--
-- Name: TABLE "optimization_runs"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."optimization_runs" TO "anon";
GRANT ALL ON TABLE "public"."optimization_runs" TO "authenticated";
GRANT ALL ON TABLE "public"."optimization_runs" TO "service_role";


--
-- Name: TABLE "optimization_runs_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."optimization_runs_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."optimization_runs_v2" TO "authenticated";


--
-- Name: TABLE "optimizer_profiles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT SELECT,MAINTAIN ON TABLE "public"."optimizer_profiles" TO "anon";
GRANT SELECT,MAINTAIN ON TABLE "public"."optimizer_profiles" TO "authenticated";
GRANT ALL ON TABLE "public"."optimizer_profiles" TO "service_role";


--
-- Name: TABLE "plan_assignment_duties_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_assignment_duties_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_assignment_duties_v2" TO "authenticated";


--
-- Name: TABLE "plan_assignments_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_assignments_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_assignments_v2" TO "authenticated";


--
-- Name: TABLE "plan_issues"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_issues" TO "anon";
GRANT ALL ON TABLE "public"."plan_issues" TO "authenticated";
GRANT ALL ON TABLE "public"."plan_issues" TO "service_role";


--
-- Name: TABLE "plan_issues_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_issues_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_issues_v2" TO "authenticated";


--
-- Name: SEQUENCE "plan_issues_v2_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."plan_issues_v2_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."plan_issues_v2_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."plan_issues_v2_id_seq" TO "service_role";


--
-- Name: TABLE "plan_shifts_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_shifts_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_shifts_v2" TO "authenticated";


--
-- Name: TABLE "plan_variants_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plan_variants_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."plan_variants_v2" TO "authenticated";


--
-- Name: TABLE "plans"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."plans" TO "anon";
GRANT ALL ON TABLE "public"."plans" TO "authenticated";
GRANT ALL ON TABLE "public"."plans" TO "service_role";


--
-- Name: TABLE "published_role_schedules_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."published_role_schedules_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."published_role_schedules_v2" TO "authenticated";


--
-- Name: TABLE "published_schedule_variants_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."published_schedule_variants_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."published_schedule_variants_v2" TO "authenticated";


--
-- Name: TABLE "published_schedules_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."published_schedules_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."published_schedules_v2" TO "authenticated";


--
-- Name: TABLE "published_standby_assignments_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."published_standby_assignments_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."published_standby_assignments_v2" TO "authenticated";


--
-- Name: TABLE "recovery_actions_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_actions_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_actions_v2" TO "authenticated";


--
-- Name: TABLE "recovery_ad_hoc_pool_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_ad_hoc_pool_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_ad_hoc_pool_v2" TO "authenticated";


--
-- Name: TABLE "recovery_incident_rate_revisions_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_incident_rate_revisions_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_incident_rate_revisions_v2" TO "authenticated";


--
-- Name: TABLE "recovery_incidents_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_incidents_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_incidents_v2" TO "authenticated";


--
-- Name: TABLE "recovery_month_revisions_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_month_revisions_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_month_revisions_v2" TO "authenticated";


--
-- Name: TABLE "recovery_offer_responses_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_offer_responses_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_offer_responses_v2" TO "authenticated";


--
-- Name: TABLE "recovery_overrides_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."recovery_overrides_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."recovery_overrides_v2" TO "authenticated";


--
-- Name: TABLE "role_plan_assignments"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."role_plan_assignments" TO "anon";
GRANT ALL ON TABLE "public"."role_plan_assignments" TO "authenticated";
GRANT ALL ON TABLE "public"."role_plan_assignments" TO "service_role";


--
-- Name: TABLE "role_plan_sections"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."role_plan_sections" TO "anon";
GRANT ALL ON TABLE "public"."role_plan_sections" TO "authenticated";
GRANT ALL ON TABLE "public"."role_plan_sections" TO "service_role";


--
-- Name: TABLE "roles"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."roles" TO "anon";
GRANT ALL ON TABLE "public"."roles" TO "authenticated";
GRANT ALL ON TABLE "public"."roles" TO "service_role";


--
-- Name: TABLE "shift_definitions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."shift_definitions" TO "anon";
GRANT ALL ON TABLE "public"."shift_definitions" TO "authenticated";
GRANT ALL ON TABLE "public"."shift_definitions" TO "service_role";


--
-- Name: TABLE "shift_swap_history_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."shift_swap_history_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."shift_swap_history_v2" TO "authenticated";


--
-- Name: SEQUENCE "shift_swap_history_v2_id_seq"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON SEQUENCE "public"."shift_swap_history_v2_id_seq" TO "anon";
GRANT ALL ON SEQUENCE "public"."shift_swap_history_v2_id_seq" TO "authenticated";
GRANT ALL ON SEQUENCE "public"."shift_swap_history_v2_id_seq" TO "service_role";


--
-- Name: TABLE "shift_swap_requests_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."shift_swap_requests_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."shift_swap_requests_v2" TO "authenticated";


--
-- Name: TABLE "shifts"; Type: ACL; Schema: public; Owner: postgres
--

GRANT INSERT,REFERENCES,DELETE,TRIGGER,TRUNCATE,MAINTAIN,UPDATE ON TABLE "public"."shifts" TO "anon";
GRANT ALL ON TABLE "public"."shifts" TO "authenticated";
GRANT ALL ON TABLE "public"."shifts" TO "service_role";


--
-- Name: TABLE "solver_feature_flags"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."solver_feature_flags" TO "service_role";
GRANT SELECT ON TABLE "public"."solver_feature_flags" TO "authenticated";


--
-- Name: TABLE "tasks"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."tasks" TO "anon";
GRANT ALL ON TABLE "public"."tasks" TO "authenticated";
GRANT ALL ON TABLE "public"."tasks" TO "service_role";


--
-- Name: TABLE "team_conversation_members_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."team_conversation_members_v1" TO "service_role";


--
-- Name: TABLE "team_conversations_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."team_conversations_v1" TO "service_role";


--
-- Name: TABLE "team_messages_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."team_messages_v1" TO "service_role";


--
-- Name: TABLE "time_records"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."time_records" TO "anon";
GRANT ALL ON TABLE "public"."time_records" TO "authenticated";
GRANT ALL ON TABLE "public"."time_records" TO "service_role";


--
-- Name: TABLE "uat_environment_controls"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."uat_environment_controls" TO "service_role";


--
-- Name: TABLE "user_permissions"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."user_permissions" TO "anon";
GRANT ALL ON TABLE "public"."user_permissions" TO "authenticated";
GRANT ALL ON TABLE "public"."user_permissions" TO "service_role";


--
-- Name: TABLE "user_profiles_v1"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."user_profiles_v1" TO "service_role";
GRANT SELECT ON TABLE "public"."user_profiles_v1" TO "authenticated";


--
-- Name: TABLE "workforce_calendar_events_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."workforce_calendar_events_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."workforce_calendar_events_v2" TO "authenticated";


--
-- Name: TABLE "workforce_event_demand_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."workforce_event_demand_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."workforce_event_demand_v2" TO "authenticated";


--
-- Name: TABLE "workforce_hot_day_limits_v2"; Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON TABLE "public"."workforce_hot_day_limits_v2" TO "service_role";
GRANT SELECT ON TABLE "public"."workforce_hot_day_limits_v2" TO "authenticated";


--
-- Name: TABLE "optimization_attempts_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON TABLE "solver_private"."optimization_attempts_v2" TO "service_role";


--
-- Name: TABLE "optimization_snapshots_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON TABLE "solver_private"."optimization_snapshots_v2" TO "service_role";


--
-- Name: TABLE "plan_assignment_cost_components_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON TABLE "solver_private"."plan_assignment_cost_components_v2" TO "service_role";


--
-- Name: SEQUENCE "plan_assignment_cost_components_v2_id_seq"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT SELECT,USAGE ON SEQUENCE "solver_private"."plan_assignment_cost_components_v2_id_seq" TO "service_role";


--
-- Name: TABLE "plan_variant_finance_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON TABLE "solver_private"."plan_variant_finance_v2" TO "service_role";


--
-- Name: TABLE "planning_data_revision_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT SELECT ON TABLE "solver_private"."planning_data_revision_v2" TO "service_role";


--
-- Name: TABLE "published_schedule_finance_v2"; Type: ACL; Schema: solver_private; Owner: postgres
--

GRANT ALL ON TABLE "solver_private"."published_schedule_finance_v2" TO "service_role";


