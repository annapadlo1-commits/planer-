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
-- Name: tasks_assignee_status_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "tasks_assignee_status_idx" ON "public"."tasks" USING "btree" ("assigned_to", "status");


--
-- Name: team_conversation_members_v1_user_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "team_conversation_members_v1_user_idx" ON "public"."team_conversation_members_v1" USING "btree" ("auth_user_id", "conversation_id");


--
-- Name: team_messages_v1_conversation_created_idx; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "team_messages_v1_conversation_created_idx" ON "public"."team_messages_v1" USING "btree" ("conversation_id", "created_at");


--
-- Name: user_permissions_scope_unique; Type: INDEX; Schema: public; Owner: postgres
--

CREATE UNIQUE INDEX "user_permissions_scope_unique" ON "public"."user_permissions" USING "btree" ("auth_user_id", "app_role", "scope_role", "scope_location") NULLS NOT DISTINCT;


--
-- Name: workforce_events_month_date_v2; Type: INDEX; Schema: public; Owner: postgres
--

CREATE INDEX "workforce_events_month_date_v2" ON "public"."workforce_calendar_events_v2" USING "btree" ("month", "event_date", "status");


--
-- Name: leader_variant_history_variant_seq_v2; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "leader_variant_history_variant_seq_v2" ON "solver_private"."leader_variant_history_v2" USING "btree" ("variant_id", "seq");


--
-- Name: optimization_attempts_v2_run_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "optimization_attempts_v2_run_idx" ON "solver_private"."optimization_attempts_v2" USING "btree" ("run_id", "attempt_number" DESC);


--
-- Name: plan_assignment_cost_components_v2_assignment_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "plan_assignment_cost_components_v2_assignment_idx" ON "solver_private"."plan_assignment_cost_components_v2" USING "btree" ("assignment_id");


--
-- Name: plan_assignment_cost_components_v2_rule_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "plan_assignment_cost_components_v2_rule_idx" ON "solver_private"."plan_assignment_cost_components_v2" USING "btree" ("pay_rule_id") WHERE ("pay_rule_id" IS NOT NULL);


--
-- Name: solver_job_dispatch_active_org_uat_v1_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "solver_job_dispatch_active_org_uat_v1_idx" ON "solver_private"."solver_job_dispatch_outbox_uat_v1" USING "btree" ("organization_key", "dispatch_status") WHERE ("dispatch_status" = ANY (ARRAY['DISPATCHING'::"text", 'ACCEPTANCE_UNKNOWN'::"text", 'ACCEPTED'::"text", 'STARTING'::"text", 'RUNNING'::"text"]));


--
-- Name: solver_job_dispatch_one_schedule_uat_v1_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE UNIQUE INDEX "solver_job_dispatch_one_schedule_uat_v1_idx" ON "solver_private"."solver_job_dispatch_outbox_uat_v1" USING "btree" ("organization_key", "month", "scope_type", COALESCE("scope_role_id", '00000000-0000-0000-0000-000000000000'::"uuid")) WHERE ("dispatch_status" = ANY (ARRAY['PENDING'::"text", 'DISPATCHING'::"text", 'ACCEPTANCE_UNKNOWN'::"text", 'ACCEPTED'::"text", 'STARTING'::"text", 'RUNNING'::"text"]));


--
-- Name: solver_job_dispatch_pending_uat_v1_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "solver_job_dispatch_pending_uat_v1_idx" ON "solver_private"."solver_job_dispatch_outbox_uat_v1" USING "btree" ("next_dispatch_at", "requested_at", "run_id") WHERE ("dispatch_status" = 'PENDING'::"text");


--
-- Name: solver_job_dispatch_scope_role_uat_v1_idx; Type: INDEX; Schema: solver_private; Owner: postgres
--

CREATE INDEX "solver_job_dispatch_scope_role_uat_v1_idx" ON "solver_private"."solver_job_dispatch_outbox_uat_v1" USING "btree" ("scope_role_id") WHERE ("scope_role_id" IS NOT NULL);


--
-- Name: plan_variants_v2 capture_leader_variant_initial_history_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER "capture_leader_variant_initial_history_v2" AFTER INSERT ON "public"."plan_variants_v2" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "solver_private"."capture_leader_variant_history_v2"();


--
-- Name: plan_variants_v2 capture_leader_variant_revision_history_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "capture_leader_variant_revision_history_v2" AFTER UPDATE OF "revision" ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."capture_leader_variant_history_v2"();


--
-- Name: employee_availability employee_availability_history_trigger; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "employee_availability_history_trigger" AFTER INSERT OR UPDATE ON "public"."employee_availability" FOR EACH ROW EXECUTE FUNCTION "public"."log_availability_change"();


--
-- Name: employee_availability employee_availability_sync_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "employee_availability_sync_v2" AFTER INSERT OR DELETE OR UPDATE ON "public"."employee_availability" FOR EACH ROW EXECUTE FUNCTION "solver_private"."sync_employee_availability_v2"();


--
-- Name: employee_pay_rates_v2 employee_pay_rate_employment_guard_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "employee_pay_rate_employment_guard_uat_v1" BEFORE INSERT OR UPDATE OF "employee_id", "valid_from", "valid_to" ON "public"."employee_pay_rates_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_employee_pay_rate_employment_uat_v1"();


--
-- Name: employee_preferences employee_preference_sync_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "employee_preference_sync_v2" AFTER INSERT OR DELETE OR UPDATE ON "public"."employee_preferences" FOR EACH ROW EXECUTE FUNCTION "solver_private"."sync_employee_preference_v2"();


--
-- Name: plan_variants_v2 guard_leader_variant_publication_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "guard_leader_variant_publication_uat_v1" BEFORE UPDATE OF "status" ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_leader_variant_publication_uat_v1"();


--
-- Name: matrix_versions guard_strategy_semantics_b4f165; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "guard_strategy_semantics_b4f165" BEFORE INSERT OR UPDATE OF "status" ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_strategy_semantics_b4f165"();


--
-- Name: matrix_duties_v2 matrix_duty_deactivation_guard_uat006; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_duty_deactivation_guard_uat006" BEFORE UPDATE OF "active" ON "public"."matrix_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."matrix_duty_deactivation_guard_uat006"();


--
-- Name: matrix_employee_profiles_v2 matrix_employee_overtime_policy_inherit_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_overtime_policy_inherit_uat_v1" BEFORE INSERT ON "public"."matrix_employee_profiles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."inherit_employee_overtime_policy_uat_v1"();


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profile_pay_rate_guard_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_profile_pay_rate_guard_uat_v1" BEFORE INSERT OR UPDATE OF "employee_id", "employment_start", "employment_end" ON "public"."matrix_employee_profiles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_employee_profile_pay_rates_uat_v1"();


--
-- Name: matrix_versions matrix_employee_profiles_v2_activate; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_profiles_v2_activate" BEFORE UPDATE OF "status" ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "solver_private"."activate_matrix_employee_profiles_v2"();


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_profiles_v2_immutable" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_employee_profiles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_employee_profile_v2"();


--
-- Name: matrix_versions matrix_employee_profiles_v2_seed_draft; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_profiles_v2_seed_draft" AFTER INSERT ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "solver_private"."seed_matrix_employee_profiles_v2"();


--
-- Name: matrix_employee_roles_v2 matrix_employee_role_semantics_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_employee_role_semantics_uat_v1" BEFORE INSERT OR UPDATE OF "is_primary", "assignment_mode", "backup_priority" ON "public"."matrix_employee_roles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."matrix_employee_role_semantics_uat_v1"();


--
-- Name: matrix_roles_v2 matrix_role_category_inherit_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_role_category_inherit_uat_v1" BEFORE INSERT ON "public"."matrix_roles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."matrix_role_category_inherit_uat_v1"();


--
-- Name: matrix_shift_templates_v2 matrix_shift_color_preserve_on_clone_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_shift_color_preserve_on_clone_uat_v1" BEFORE INSERT ON "public"."matrix_shift_templates_v2" FOR EACH ROW EXECUTE FUNCTION "public"."matrix_shift_color_preserve_on_clone_uat_v1"();


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_alpha16_period; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_shift_templates_v2_alpha16_period" BEFORE INSERT OR UPDATE OF "starts_at", "ends_at", "ends_next_day", "shift_period" ON "public"."matrix_shift_templates_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."alpha16_shift_period_default_v2"();


--
-- Name: matrix_duties_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_employee_duties_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_employee_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_employee_locations_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_employee_locations_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_employee_profiles_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_employee_profiles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_employee_roles_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_employee_roles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_locations_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_locations_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_pay_rule_duties_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_pay_rule_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_pay_rule_locations_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_pay_rule_locations_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_pay_rule_roles_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_pay_rule_roles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_pay_rule_shifts_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_pay_rule_shifts_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_pay_rules_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_pay_rules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_role_duties_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_role_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_roles_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_roles_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_scenario_budgets_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_scenario_budgets_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_scenario_pay_rule_overrides_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_scenario_strategies_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_scenario_strategies_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_scenarios_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_scenarios_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_shift_templates_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_shift_templates_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_staffing_rules_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_staffing_rules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_strategies_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_strategies_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_strategy_objectives_v2 matrix_v2_immutable_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_immutable_guard" BEFORE INSERT OR DELETE OR UPDATE ON "public"."matrix_strategy_objectives_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_child_immutable_v2"();


--
-- Name: matrix_versions matrix_v2_prevent_last_usable_delete_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "matrix_v2_prevent_last_usable_delete_uat_v1" BEFORE DELETE ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "public"."matrix_v2_prevent_last_usable_delete_uat_v1"();


--
-- Name: matrix_versions normalize_initial_matrix_month_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "normalize_initial_matrix_month_uat_v1" BEFORE INSERT ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "solver_private"."normalize_initial_matrix_month_uat_v1"();


--
-- Name: notifications notifications_personal_normalize_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "notifications_personal_normalize_v1" BEFORE INSERT OR UPDATE OF "title", "body", "action_route" ON "public"."notifications" FOR EACH ROW EXECUTE FUNCTION "solver_private"."normalize_personal_notification_v1"();


--
-- Name: optimization_runs_v2 optimization_runs_v2_provenance_immutable; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "optimization_runs_v2_provenance_immutable" BEFORE UPDATE OF "request_engine", "solver_version" ON "public"."optimization_runs_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_run_provenance_v2"();


--
-- Name: optimization_runs_v2 optimization_runs_v2_version_stamp_immutable_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "optimization_runs_v2_version_stamp_immutable_uat_v1" BEFORE UPDATE OF "version_stamp" ON "public"."optimization_runs_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."enforce_run_version_stamp_uat_v1"();


--
-- Name: plan_assignment_duties_v2 plan_assignment_duties_v2_publication_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_assignment_duties_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "public"."plan_assignment_duties_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"();


--
-- Name: plan_assignments_v2 plan_assignments_v2_publication_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_assignments_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "public"."plan_assignments_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_direct_child_v2"();


--
-- Name: plan_issues_v2 plan_issues_v2_publication_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_issues_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "public"."plan_issues_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_direct_child_v2"();


--
-- Name: plan_shifts_v2 plan_shifts_v2_publication_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_shifts_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "public"."plan_shifts_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_direct_child_v2"();


--
-- Name: plan_variants_v2 plan_variants_v2_active_solver_selection; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_variants_v2_active_solver_selection" BEFORE INSERT OR UPDATE OF "selected" ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_active_variant_selection_v2"();


--
-- Name: plan_variants_v2 plan_variants_v2_publication_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_variants_v2_publication_freeze" BEFORE DELETE OR UPDATE ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_row_v2"();


--
-- Name: plan_variants_v2 plan_variants_v2_version_stamp_immutable_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plan_variants_v2_version_stamp_immutable_uat_v1" BEFORE UPDATE OF "version_stamp" ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."enforce_run_version_stamp_uat_v1"();


--
-- Name: assignments planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."assignments" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employee_availability planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employee_availability" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employee_hr_profiles planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employee_hr_profiles" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employee_pay_rates_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employee_pay_rates_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employee_preferences planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employee_preferences" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employee_time_constraints_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employee_time_constraints_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: employees planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."employees" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: locations planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."locations" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_duties_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_duties_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_employee_duties_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_employee_duties_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_employee_locations_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_employee_locations_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_employee_profiles_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_employee_profiles_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_employee_roles_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_employee_roles_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_locations_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_locations_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_pay_rule_duties_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_pay_rule_duties_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_pay_rule_locations_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_pay_rule_locations_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_pay_rule_roles_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_pay_rule_roles_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_pay_rule_shifts_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_pay_rule_shifts_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_pay_rules_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_pay_rules_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_role_duties_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_role_duties_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_roles_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_roles_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_scenario_budgets_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_scenario_budgets_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_scenario_pay_rule_overrides_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_scenario_pay_rule_overrides_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_scenario_strategies_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_scenario_strategies_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_scenarios_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_scenarios_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_shift_templates_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_shift_templates_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_staffing_rules_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_staffing_rules_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_strategies_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_strategies_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_strategy_objectives_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_strategy_objectives_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: matrix_versions planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."matrix_versions" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: monthly_budgets planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."monthly_budgets" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plan_assignment_duties_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."plan_assignment_duties_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plan_assignments_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."plan_assignments_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plan_shifts_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."plan_shifts_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plan_variants_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."plan_variants_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plans planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."plans" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: published_schedule_variants_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."published_schedule_variants_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: published_schedules_v2 planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."published_schedules_v2" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: shifts planning_revision_v2_bump; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "planning_revision_v2_bump" BEFORE INSERT OR DELETE OR UPDATE OR TRUNCATE ON "public"."shifts" FOR EACH STATEMENT EXECUTE FUNCTION "solver_private"."bump_planning_revision_v2"();


--
-- Name: plans plans_legacy_publication_cutover_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "plans_legacy_publication_cutover_guard" BEFORE INSERT OR UPDATE OF "status" ON "public"."plans" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_legacy_plan_publication_v2"();


--
-- Name: published_schedule_variants_v2 published_company_generate_standby_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_company_generate_standby_v2" AFTER INSERT ON "public"."published_schedule_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."generate_published_standby_trigger_v2"();


--
-- Name: published_schedules_v2 published_company_supersede_standby_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_company_supersede_standby_v2" AFTER UPDATE OF "status" ON "public"."published_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."supersede_standby_with_source_v2"();


--
-- Name: published_role_schedules_v2 published_role_generate_standby_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_role_generate_standby_v2" AFTER INSERT ON "public"."published_role_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."generate_published_standby_trigger_v2"();


--
-- Name: published_role_schedules_v2 published_role_schedule_authority_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_role_schedule_authority_guard" BEFORE INSERT OR UPDATE OF "status", "variant_id" ON "public"."published_role_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."publication_authority_guard_v2"();


--
-- Name: published_role_schedules_v2 published_role_supersede_logical_predecessor_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_role_supersede_logical_predecessor_v2" BEFORE INSERT ON "public"."published_role_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."supersede_previous_logical_role_schedule_uat_v2"();


--
-- Name: published_role_schedules_v2 published_role_supersede_standby_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_role_supersede_standby_v2" AFTER UPDATE OF "status" ON "public"."published_role_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."supersede_standby_with_source_v2"();


--
-- Name: published_schedules_v2 published_schedule_authority_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_schedule_authority_guard" BEFORE INSERT OR UPDATE OF "status" ON "public"."published_schedules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."publication_authority_guard_v2"();


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_link_freeze; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_schedule_variants_v2_link_freeze" BEFORE DELETE OR UPDATE ON "public"."published_schedule_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_publication_variant_link_v2"();


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_production_only; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "published_schedule_variants_v2_production_only" BEFORE INSERT ON "public"."published_schedule_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_production_variant_link_v2"();


--
-- Name: published_schedule_variants_v2 role_composite_consistency_guard; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE CONSTRAINT TRIGGER "role_composite_consistency_guard" AFTER INSERT OR DELETE OR UPDATE ON "public"."published_schedule_variants_v2" DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION "solver_private"."role_composite_consistency_guard_v2"();


--
-- Name: shift_swap_history_v2 shift_swap_history_coverage_uat006; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "shift_swap_history_coverage_uat006" BEFORE INSERT ON "public"."shift_swap_history_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."swap_history_coverage_uat006"();


--
-- Name: shift_swap_requests_v2 shift_swap_personal_notifications_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "shift_swap_personal_notifications_v1" AFTER INSERT OR UPDATE OF "status" ON "public"."shift_swap_requests_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."shift_swap_personal_notifications_v1"();


--
-- Name: matrix_staffing_rules_v2 staffing_duty_link_guard_uat006; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "staffing_duty_link_guard_uat006" BEFORE INSERT OR UPDATE OF "matrix_version_id", "role_id", "duty_id", "active" ON "public"."matrix_staffing_rules_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."staffing_duty_link_guard_uat006"();


--
-- Name: plan_variants_v2 sync_leader_workflow_published_uat_v1; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "sync_leader_workflow_published_uat_v1" BEFORE UPDATE OF "status" ON "public"."plan_variants_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."sync_leader_workflow_published_uat_v1"();


--
-- Name: matrix_versions zz_matrix_version_immutable_v2; Type: TRIGGER; Schema: public; Owner: postgres
--

CREATE TRIGGER "zz_matrix_version_immutable_v2" BEFORE DELETE OR UPDATE ON "public"."matrix_versions" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_matrix_version_immutable_v2"();


--
-- Name: plan_assignment_cost_components_v2 plan_assignment_cost_components_v2_publication_freeze; Type: TRIGGER; Schema: solver_private; Owner: postgres
--

CREATE TRIGGER "plan_assignment_cost_components_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "solver_private"."plan_assignment_cost_components_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_assignment_child_v2"();


--
-- Name: plan_variant_finance_v2 plan_variant_finance_v2_publication_freeze; Type: TRIGGER; Schema: solver_private; Owner: postgres
--

CREATE TRIGGER "plan_variant_finance_v2_publication_freeze" BEFORE INSERT OR DELETE OR UPDATE ON "solver_private"."plan_variant_finance_v2" FOR EACH ROW EXECUTE FUNCTION "solver_private"."guard_published_variant_direct_child_v2"();


--
-- Name: application_access_directory_v1 application_access_directory_v1_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_access_directory_v1"
    ADD CONSTRAINT "application_access_directory_v1_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: application_access_directory_v1 application_access_directory_v1_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_access_directory_v1"
    ADD CONSTRAINT "application_access_directory_v1_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: application_finance_visibility_policy_v1 application_finance_visibility_policy_v1_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."application_finance_visibility_policy_v1"
    ADD CONSTRAINT "application_finance_visibility_policy_v1_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: assignments assignments_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: assignments assignments_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."assignments"
    ADD CONSTRAINT "assignments_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id") ON DELETE CASCADE;


--
-- Name: attendance_events attendance_events_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance_events"
    ADD CONSTRAINT "attendance_events_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: attendance_events attendance_events_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance_events"
    ADD CONSTRAINT "attendance_events_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: attendance_events attendance_events_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance_events"
    ADD CONSTRAINT "attendance_events_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");


--
-- Name: attendance_events attendance_events_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."attendance_events"
    ADD CONSTRAINT "attendance_events_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id");


--
-- Name: audit_log audit_log_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."audit_log"
    ADD CONSTRAINT "audit_log_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_constraint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_constraint_id_fkey" FOREIGN KEY ("constraint_id") REFERENCES "public"."employee_time_constraints_v2"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_hot_day_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_hot_day_event_id_fkey" FOREIGN KEY ("hot_day_event_id") REFERENCES "public"."workforce_calendar_events_v2"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");


--
-- Name: availability_exception_reviews_v2 availability_exception_reviews_v2_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."availability_exception_reviews_v2"
    ADD CONSTRAINT "availability_exception_reviews_v2_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id");


--
-- Name: business_app_integrations_v1 business_app_integrations_v1_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."business_app_integrations_v1"
    ADD CONSTRAINT "business_app_integrations_v1_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: business_app_integrations_v1 business_app_integrations_v1_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."business_app_integrations_v1"
    ADD CONSTRAINT "business_app_integrations_v1_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: composite_schedules composite_schedules_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."composite_schedules"
    ADD CONSTRAINT "composite_schedules_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: composite_schedules composite_schedules_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."composite_schedules"
    ADD CONSTRAINT "composite_schedules_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: demand_rules demand_rules_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."demand_rules"
    ADD CONSTRAINT "demand_rules_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");


--
-- Name: demand_rules demand_rules_shift_definition_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."demand_rules"
    ADD CONSTRAINT "demand_rules_shift_definition_id_fkey" FOREIGN KEY ("shift_definition_id") REFERENCES "public"."shift_definitions"("id");


--
-- Name: employee_availability employee_availability_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability"
    ADD CONSTRAINT "employee_availability_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_availability_history employee_availability_history_changed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability_history"
    ADD CONSTRAINT "employee_availability_history_changed_by_fkey" FOREIGN KEY ("changed_by") REFERENCES "auth"."users"("id");


--
-- Name: employee_availability_history employee_availability_history_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability_history"
    ADD CONSTRAINT "employee_availability_history_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_availability employee_availability_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_availability"
    ADD CONSTRAINT "employee_availability_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: employee_capabilities employee_capabilities_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_capabilities"
    ADD CONSTRAINT "employee_capabilities_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_hr_profiles employee_hr_profiles_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_hr_profiles"
    ADD CONSTRAINT "employee_hr_profiles_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_hr_profiles employee_hr_profiles_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_hr_profiles"
    ADD CONSTRAINT "employee_hr_profiles_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: employee_locations employee_locations_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_locations"
    ADD CONSTRAINT "employee_locations_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_locations employee_locations_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_locations"
    ADD CONSTRAINT "employee_locations_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id") ON DELETE CASCADE;


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_pay_rates_v2"
    ADD CONSTRAINT "employee_pay_rates_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_pay_rates_v2"
    ADD CONSTRAINT "employee_pay_rates_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_pay_rates_v2"
    ADD CONSTRAINT "employee_pay_rates_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employee_preferences employee_preferences_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_preferences"
    ADD CONSTRAINT "employee_preferences_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_requests_v1 employee_requests_v1_constraint_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_constraint_id_fkey" FOREIGN KEY ("constraint_id") REFERENCES "public"."employee_time_constraints_v2"("id") ON DELETE SET NULL;


--
-- Name: employee_requests_v1 employee_requests_v1_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_requests_v1 employee_requests_v1_legacy_review_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_legacy_review_id_fkey" FOREIGN KEY ("legacy_review_id") REFERENCES "public"."availability_exception_reviews_v2"("id") ON DELETE SET NULL;


--
-- Name: employee_requests_v1 employee_requests_v1_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: employee_requests_v1 employee_requests_v1_reviewed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_requests_v1"
    ADD CONSTRAINT "employee_requests_v1_reviewed_by_fkey" FOREIGN KEY ("reviewed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_time_constraints_v2"
    ADD CONSTRAINT "employee_time_constraints_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_time_constraints_v2"
    ADD CONSTRAINT "employee_time_constraints_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_supersedes_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_time_constraints_v2"
    ADD CONSTRAINT "employee_time_constraints_v2_supersedes_id_fkey" FOREIGN KEY ("supersedes_id") REFERENCES "public"."employee_time_constraints_v2"("id") ON DELETE SET NULL;


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."matrix_locations_v2"("id") ON DELETE RESTRICT;


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id") ON DELETE RESTRICT;


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_v2_supersedes_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employee_weekly_work_patterns_v2"
    ADD CONSTRAINT "employee_weekly_work_patterns_v2_supersedes_id_fkey" FOREIGN KEY ("supersedes_id") REFERENCES "public"."employee_weekly_work_patterns_v2"("id") ON DELETE SET NULL;


--
-- Name: employees employees_archived_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");


--
-- Name: employees employees_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employees"
    ADD CONSTRAINT "employees_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employer_cost_components_v2 employer_cost_components_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employer_cost_components_v2"
    ADD CONSTRAINT "employer_cost_components_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: employer_cost_components_v2 employer_cost_components_v2_supersedes_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."employer_cost_components_v2"
    ADD CONSTRAINT "employer_cost_components_v2_supersedes_id_fkey" FOREIGN KEY ("supersedes_id") REFERENCES "public"."employer_cost_components_v2"("id");


--
-- Name: event_demand_changes event_demand_changes_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."event_demand_changes"
    ADD CONSTRAINT "event_demand_changes_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_events"("id") ON DELETE CASCADE;


--
-- Name: integration_runs integration_runs_executed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."integration_runs"
    ADD CONSTRAINT "integration_runs_executed_by_fkey" FOREIGN KEY ("executed_by") REFERENCES "auth"."users"("id");


--
-- Name: matrix_conflicts matrix_conflicts_composite_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_conflicts"
    ADD CONSTRAINT "matrix_conflicts_composite_schedule_id_fkey" FOREIGN KEY ("composite_schedule_id") REFERENCES "public"."composite_schedules"("id") ON DELETE CASCADE;


--
-- Name: matrix_conflicts matrix_conflicts_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_conflicts"
    ADD CONSTRAINT "matrix_conflicts_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: matrix_conflicts matrix_conflicts_resolved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_conflicts"
    ADD CONSTRAINT "matrix_conflicts_resolved_by_fkey" FOREIGN KEY ("resolved_by") REFERENCES "auth"."users"("id");


--
-- Name: matrix_conflicts matrix_conflicts_role_plan_section_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_conflicts"
    ADD CONSTRAINT "matrix_conflicts_role_plan_section_id_fkey" FOREIGN KEY ("role_plan_section_id") REFERENCES "public"."role_plan_sections"("id") ON DELETE CASCADE;


--
-- Name: matrix_demand matrix_demand_function_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_demand"
    ADD CONSTRAINT "matrix_demand_function_id_fkey" FOREIGN KEY ("function_id") REFERENCES "public"."matrix_functions"("id") ON DELETE SET NULL;


--
-- Name: matrix_demand matrix_demand_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_demand"
    ADD CONSTRAINT "matrix_demand_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles"("id") ON DELETE CASCADE;


--
-- Name: matrix_demand matrix_demand_shift_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_demand"
    ADD CONSTRAINT "matrix_demand_shift_template_id_fkey" FOREIGN KEY ("shift_template_id") REFERENCES "public"."matrix_shift_templates"("id") ON DELETE CASCADE;


--
-- Name: matrix_duties_v2 matrix_duties_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_duties_v2"
    ADD CONSTRAINT "matrix_duties_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_employee_duties_v2 matrix_employee_duties_v2_profile_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_duties_v2"
    ADD CONSTRAINT "matrix_employee_duties_v2_profile_fk" FOREIGN KEY ("matrix_version_id", "employee_id") REFERENCES "public"."matrix_employee_profiles_v2"("matrix_version_id", "employee_id") ON DELETE CASCADE;


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_employee_locations_v2 matrix_employee_locations_v2_profile_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_locations_v2"
    ADD CONSTRAINT "matrix_employee_locations_v2_profile_fk" FOREIGN KEY ("matrix_version_id", "employee_id") REFERENCES "public"."matrix_employee_profiles_v2"("matrix_version_id", "employee_id") ON DELETE CASCADE;


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_archived_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE RESTRICT;


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_profiles_v2"
    ADD CONSTRAINT "matrix_employee_profiles_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_employee_roles matrix_employee_roles_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles"
    ADD CONSTRAINT "matrix_employee_roles_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles matrix_employee_roles_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles"
    ADD CONSTRAINT "matrix_employee_roles_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles matrix_employee_roles_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles"
    ADD CONSTRAINT "matrix_employee_roles_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_profile_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_profile_fk" FOREIGN KEY ("matrix_version_id", "employee_id") REFERENCES "public"."matrix_employee_profiles_v2"("matrix_version_id", "employee_id") ON DELETE CASCADE;


--
-- Name: matrix_employee_roles_v2 matrix_employee_roles_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_employee_roles_v2"
    ADD CONSTRAINT "matrix_employee_roles_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_functions matrix_functions_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_functions"
    ADD CONSTRAINT "matrix_functions_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_import_runs matrix_import_runs_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_import_runs"
    ADD CONSTRAINT "matrix_import_runs_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: matrix_import_runs matrix_import_runs_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_import_runs"
    ADD CONSTRAINT "matrix_import_runs_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: matrix_locations matrix_locations_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations"
    ADD CONSTRAINT "matrix_locations_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_locations_v2 matrix_locations_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_locations_v2"
    ADD CONSTRAINT "matrix_locations_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_duties_v2 matrix_pay_rule_duties_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_duties_v2"
    ADD CONSTRAINT "matrix_pay_rule_duties_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_duties_v2 matrix_pay_rule_duties_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_duties_v2"
    ADD CONSTRAINT "matrix_pay_rule_duties_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_duties_v2 matrix_pay_rule_duties_v2_matrix_version_id_pay_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_duties_v2"
    ADD CONSTRAINT "matrix_pay_rule_duties_v2_matrix_version_id_pay_rule_id_fkey" FOREIGN KEY ("matrix_version_id", "pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_locations_v2 matrix_pay_rule_locations_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_locations_v2"
    ADD CONSTRAINT "matrix_pay_rule_locations_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_locations_v2 matrix_pay_rule_locations_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_locations_v2"
    ADD CONSTRAINT "matrix_pay_rule_locations_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_locations_v2 matrix_pay_rule_locations_v2_matrix_version_id_pay_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_locations_v2"
    ADD CONSTRAINT "matrix_pay_rule_locations_v2_matrix_version_id_pay_rule_id_fkey" FOREIGN KEY ("matrix_version_id", "pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_roles_v2 matrix_pay_rule_roles_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_roles_v2"
    ADD CONSTRAINT "matrix_pay_rule_roles_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_roles_v2 matrix_pay_rule_roles_v2_matrix_version_id_pay_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_roles_v2"
    ADD CONSTRAINT "matrix_pay_rule_roles_v2_matrix_version_id_pay_rule_id_fkey" FOREIGN KEY ("matrix_version_id", "pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_roles_v2 matrix_pay_rule_roles_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_roles_v2"
    ADD CONSTRAINT "matrix_pay_rule_roles_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_shifts_v2 matrix_pay_rule_shifts_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_shifts_v2"
    ADD CONSTRAINT "matrix_pay_rule_shifts_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_shifts_v2 matrix_pay_rule_shifts_v2_matrix_version_id_pay_rule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_shifts_v2"
    ADD CONSTRAINT "matrix_pay_rule_shifts_v2_matrix_version_id_pay_rule_id_fkey" FOREIGN KEY ("matrix_version_id", "pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rule_shifts_v2 matrix_pay_rule_shifts_v2_matrix_version_id_shift_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rule_shifts_v2"
    ADD CONSTRAINT "matrix_pay_rule_shifts_v2_matrix_version_id_shift_template_fkey" FOREIGN KEY ("matrix_version_id", "shift_template_id") REFERENCES "public"."matrix_shift_templates_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_pay_rules_v2 matrix_pay_rules_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_pay_rules_v2"
    ADD CONSTRAINT "matrix_pay_rules_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_categories_v2"
    ADD CONSTRAINT "matrix_role_categories_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_role_duties_v2 matrix_role_duties_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_duties_v2"
    ADD CONSTRAINT "matrix_role_duties_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_role_duties_v2 matrix_role_duties_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_duties_v2"
    ADD CONSTRAINT "matrix_role_duties_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_role_duties_v2 matrix_role_duties_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_duties_v2"
    ADD CONSTRAINT "matrix_role_duties_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_role_functions matrix_role_functions_function_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_functions"
    ADD CONSTRAINT "matrix_role_functions_function_id_fkey" FOREIGN KEY ("function_id") REFERENCES "public"."matrix_functions"("id") ON DELETE CASCADE;


--
-- Name: matrix_role_functions matrix_role_functions_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_role_functions"
    ADD CONSTRAINT "matrix_role_functions_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles"("id") ON DELETE CASCADE;


--
-- Name: matrix_roles matrix_roles_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles"
    ADD CONSTRAINT "matrix_roles_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_roles_v2 matrix_roles_v2_category_fk; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_category_fk" FOREIGN KEY ("matrix_version_id", "category_id") REFERENCES "public"."matrix_role_categories_v2"("matrix_version_id", "id") ON DELETE RESTRICT;


--
-- Name: matrix_roles_v2 matrix_roles_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_roles_v2"
    ADD CONSTRAINT "matrix_roles_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_budgets_v2 matrix_scenario_budgets_v2_matrix_version_id_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_budgets_v2"
    ADD CONSTRAINT "matrix_scenario_budgets_v2_matrix_version_id_scenario_id_fkey" FOREIGN KEY ("matrix_version_id", "scenario_id") REFERENCES "public"."matrix_scenarios_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_scenario_pay_rule_over_matrix_version_id_pay_rule_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_pay_rule_overrides_v2"
    ADD CONSTRAINT "matrix_scenario_pay_rule_over_matrix_version_id_pay_rule_i_fkey" FOREIGN KEY ("matrix_version_id", "pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_scenario_pay_rule_over_matrix_version_id_scenario_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_pay_rule_overrides_v2"
    ADD CONSTRAINT "matrix_scenario_pay_rule_over_matrix_version_id_scenario_i_fkey" FOREIGN KEY ("matrix_version_id", "scenario_id") REFERENCES "public"."matrix_scenarios_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_pay_rule_overrides_v2 matrix_scenario_pay_rule_overrides_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_pay_rule_overrides_v2"
    ADD CONSTRAINT "matrix_scenario_pay_rule_overrides_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_strategies_v2 matrix_scenario_strategies_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_strategies_v2"
    ADD CONSTRAINT "matrix_scenario_strategies_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_strategies_v2 matrix_scenario_strategies_v2_matrix_version_id_scenario_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_strategies_v2"
    ADD CONSTRAINT "matrix_scenario_strategies_v2_matrix_version_id_scenario_i_fkey" FOREIGN KEY ("matrix_version_id", "scenario_id") REFERENCES "public"."matrix_scenarios_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenario_strategies_v2 matrix_scenario_strategies_v2_matrix_version_id_strategy_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenario_strategies_v2"
    ADD CONSTRAINT "matrix_scenario_strategies_v2_matrix_version_id_strategy_i_fkey" FOREIGN KEY ("matrix_version_id", "strategy_id") REFERENCES "public"."matrix_strategies_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_scenarios matrix_scenarios_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios"
    ADD CONSTRAINT "matrix_scenarios_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_scenarios_v2 matrix_scenarios_v2_matrix_version_id_parent_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scenarios_v2"
    ADD CONSTRAINT "matrix_scenarios_v2_matrix_version_id_parent_scenario_id_fkey" FOREIGN KEY ("matrix_version_id", "parent_scenario_id") REFERENCES "public"."matrix_scenarios_v2"("matrix_version_id", "id") ON DELETE RESTRICT;


--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scope_grants_v2"
    ADD CONSTRAINT "matrix_scope_grants_v2_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_scope_grants_v2"
    ADD CONSTRAINT "matrix_scope_grants_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: matrix_shift_templates matrix_shift_templates_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates"
    ADD CONSTRAINT "matrix_shift_templates_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."matrix_locations"("id") ON DELETE CASCADE;


--
-- Name: matrix_shift_templates matrix_shift_templates_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates"
    ADD CONSTRAINT "matrix_shift_templates_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_shift_templates_v2 matrix_shift_templates_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_shift_templates_v2"
    ADD CONSTRAINT "matrix_shift_templates_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_matrix_version_id_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_matrix_version_id_scenario_id_fkey" FOREIGN KEY ("matrix_version_id", "scenario_id") REFERENCES "public"."matrix_scenarios_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_staffing_rules_v2 matrix_staffing_rules_v2_matrix_version_id_shift_template__fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_staffing_rules_v2"
    ADD CONSTRAINT "matrix_staffing_rules_v2_matrix_version_id_shift_template__fkey" FOREIGN KEY ("matrix_version_id", "shift_template_id") REFERENCES "public"."matrix_shift_templates_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_legacy_optimizer_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_legacy_optimizer_profile_id_fkey" FOREIGN KEY ("legacy_optimizer_profile_id") REFERENCES "public"."optimizer_profiles"("id") ON DELETE SET NULL;


--
-- Name: matrix_strategies_v2 matrix_strategies_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategies_v2"
    ADD CONSTRAINT "matrix_strategies_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_strategy_objectives_v2 matrix_strategy_objectives_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategy_objectives_v2"
    ADD CONSTRAINT "matrix_strategy_objectives_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: matrix_strategy_objectives_v2 matrix_strategy_objectives_v2_matrix_version_id_strategy_i_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_strategy_objectives_v2"
    ADD CONSTRAINT "matrix_strategy_objectives_v2_matrix_version_id_strategy_i_fkey" FOREIGN KEY ("matrix_version_id", "strategy_id") REFERENCES "public"."matrix_strategies_v2"("matrix_version_id", "id") ON DELETE CASCADE;


--
-- Name: matrix_versions matrix_versions_base_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_versions"
    ADD CONSTRAINT "matrix_versions_base_version_id_fkey" FOREIGN KEY ("base_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE SET NULL;


--
-- Name: matrix_versions matrix_versions_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_versions"
    ADD CONSTRAINT "matrix_versions_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: matrix_versions matrix_versions_published_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."matrix_versions"
    ADD CONSTRAINT "matrix_versions_published_by_fkey" FOREIGN KEY ("published_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: monthly_budget_lines_v2 monthly_budget_lines_v2_revision_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_lines_v2"
    ADD CONSTRAINT "monthly_budget_lines_v2_revision_id_fkey" FOREIGN KEY ("revision_id") REFERENCES "public"."monthly_budget_revisions_v2"("id") ON DELETE CASCADE;


--
-- Name: monthly_budget_revisions_v2 monthly_budget_revisions_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budget_revisions_v2"
    ADD CONSTRAINT "monthly_budget_revisions_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: monthly_budgets monthly_budgets_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."monthly_budgets"
    ADD CONSTRAINT "monthly_budgets_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: notifications notifications_recipient_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_recipient_id_fkey" FOREIGN KEY ("recipient_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: notifications notifications_task_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."notifications"
    ADD CONSTRAINT "notifications_task_id_fkey" FOREIGN KEY ("task_id") REFERENCES "public"."tasks"("id") ON DELETE CASCADE;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_issue_id_fkey" FOREIGN KEY ("issue_id") REFERENCES "public"."plan_issues_v2"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."published_schedules_v2"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_overrides_v2"
    ADD CONSTRAINT "operational_assignment_overrides_v2_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."plan_shifts_v2"("id") ON DELETE RESTRICT;


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacement_replacement_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacement_replacement_employee_id_fkey" FOREIGN KEY ("replacement_employee_id") REFERENCES "public"."employees"("id");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacements__standby_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacements__standby_assignment_id_fkey" FOREIGN KEY ("standby_assignment_id") REFERENCES "public"."published_standby_assignments_v2"("id");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacements_original_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacements_original_assignment_id_fkey" FOREIGN KEY ("original_assignment_id") REFERENCES "public"."plan_assignments_v2"("id");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacements_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacements_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: operational_assignment_replacements_v2 operational_assignment_replacements_v2_revoked_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_assignment_replacements_v2"
    ADD CONSTRAINT "operational_assignment_replacements_v2_revoked_by_fkey" FOREIGN KEY ("revoked_by") REFERENCES "auth"."users"("id");


--
-- Name: operational_events operational_events_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: operational_events operational_events_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");


--
-- Name: operational_events operational_events_verifier_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_events"
    ADD CONSTRAINT "operational_events_verifier_user_id_fkey" FOREIGN KEY ("verifier_user_id") REFERENCES "auth"."users"("id");


--
-- Name: operational_program_audience_rules_v1 operational_program_audience_rules_v1_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_audience_rules_v1"
    ADD CONSTRAINT "operational_program_audience_rules_v1_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE CASCADE;


--
-- Name: operational_program_audit_v1 operational_program_audit_v1_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_audit_v1"
    ADD CONSTRAINT "operational_program_audit_v1_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_program_audit_v1 operational_program_audit_v1_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_audit_v1"
    ADD CONSTRAINT "operational_program_audit_v1_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE SET NULL;


--
-- Name: operational_program_checklist_items_v1 operational_program_checklist_items_v1_completed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_checklist_items_v1"
    ADD CONSTRAINT "operational_program_checklist_items_v1_completed_by_fkey" FOREIGN KEY ("completed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_program_checklist_items_v1 operational_program_checklist_items_v1_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_checklist_items_v1"
    ADD CONSTRAINT "operational_program_checklist_items_v1_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE CASCADE;


--
-- Name: operational_program_events_v1 operational_program_events_v1_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_program_events_v1 operational_program_events_v1_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;


--
-- Name: operational_program_events_v1 operational_program_events_v1_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."matrix_locations_v2"("id") ON DELETE RESTRICT;


--
-- Name: operational_program_events_v1 operational_program_events_v1_parent_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_parent_event_id_fkey" FOREIGN KEY ("parent_event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE SET NULL;


--
-- Name: operational_program_events_v1 operational_program_events_v1_published_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_events_v1"
    ADD CONSTRAINT "operational_program_events_v1_published_by_fkey" FOREIGN KEY ("published_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_program_inventory_links_v1 operational_program_inventory_links_v1_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_inventory_links_v1"
    ADD CONSTRAINT "operational_program_inventory_links_v1_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE CASCADE;


--
-- Name: operational_program_inventory_links_v1 operational_program_inventory_links_v1_integration_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_inventory_links_v1"
    ADD CONSTRAINT "operational_program_inventory_links_v1_integration_id_fkey" FOREIGN KEY ("integration_id") REFERENCES "public"."business_app_integrations_v1"("id") ON DELETE RESTRICT;


--
-- Name: operational_program_participants_v1 operational_program_participants_v1_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_participants_v1"
    ADD CONSTRAINT "operational_program_participants_v1_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: operational_program_participants_v1 operational_program_participants_v1_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_participants_v1"
    ADD CONSTRAINT "operational_program_participants_v1_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE RESTRICT;


--
-- Name: operational_program_participants_v1 operational_program_participants_v1_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."operational_program_participants_v1"
    ADD CONSTRAINT "operational_program_participants_v1_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."operational_program_events_v1"("id") ON DELETE CASCADE;


--
-- Name: optimization_candidates optimization_candidates_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_candidates"
    ADD CONSTRAINT "optimization_candidates_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id") ON DELETE SET NULL;


--
-- Name: optimization_candidates optimization_candidates_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_candidates"
    ADD CONSTRAINT "optimization_candidates_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs"("id") ON DELETE CASCADE;


--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_run_strategies_v2"
    ADD CONSTRAINT "optimization_run_strategies_v2_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs_v2"("id") ON DELETE CASCADE;


--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_run_strategies_v2"
    ADD CONSTRAINT "optimization_run_strategies_v2_strategy_id_fkey" FOREIGN KEY ("strategy_id") REFERENCES "public"."matrix_strategies_v2"("id");


--
-- Name: optimization_runs optimization_runs_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs"
    ADD CONSTRAINT "optimization_runs_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: optimization_runs optimization_runs_profile_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs"
    ADD CONSTRAINT "optimization_runs_profile_id_fkey" FOREIGN KEY ("profile_id") REFERENCES "public"."optimizer_profiles"("id");


--
-- Name: optimization_runs optimization_runs_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs"
    ADD CONSTRAINT "optimization_runs_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_requested_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_requested_by_fkey" FOREIGN KEY ("requested_by") REFERENCES "auth"."users"("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_scenario_id_fkey" FOREIGN KEY ("scenario_id") REFERENCES "public"."matrix_scenarios_v2"("id");


--
-- Name: optimization_runs_v2 optimization_runs_v2_scope_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimization_runs_v2"
    ADD CONSTRAINT "optimization_runs_v2_scope_role_id_fkey" FOREIGN KEY ("scope_role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: optimizer_profiles optimizer_profiles_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."optimizer_profiles"
    ADD CONSTRAINT "optimizer_profiles_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id") ON DELETE CASCADE;


--
-- Name: plan_assignment_duties_v2 plan_assignment_duties_v2_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignment_duties_v2"
    ADD CONSTRAINT "plan_assignment_duties_v2_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."plan_assignments_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_assignment_duties_v2 plan_assignment_duties_v2_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignment_duties_v2"
    ADD CONSTRAINT "plan_assignment_duties_v2_duty_id_fkey" FOREIGN KEY ("duty_id") REFERENCES "public"."matrix_duties_v2"("id");


--
-- Name: plan_assignments_v2 plan_assignments_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: plan_assignments_v2 plan_assignments_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: plan_assignments_v2 plan_assignments_v2_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."plan_shifts_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_assignments_v2 plan_assignments_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_assignments_v2"
    ADD CONSTRAINT "plan_assignments_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_issues plan_issues_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues"
    ADD CONSTRAINT "plan_issues_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id") ON DELETE CASCADE;


--
-- Name: plan_issues plan_issues_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues"
    ADD CONSTRAINT "plan_issues_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."shifts"("id") ON DELETE CASCADE;


--
-- Name: plan_issues_v2 plan_issues_v2_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues_v2"
    ADD CONSTRAINT "plan_issues_v2_duty_id_fkey" FOREIGN KEY ("duty_id") REFERENCES "public"."matrix_duties_v2"("id");


--
-- Name: plan_issues_v2 plan_issues_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues_v2"
    ADD CONSTRAINT "plan_issues_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: plan_issues_v2 plan_issues_v2_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues_v2"
    ADD CONSTRAINT "plan_issues_v2_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."plan_shifts_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_issues_v2 plan_issues_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_issues_v2"
    ADD CONSTRAINT "plan_issues_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_shifts_v2 plan_shifts_v2_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_shifts_v2"
    ADD CONSTRAINT "plan_shifts_v2_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."matrix_locations_v2"("id");


--
-- Name: plan_shifts_v2 plan_shifts_v2_shift_template_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_shifts_v2"
    ADD CONSTRAINT "plan_shifts_v2_shift_template_id_fkey" FOREIGN KEY ("shift_template_id") REFERENCES "public"."matrix_shift_templates_v2"("id");


--
-- Name: plan_shifts_v2 plan_shifts_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_shifts_v2"
    ADD CONSTRAINT "plan_shifts_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_variants_v2 plan_variants_v2_equivalent_to_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_equivalent_to_variant_id_fkey" FOREIGN KEY ("equivalent_to_variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE SET NULL;


--
-- Name: plan_variants_v2 plan_variants_v2_last_edited_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_last_edited_by_fkey" FOREIGN KEY ("last_edited_by") REFERENCES "auth"."users"("id");


--
-- Name: plan_variants_v2 plan_variants_v2_run_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_variants_v2 plan_variants_v2_run_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_run_strategy_id_fkey" FOREIGN KEY ("run_strategy_id") REFERENCES "public"."optimization_run_strategies_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_variants_v2 plan_variants_v2_selected_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_selected_by_fkey" FOREIGN KEY ("selected_by") REFERENCES "auth"."users"("id");


--
-- Name: plan_variants_v2 plan_variants_v2_source_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_source_variant_id_fkey" FOREIGN KEY ("source_variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE RESTRICT;


--
-- Name: plan_variants_v2 plan_variants_v2_strategy_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plan_variants_v2"
    ADD CONSTRAINT "plan_variants_v2_strategy_id_fkey" FOREIGN KEY ("strategy_id") REFERENCES "public"."matrix_strategies_v2"("id");


--
-- Name: plans plans_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: plans plans_parent_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."plans"
    ADD CONSTRAINT "plans_parent_plan_id_fkey" FOREIGN KEY ("parent_plan_id") REFERENCES "public"."plans"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_archived_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_scenario_id_fkey" FOREIGN KEY ("scenario_id") REFERENCES "public"."matrix_scenarios_v2"("id");


--
-- Name: published_role_schedules_v2 published_role_schedules_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_role_schedules_v2"
    ADD CONSTRAINT "published_role_schedules_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id");


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedule_variants_v2"
    ADD CONSTRAINT "published_schedule_variants_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedule_variants_v2"
    ADD CONSTRAINT "published_schedule_variants_v2_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."published_schedules_v2"("id") ON DELETE RESTRICT;


--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedule_variants_v2"
    ADD CONSTRAINT "published_schedule_variants_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE RESTRICT;


--
-- Name: published_schedules_v2 published_schedules_v2_archived_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_archived_by_fkey" FOREIGN KEY ("archived_by") REFERENCES "auth"."users"("id");


--
-- Name: published_schedules_v2 published_schedules_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: published_schedules_v2 published_schedules_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: published_schedules_v2 published_schedules_v2_scenario_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_schedules_v2"
    ADD CONSTRAINT "published_schedules_v2_scenario_id_fkey" FOREIGN KEY ("scenario_id") REFERENCES "public"."matrix_scenarios_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_activated_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_activated_assignment_id_fkey" FOREIGN KEY ("activated_assignment_id") REFERENCES "public"."plan_assignments_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_activated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_activated_by_fkey" FOREIGN KEY ("activated_by") REFERENCES "auth"."users"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_activated_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_activated_shift_id_fkey" FOREIGN KEY ("activated_shift_id") REFERENCES "public"."plan_shifts_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_source_role_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_source_role_schedule_id_fkey" FOREIGN KEY ("source_role_schedule_id") REFERENCES "public"."published_role_schedules_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_source_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_source_schedule_id_fkey" FOREIGN KEY ("source_schedule_id") REFERENCES "public"."published_schedules_v2"("id");


--
-- Name: published_standby_assignments_v2 published_standby_assignments_v2_source_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."published_standby_assignments_v2"
    ADD CONSTRAINT "published_standby_assignments_v2_source_variant_id_fkey" FOREIGN KEY ("source_variant_id") REFERENCES "public"."plan_variants_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_draft_variant_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_draft_variant_id_fkey" FOREIGN KEY ("draft_variant_id") REFERENCES "public"."plan_variants_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_duty_id_fkey" FOREIGN KEY ("duty_id") REFERENCES "public"."matrix_duties_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_incident_id_fkey" FOREIGN KEY ("incident_id") REFERENCES "public"."recovery_incidents_v2"("id") ON DELETE CASCADE;


--
-- Name: recovery_actions_v2 recovery_actions_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_selected_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_selected_employee_id_fkey" FOREIGN KEY ("selected_employee_id") REFERENCES "public"."employees"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_shift_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_shift_id_fkey" FOREIGN KEY ("shift_id") REFERENCES "public"."plan_shifts_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_source_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_source_assignment_id_fkey" FOREIGN KEY ("source_assignment_id") REFERENCES "public"."plan_assignments_v2"("id");


--
-- Name: recovery_actions_v2 recovery_actions_v2_source_issue_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_actions_v2"
    ADD CONSTRAINT "recovery_actions_v2_source_issue_id_fkey" FOREIGN KEY ("source_issue_id") REFERENCES "public"."plan_issues_v2"("id");


--
-- Name: recovery_ad_hoc_pool_v2 recovery_ad_hoc_pool_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_ad_hoc_pool_v2"
    ADD CONSTRAINT "recovery_ad_hoc_pool_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_ad_hoc_pool_v2 recovery_ad_hoc_pool_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_ad_hoc_pool_v2"
    ADD CONSTRAINT "recovery_ad_hoc_pool_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: recovery_ad_hoc_pool_v2 recovery_ad_hoc_pool_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_ad_hoc_pool_v2"
    ADD CONSTRAINT "recovery_ad_hoc_pool_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_incident_id_fkey" FOREIGN KEY ("incident_id") REFERENCES "public"."recovery_incidents_v2"("id") ON DELETE CASCADE;


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_proposed_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_proposed_by_fkey" FOREIGN KEY ("proposed_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: recovery_incident_rate_revisions_v2 recovery_incident_rate_revisions_v2_supersedes_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incident_rate_revisions_v2"
    ADD CONSTRAINT "recovery_incident_rate_revisions_v2_supersedes_id_fkey" FOREIGN KEY ("supersedes_id") REFERENCES "public"."recovery_incident_rate_revisions_v2"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."matrix_locations_v2"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_schedule_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."published_schedules_v2"("id");


--
-- Name: recovery_incidents_v2 recovery_incidents_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_incidents_v2"
    ADD CONSTRAINT "recovery_incidents_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_month_revisions_v2 recovery_month_revisions_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_month_revisions_v2"
    ADD CONSTRAINT "recovery_month_revisions_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_offer_responses_v2 recovery_offer_responses_v2_action_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_offer_responses_v2"
    ADD CONSTRAINT "recovery_offer_responses_v2_action_id_fkey" FOREIGN KEY ("action_id") REFERENCES "public"."recovery_actions_v2"("id") ON DELETE CASCADE;


--
-- Name: recovery_offer_responses_v2 recovery_offer_responses_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_offer_responses_v2"
    ADD CONSTRAINT "recovery_offer_responses_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id");


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_incident_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_incident_id_fkey" FOREIGN KEY ("incident_id") REFERENCES "public"."recovery_incidents_v2"("id") ON DELETE CASCADE;


--
-- Name: recovery_overrides_v2 recovery_overrides_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."recovery_overrides_v2"
    ADD CONSTRAINT "recovery_overrides_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: role_plan_assignments role_plan_assignments_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_assignments"
    ADD CONSTRAINT "role_plan_assignments_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."assignments"("id") ON DELETE CASCADE;


--
-- Name: role_plan_assignments role_plan_assignments_role_plan_section_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_assignments"
    ADD CONSTRAINT "role_plan_assignments_role_plan_section_id_fkey" FOREIGN KEY ("role_plan_section_id") REFERENCES "public"."role_plan_sections"("id") ON DELETE CASCADE;


--
-- Name: role_plan_sections role_plan_sections_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id");


--
-- Name: role_plan_sections role_plan_sections_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: role_plan_sections role_plan_sections_legacy_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_legacy_plan_id_fkey" FOREIGN KEY ("legacy_plan_id") REFERENCES "public"."plans"("id") ON DELETE SET NULL;


--
-- Name: role_plan_sections role_plan_sections_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: role_plan_sections role_plan_sections_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."role_plan_sections"
    ADD CONSTRAINT "role_plan_sections_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles"("id");


--
-- Name: shift_definitions shift_definitions_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_definitions"
    ADD CONSTRAINT "shift_definitions_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");


--
-- Name: shift_swap_history_v2 shift_swap_history_v2_actor_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_history_v2"
    ADD CONSTRAINT "shift_swap_history_v2_actor_id_fkey" FOREIGN KEY ("actor_id") REFERENCES "auth"."users"("id");


--
-- Name: shift_swap_history_v2 shift_swap_history_v2_request_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_history_v2"
    ADD CONSTRAINT "shift_swap_history_v2_request_id_fkey" FOREIGN KEY ("request_id") REFERENCES "public"."shift_swap_requests_v2"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_accepted_by_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_accepted_by_employee_id_fkey" FOREIGN KEY ("accepted_by_employee_id") REFERENCES "public"."employees"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_leader_decided_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_leader_decided_by_fkey" FOREIGN KEY ("leader_decided_by") REFERENCES "auth"."users"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_original_assignment_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_original_assignment_id_fkey" FOREIGN KEY ("original_assignment_id") REFERENCES "public"."plan_assignments_v2"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_proposer_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_proposer_employee_id_fkey" FOREIGN KEY ("proposer_employee_id") REFERENCES "public"."employees"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_replacement_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_replacement_id_fkey" FOREIGN KEY ("replacement_id") REFERENCES "public"."operational_assignment_replacements_v2"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_role_id_fkey" FOREIGN KEY ("role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: shift_swap_requests_v2 shift_swap_requests_v2_target_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shift_swap_requests_v2"
    ADD CONSTRAINT "shift_swap_requests_v2_target_employee_id_fkey" FOREIGN KEY ("target_employee_id") REFERENCES "public"."employees"("id");


--
-- Name: shifts shifts_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_location_id_fkey" FOREIGN KEY ("location_id") REFERENCES "public"."locations"("id");


--
-- Name: shifts shifts_plan_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_plan_id_fkey" FOREIGN KEY ("plan_id") REFERENCES "public"."plans"("id") ON DELETE CASCADE;


--
-- Name: shifts shifts_source_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."shifts"
    ADD CONSTRAINT "shifts_source_event_id_fkey" FOREIGN KEY ("source_event_id") REFERENCES "public"."operational_events"("id");


--
-- Name: solver_feature_flags solver_feature_flags_updated_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."solver_feature_flags"
    ADD CONSTRAINT "solver_feature_flags_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id") ON DELETE SET NULL;


--
-- Name: tasks tasks_assigned_to_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_assigned_to_fkey" FOREIGN KEY ("assigned_to") REFERENCES "auth"."users"("id");


--
-- Name: tasks tasks_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: tasks tasks_source_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."tasks"
    ADD CONSTRAINT "tasks_source_event_id_fkey" FOREIGN KEY ("source_event_id") REFERENCES "public"."operational_events"("id") ON DELETE CASCADE;


--
-- Name: team_conversation_members_v1 team_conversation_members_v1_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversation_members_v1"
    ADD CONSTRAINT "team_conversation_members_v1_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: team_conversation_members_v1 team_conversation_members_v1_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversation_members_v1"
    ADD CONSTRAINT "team_conversation_members_v1_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."team_conversations_v1"("id") ON DELETE CASCADE;


--
-- Name: team_conversation_members_v1 team_conversation_members_v1_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversation_members_v1"
    ADD CONSTRAINT "team_conversation_members_v1_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE SET NULL;


--
-- Name: team_conversations_v1 team_conversations_v1_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_conversations_v1"
    ADD CONSTRAINT "team_conversations_v1_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;


--
-- Name: team_messages_v1 team_messages_v1_conversation_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_messages_v1"
    ADD CONSTRAINT "team_messages_v1_conversation_id_fkey" FOREIGN KEY ("conversation_id") REFERENCES "public"."team_conversations_v1"("id") ON DELETE CASCADE;


--
-- Name: team_messages_v1 team_messages_v1_sender_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."team_messages_v1"
    ADD CONSTRAINT "team_messages_v1_sender_user_id_fkey" FOREIGN KEY ("sender_user_id") REFERENCES "auth"."users"("id") ON DELETE RESTRICT;


--
-- Name: time_records time_records_approved_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."time_records"
    ADD CONSTRAINT "time_records_approved_by_fkey" FOREIGN KEY ("approved_by") REFERENCES "auth"."users"("id");


--
-- Name: time_records time_records_employee_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."time_records"
    ADD CONSTRAINT "time_records_employee_id_fkey" FOREIGN KEY ("employee_id") REFERENCES "public"."employees"("id") ON DELETE CASCADE;


--
-- Name: user_permissions user_permissions_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."user_permissions"
    ADD CONSTRAINT "user_permissions_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: user_profiles_v1 user_profiles_v1_auth_user_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."user_profiles_v1"
    ADD CONSTRAINT "user_profiles_v1_auth_user_id_fkey" FOREIGN KEY ("auth_user_id") REFERENCES "auth"."users"("id") ON DELETE CASCADE;


--
-- Name: workforce_calendar_events_v2 workforce_calendar_events_v2_cancelled_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_calendar_events_v2"
    ADD CONSTRAINT "workforce_calendar_events_v2_cancelled_by_fkey" FOREIGN KEY ("cancelled_by") REFERENCES "auth"."users"("id");


--
-- Name: workforce_calendar_events_v2 workforce_calendar_events_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_calendar_events_v2"
    ADD CONSTRAINT "workforce_calendar_events_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: workforce_calendar_events_v2 workforce_calendar_events_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_calendar_events_v2"
    ADD CONSTRAINT "workforce_calendar_events_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: workforce_calendar_events_v2 workforce_calendar_events_v2_matrix_version_id_location_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_calendar_events_v2"
    ADD CONSTRAINT "workforce_calendar_events_v2_matrix_version_id_location_id_fkey" FOREIGN KEY ("matrix_version_id", "location_id") REFERENCES "public"."matrix_locations_v2"("matrix_version_id", "id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."workforce_calendar_events_v2"("id") ON DELETE CASCADE;


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_matrix_version_id_duty_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_matrix_version_id_duty_id_fkey" FOREIGN KEY ("matrix_version_id", "duty_id") REFERENCES "public"."matrix_duties_v2"("matrix_version_id", "id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id");


--
-- Name: workforce_event_demand_v2 workforce_event_demand_v2_matrix_version_id_shift_template_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_event_demand_v2"
    ADD CONSTRAINT "workforce_event_demand_v2_matrix_version_id_shift_template_fkey" FOREIGN KEY ("matrix_version_id", "shift_template_id") REFERENCES "public"."matrix_shift_templates_v2"("matrix_version_id", "id");


--
-- Name: workforce_hot_day_limits_v2 workforce_hot_day_limits_v2_event_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_hot_day_limits_v2"
    ADD CONSTRAINT "workforce_hot_day_limits_v2_event_id_fkey" FOREIGN KEY ("event_id") REFERENCES "public"."workforce_calendar_events_v2"("id") ON DELETE CASCADE;


--
-- Name: workforce_hot_day_limits_v2 workforce_hot_day_limits_v2_matrix_version_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_hot_day_limits_v2"
    ADD CONSTRAINT "workforce_hot_day_limits_v2_matrix_version_id_fkey" FOREIGN KEY ("matrix_version_id") REFERENCES "public"."matrix_versions"("id");


--
-- Name: workforce_hot_day_limits_v2 workforce_hot_day_limits_v2_matrix_version_id_role_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: postgres
--

ALTER TABLE ONLY "public"."workforce_hot_day_limits_v2"
    ADD CONSTRAINT "workforce_hot_day_limits_v2_matrix_version_id_role_id_fkey" FOREIGN KEY ("matrix_version_id", "role_id") REFERENCES "public"."matrix_roles_v2"("matrix_version_id", "id");


--
-- Name: leader_variant_history_cursor_v2 leader_variant_history_cursor_v2_current_seq_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_cursor_v2"
    ADD CONSTRAINT "leader_variant_history_cursor_v2_current_seq_fkey" FOREIGN KEY ("current_seq") REFERENCES "solver_private"."leader_variant_history_v2"("seq") ON DELETE CASCADE;


--
-- Name: leader_variant_history_cursor_v2 leader_variant_history_cursor_v2_updated_by_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_cursor_v2"
    ADD CONSTRAINT "leader_variant_history_cursor_v2_updated_by_fkey" FOREIGN KEY ("updated_by") REFERENCES "auth"."users"("id");


--
-- Name: leader_variant_history_cursor_v2 leader_variant_history_cursor_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_cursor_v2"
    ADD CONSTRAINT "leader_variant_history_cursor_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: leader_variant_history_v2 leader_variant_history_v2_created_by_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_v2"
    ADD CONSTRAINT "leader_variant_history_v2_created_by_fkey" FOREIGN KEY ("created_by") REFERENCES "auth"."users"("id");


--
-- Name: leader_variant_history_v2 leader_variant_history_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."leader_variant_history_v2"
    ADD CONSTRAINT "leader_variant_history_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: optimization_attempts_v2 optimization_attempts_v2_run_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."optimization_attempts_v2"
    ADD CONSTRAINT "optimization_attempts_v2_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs_v2"("id") ON DELETE CASCADE;


--
-- Name: optimization_snapshots_v2 optimization_snapshots_v2_run_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."optimization_snapshots_v2"
    ADD CONSTRAINT "optimization_snapshots_v2_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_assignment_cost_components_v2 plan_assignment_cost_components_v2_assignment_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_assignment_cost_components_v2"
    ADD CONSTRAINT "plan_assignment_cost_components_v2_assignment_id_fkey" FOREIGN KEY ("assignment_id") REFERENCES "public"."plan_assignments_v2"("id") ON DELETE CASCADE;


--
-- Name: plan_assignment_cost_components_v2 plan_assignment_cost_components_v2_pay_rule_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_assignment_cost_components_v2"
    ADD CONSTRAINT "plan_assignment_cost_components_v2_pay_rule_id_fkey" FOREIGN KEY ("pay_rule_id") REFERENCES "public"."matrix_pay_rules_v2"("id");


--
-- Name: plan_variant_finance_v2 plan_variant_finance_v2_variant_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."plan_variant_finance_v2"
    ADD CONSTRAINT "plan_variant_finance_v2_variant_id_fkey" FOREIGN KEY ("variant_id") REFERENCES "public"."plan_variants_v2"("id") ON DELETE CASCADE;


--
-- Name: published_schedule_finance_v2 published_schedule_finance_v2_schedule_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."published_schedule_finance_v2"
    ADD CONSTRAINT "published_schedule_finance_v2_schedule_id_fkey" FOREIGN KEY ("schedule_id") REFERENCES "public"."published_schedules_v2"("id") ON DELETE CASCADE;


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_organization_key_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_organization_key_fkey" FOREIGN KEY ("organization_key") REFERENCES "public"."matrix_versions"("id");


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_run_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_run_id_fkey" FOREIGN KEY ("run_id") REFERENCES "public"."optimization_runs_v2"("id") ON DELETE CASCADE;


--
-- Name: solver_job_dispatch_outbox_uat_v1 solver_job_dispatch_outbox_uat_v1_scope_role_id_fkey; Type: FK CONSTRAINT; Schema: solver_private; Owner: postgres
--

ALTER TABLE ONLY "solver_private"."solver_job_dispatch_outbox_uat_v1"
    ADD CONSTRAINT "solver_job_dispatch_outbox_uat_v1_scope_role_id_fkey" FOREIGN KEY ("scope_role_id") REFERENCES "public"."matrix_roles_v2"("id");


--
-- Name: application_access_directory_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."application_access_directory_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: application_finance_visibility_policy_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."application_finance_visibility_policy_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: assignments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."assignments" ENABLE ROW LEVEL SECURITY;

--
-- Name: attendance_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."attendance_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: audit_log; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."audit_log" ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_budgets authenticated_reads_budgets; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_budgets" ON "public"."monthly_budgets" FOR SELECT TO "authenticated" USING (true);


--
-- Name: demand_rules authenticated_reads_demand_rules; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_demand_rules" ON "public"."demand_rules" FOR SELECT TO "authenticated" USING (true);


--
-- Name: employee_capabilities authenticated_reads_employee_capabilities; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_employee_capabilities" ON "public"."employee_capabilities" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_capabilities"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id")));


--
-- Name: employee_locations authenticated_reads_employee_locations; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_employee_locations" ON "public"."employee_locations" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_locations"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id")));


--
-- Name: event_demand_changes authenticated_reads_event_demand; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_event_demand" ON "public"."event_demand_changes" FOR SELECT TO "authenticated" USING (true);


--
-- Name: operational_events authenticated_reads_events; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_events" ON "public"."operational_events" FOR SELECT TO "authenticated" USING (true);


--
-- Name: locations authenticated_reads_locations; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_locations" ON "public"."locations" FOR SELECT TO "authenticated" USING (true);


--
-- Name: plans authenticated_reads_plans; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_plans" ON "public"."plans" FOR SELECT TO "authenticated" USING ((("status" = 'PUBLISHED'::"public"."plan_status") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: roles authenticated_reads_roles; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_roles" ON "public"."roles" FOR SELECT TO "authenticated" USING (true);


--
-- Name: shift_definitions authenticated_reads_shift_definitions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "authenticated_reads_shift_definitions" ON "public"."shift_definitions" FOR SELECT TO "authenticated" USING (true);


--
-- Name: availability_exception_reviews_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."availability_exception_reviews_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: availability_exception_reviews_v2 availability_exception_self_or_manager_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "availability_exception_self_or_manager_read_v2" ON "public"."availability_exception_reviews_v2" FOR SELECT TO "authenticated" USING ((("employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ( SELECT "public"."can_manage_plans"() AS "can_manage_plans") OR ( SELECT "public"."has_app_role"('HR_FINANCE'::"public"."app_role") AS "has_app_role")));


--
-- Name: employee_availability_history availability_history_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "availability_history_read" ON "public"."employee_availability_history" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_availability_history"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id")));


--
-- Name: employee_availability availability_manage; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "availability_manage" ON "public"."employee_availability" TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_availability"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id"))) WITH CHECK (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_availability"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id")));


--
-- Name: employee_availability availability_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "availability_read" ON "public"."employee_availability" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "employee_availability"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "employee_id")));


--
-- Name: business_app_integrations_v1 business integrations use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "business integrations use rpc only" ON "public"."business_app_integrations_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: business_app_integrations_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."business_app_integrations_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: composite_schedules; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."composite_schedules" ENABLE ROW LEVEL SECURITY;

--
-- Name: demand_rules; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."demand_rules" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_availability; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_availability" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_availability_history; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_availability_history" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_capabilities; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_capabilities" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_hr_profiles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_hr_profiles" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_locations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_locations" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_pay_rates_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_pay_rates_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_pay_rates_v2_read" ON "public"."employee_pay_rates_v2" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: employee_pay_rates_v2 employee_pay_rates_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_pay_rates_v2_write" ON "public"."employee_pay_rates_v2" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: employee_preferences; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_preferences" ENABLE ROW LEVEL SECURITY;

--
-- Name: assignments employee_reads_own_assignments; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_reads_own_assignments" ON "public"."assignments" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "assignments"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("id")));


--
-- Name: attendance_events employee_reads_own_attendance; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_reads_own_attendance" ON "public"."attendance_events" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "attendance_events"."employee_id") AND ("employee"."auth_user_id" = "auth"."uid"())))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR "public"."matrix_v2_can_manage_legacy_resource_uat_v1"(NULL::"text", "location_id", "employee_id")));


--
-- Name: shifts employee_reads_published_shifts; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_reads_published_shifts" ON "public"."shifts" FOR SELECT TO "authenticated" USING (((EXISTS ( SELECT 1
   FROM "public"."plans" "plan"
  WHERE (("plan"."id" = "shifts"."plan_id") AND ("plan"."status" = 'PUBLISHED'::"public"."plan_status")))) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: employees employee_reads_self; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_reads_self" ON "public"."employees" FOR SELECT TO "authenticated" USING ((("auth_user_id" = "auth"."uid"()) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR "public"."matrix_v2_can_manage_resource_uat_v1"(NULL::"uuid", NULL::"uuid", "id")));


--
-- Name: employee_requests_v1 employee_requests_self_or_manager_read_v1; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_requests_self_or_manager_read_v1" ON "public"."employee_requests_v1" FOR SELECT TO "authenticated" USING ((("requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."matrix_v2_can_manage_employee"("employee_id")));


--
-- Name: employee_requests_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_requests_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_time_constraints_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_time_constraints_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_insert; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_time_constraints_v2_insert" ON "public"."employee_time_constraints_v2" FOR INSERT TO "authenticated" WITH CHECK (("public"."can_manage_plans"() OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (("source" = 'GRAFIK_PRO'::"text") AND "editable_by_employee" AND ("constraint_kind" = ANY (ARRAY['AVAILABLE_WINDOW'::"text", 'UNAVAILABLE'::"text"])) AND ("created_by" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_time_constraints_v2"."employee_id") AND ("e"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_time_constraints_v2_read" ON "public"."employee_time_constraints_v2" FOR SELECT TO "authenticated" USING ("public"."matrix_v2_can_manage_employee"("employee_id"));


--
-- Name: employee_time_constraints_v2 employee_time_constraints_v2_update; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_time_constraints_v2_update" ON "public"."employee_time_constraints_v2" FOR UPDATE TO "authenticated" USING (("public"."can_manage_plans"() OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (("source" = 'GRAFIK_PRO'::"text") AND "editable_by_employee" AND ("created_by" = ( SELECT "auth"."uid"() AS "uid")) AND (EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_time_constraints_v2"."employee_id") AND ("e"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))))))) WITH CHECK (("public"."can_manage_plans"() OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (("source" = 'GRAFIK_PRO'::"text") AND "editable_by_employee" AND ("created_by" = ( SELECT "auth"."uid"() AS "uid")) AND ("constraint_kind" = ANY (ARRAY['AVAILABLE_WINDOW'::"text", 'UNAVAILABLE'::"text"])) AND (EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_time_constraints_v2"."employee_id") AND ("e"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid"))))))));


--
-- Name: employee_weekly_work_patterns_v2 employee_weekly_work_patterns_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employee_weekly_work_patterns_read" ON "public"."employee_weekly_work_patterns_v2" FOR SELECT TO "authenticated" USING (("public"."can_manage_plans"() OR "public"."matrix_v2_can_manage_employee"("employee_id")));


--
-- Name: employee_weekly_work_patterns_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employee_weekly_work_patterns_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: employees; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employees" ENABLE ROW LEVEL SECURITY;

--
-- Name: employer_cost_components_v2 employer_cost_components_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "employer_cost_components_read_v2" ON "public"."employer_cost_components_v2" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: employer_cost_components_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."employer_cost_components_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: event_demand_changes; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."event_demand_changes" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rule_duties_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_pay_rule_duties_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_duties_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_pay_rule_locations_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_pay_rule_locations_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_locations_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_pay_rule_roles_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_pay_rule_roles_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_roles_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_pay_rule_shifts_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_pay_rule_shifts_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_shifts_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_pay_rules_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_pay_rules_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rules_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_scenario_budgets_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_scenario_budgets_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_budgets_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_scenario_pay_rule_overrides_v2 finance_matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_read" ON "public"."matrix_scenario_pay_rule_overrides_v2" FOR SELECT TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_pay_rule_overrides_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_pay_rule_duties_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_pay_rule_duties_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_pay_rule_locations_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_pay_rule_locations_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_pay_rule_roles_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_pay_rule_roles_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_pay_rule_shifts_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_pay_rule_shifts_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_shifts_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rule_shifts_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_pay_rules_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_pay_rules_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rules_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_pay_rules_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_scenario_budgets_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_scenario_budgets_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_budgets_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_budgets_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_scenario_pay_rule_overrides_v2 finance_matrix_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "finance_matrix_v2_write" ON "public"."matrix_scenario_pay_rule_overrides_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_pay_rule_overrides_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_pay_rule_overrides_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: employee_hr_profiles hr_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "hr_read" ON "public"."employee_hr_profiles" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "employee_hr_profiles"."employee_id") AND ("e"."auth_user_id" = "auth"."uid"()))))));


--
-- Name: employee_hr_profiles hr_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "hr_write" ON "public"."employee_hr_profiles" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: recovery_incident_rate_revisions_v2 incident_rates_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "incident_rates_read_v2" ON "public"."recovery_incident_rate_revisions_v2" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: integration_runs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."integration_runs" ENABLE ROW LEVEL SECURITY;

--
-- Name: locations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."locations" ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_budgets managers_manage_budgets; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "managers_manage_budgets" ON "public"."monthly_budgets" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")));


--
-- Name: operational_events managers_manage_events; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "managers_manage_events" ON "public"."operational_events" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_legacy_resource_uat_v1"(NULL::"text", "location_id", NULL::"uuid"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_legacy_resource_uat_v1"(NULL::"text", "location_id", NULL::"uuid")));


--
-- Name: matrix_conflicts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_conflicts" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_demand; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_demand" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_duties_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_duties_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_employee_duties_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_duties_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_employee_locations_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_locations_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_employee_profiles_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_profiles_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_employee_profiles_v2 matrix_employee_profiles_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_employee_profiles_v2_read" ON "public"."matrix_employee_profiles_v2" FOR SELECT TO "authenticated" USING (("public"."can_manage_plans"() OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (EXISTS ( SELECT 1
   FROM "public"."employees" "e"
  WHERE (("e"."id" = "matrix_employee_profiles_v2"."employee_id") AND ("e"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))))));


--
-- Name: matrix_employee_roles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_roles" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_employee_roles matrix_employee_roles_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_employee_roles_read" ON "public"."matrix_employee_roles" FOR SELECT TO "authenticated" USING ((("public"."can_manage_plans"() OR (EXISTS ( SELECT 1
   FROM "public"."employees" "employee"
  WHERE (("employee"."id" = "matrix_employee_roles"."employee_id") AND ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))))) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_roles"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_employee_roles_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_employee_roles_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_functions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_functions" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_import_runs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_import_runs" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_import_runs matrix_import_runs_owner; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_import_runs_owner" ON "public"."matrix_import_runs" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: matrix_locations; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_locations" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_locations_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_locations_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rule_duties_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_pay_rule_duties_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rule_locations_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_pay_rule_locations_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rule_roles_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_pay_rule_roles_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rule_shifts_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_pay_rule_shifts_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_pay_rules_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_pay_rules_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_demand matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_demand" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."matrix_shift_templates" "shift_row"
     JOIN "public"."matrix_versions" "mv" ON (("mv"."id" = "shift_row"."matrix_version_id")))
  WHERE (("shift_row"."id" = "matrix_demand"."shift_template_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_functions matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_functions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_functions"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_locations matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_locations" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_locations"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_role_functions matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_role_functions" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."matrix_roles" "role_row"
     JOIN "public"."matrix_versions" "mv" ON (("mv"."id" = "role_row"."matrix_version_id")))
  WHERE (("role_row"."id" = "matrix_role_functions"."role_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_roles matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_roles" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_roles"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_shift_templates matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_shift_templates" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_shift_templates"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_versions matrix_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_read" ON "public"."matrix_versions" FOR SELECT TO "authenticated" USING ((("status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: matrix_role_categories_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_role_categories_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_role_categories_v2 matrix_role_categories_v2_select; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_role_categories_v2_select" ON "public"."matrix_role_categories_v2" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role") OR (EXISTS ( SELECT 1
   FROM "public"."matrix_roles_v2" "role"
  WHERE (("role"."category_id" = "matrix_role_categories_v2"."id") AND "role"."active" AND "public"."matrix_v2_can_manage_resource_uat_v1"("role"."id", NULL::"uuid", NULL::"uuid"))))));


--
-- Name: matrix_role_duties_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_role_duties_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_role_functions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_role_functions" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_roles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_roles" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_roles_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_roles_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scenario_budgets_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scenario_budgets_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scenario_pay_rule_overrides_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scenario_pay_rule_overrides_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scenario_strategies_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scenario_strategies_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scenarios; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scenarios" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scenarios matrix_scenarios_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_scenarios_read" ON "public"."matrix_scenarios" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenarios"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_scenarios_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scenarios_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scope_grants_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_scope_grants_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_scope_grants_v2_read" ON "public"."matrix_scope_grants_v2" FOR SELECT TO "authenticated" USING ((("auth_user_id" = ( SELECT "auth"."uid"() AS "uid")) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: matrix_scope_grants_v2 matrix_scope_grants_v2_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_scope_grants_v2_write" ON "public"."matrix_scope_grants_v2" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: matrix_shift_templates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_shift_templates" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_shift_templates_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_shift_templates_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_staffing_rules_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_staffing_rules_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_strategies_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_strategies_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_strategy_objectives_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_strategy_objectives_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: matrix_duties_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_duties_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_locations_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_locations_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_role_duties_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_role_duties_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_role_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_role_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_roles_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_roles_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_scenario_strategies_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_scenario_strategies_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_strategies_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_strategies_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_scenarios_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_scenarios_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenarios_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenarios_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_shift_templates_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_shift_templates_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_shift_templates_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_shift_templates_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_staffing_rules_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_staffing_rules_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_staffing_rules_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_staffing_rules_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_strategies_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_strategies_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategies_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategies_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_strategy_objectives_v2 matrix_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_admin_write" ON "public"."matrix_strategy_objectives_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategy_objectives_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategy_objectives_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_duties_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_duties_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_duties_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_locations_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_locations_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_locations_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_role_duties_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_role_duties_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_role_duties_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_roles_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_roles_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_roles_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_scenario_strategies_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_scenario_strategies_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenario_strategies_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_scenarios_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_scenarios_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_scenarios_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_shift_templates_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_shift_templates_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_shift_templates_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_staffing_rules_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_staffing_rules_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_staffing_rules_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_strategies_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_strategies_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategies_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_strategy_objectives_v2 matrix_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "matrix_v2_read" ON "public"."matrix_strategy_objectives_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_strategy_objectives_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))))));


--
-- Name: matrix_versions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."matrix_versions" ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_budget_lines_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."monthly_budget_lines_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_budget_revisions_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."monthly_budget_revisions_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: monthly_budgets; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."monthly_budgets" ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."notifications" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_audience_rules_v1 operational audiences use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational audiences use rpc only" ON "public"."operational_program_audience_rules_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_program_audit_v1 operational audit uses rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational audit uses rpc only" ON "public"."operational_program_audit_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_program_checklist_items_v1 operational checklists use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational checklists use rpc only" ON "public"."operational_program_checklist_items_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_program_events_v1 operational events use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational events use rpc only" ON "public"."operational_program_events_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_program_inventory_links_v1 operational inventory links use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational inventory links use rpc only" ON "public"."operational_program_inventory_links_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_program_participants_v1 operational participants use rpc only; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational participants use rpc only" ON "public"."operational_program_participants_v1" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_assignment_overrides_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_assignment_overrides_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_assignment_overrides_v2 operational_assignment_overrides_v2_deny_direct; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational_assignment_overrides_v2_deny_direct" ON "public"."operational_assignment_overrides_v2" TO "authenticated" USING (false) WITH CHECK (false);


--
-- Name: operational_assignment_replacements_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_assignment_replacements_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_events; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_events" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_audience_rules_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_audience_rules_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_audit_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_audit_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_checklist_items_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_checklist_items_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_events_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_events_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_inventory_links_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_inventory_links_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_program_participants_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."operational_program_participants_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: operational_assignment_replacements_v2 operational_replacements_self_or_manager_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "operational_replacements_self_or_manager_read_v2" ON "public"."operational_assignment_replacements_v2" FOR SELECT TO "authenticated" USING ((( SELECT "public"."can_manage_plans"() AS "can_manage_plans") OR ("replacement_employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("original_assignment_id" IN ( SELECT "assignment"."id"
   FROM ("public"."plan_assignments_v2" "assignment"
     JOIN "public"."employees" "employee" ON (("employee"."id" = "assignment"."employee_id")))
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: optimization_candidates; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."optimization_candidates" ENABLE ROW LEVEL SECURITY;

--
-- Name: optimization_candidates optimization_candidates_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "optimization_candidates_read" ON "public"."optimization_candidates" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."optimization_runs" "r"
  WHERE (("r"."id" = "optimization_candidates"."run_id") AND "public"."can_manage_plans"()))));


--
-- Name: optimization_run_strategies_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."optimization_run_strategies_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: optimization_run_strategies_v2 optimization_run_strategies_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "optimization_run_strategies_v2_read" ON "public"."optimization_run_strategies_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."optimization_runs_v2" "r"
  WHERE (("r"."id" = "optimization_run_strategies_v2"."run_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: optimization_runs; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."optimization_runs" ENABLE ROW LEVEL SECURITY;

--
-- Name: optimization_runs optimization_runs_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "optimization_runs_read" ON "public"."optimization_runs" FOR SELECT TO "authenticated" USING ("public"."can_manage_plans"());


--
-- Name: optimization_runs_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."optimization_runs_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: optimization_runs_v2 optimization_runs_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "optimization_runs_v2_read" ON "public"."optimization_runs_v2" FOR SELECT TO "authenticated" USING ((("requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role")));


--
-- Name: optimizer_profiles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."optimizer_profiles" ENABLE ROW LEVEL SECURITY;

--
-- Name: optimizer_profiles optimizer_profiles_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "optimizer_profiles_read" ON "public"."optimizer_profiles" FOR SELECT TO "authenticated" USING (("public"."can_manage_plans"() AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "optimizer_profiles"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: plan_assignment_duties_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_assignment_duties_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_assignment_duties_v2 plan_assignment_duties_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_assignment_duties_v2_read" ON "public"."plan_assignment_duties_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM (("public"."plan_assignments_v2" "a"
     JOIN "public"."plan_variants_v2" "v" ON (("v"."id" = "a"."variant_id")))
     JOIN "public"."optimization_runs_v2" "r" ON (("r"."id" = "v"."run_id")))
  WHERE (("a"."id" = "plan_assignment_duties_v2"."assignment_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: plan_assignments_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_assignments_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_assignments_v2 plan_assignments_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_assignments_v2_read" ON "public"."plan_assignments_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."plan_variants_v2" "v"
     JOIN "public"."optimization_runs_v2" "r" ON (("r"."id" = "v"."run_id")))
  WHERE (("v"."id" = "plan_assignments_v2"."variant_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: plan_issues; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_issues" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_issues plan_issues_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_issues_read" ON "public"."plan_issues" FOR SELECT TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("id")));


--
-- Name: plan_issues_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_issues_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_issues_v2 plan_issues_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_issues_v2_read" ON "public"."plan_issues_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."plan_variants_v2" "v"
     JOIN "public"."optimization_runs_v2" "r" ON (("r"."id" = "v"."run_id")))
  WHERE (("v"."id" = "plan_issues_v2"."variant_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: plan_shifts_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_shifts_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_shifts_v2 plan_shifts_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_shifts_v2_read" ON "public"."plan_shifts_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM ("public"."plan_variants_v2" "v"
     JOIN "public"."optimization_runs_v2" "r" ON (("r"."id" = "v"."run_id")))
  WHERE (("v"."id" = "plan_shifts_v2"."variant_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: plan_variants_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plan_variants_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: plan_variants_v2 plan_variants_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "plan_variants_v2_read" ON "public"."plan_variants_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."optimization_runs_v2" "r"
  WHERE (("r"."id" = "plan_variants_v2"."run_id") AND (("r"."requested_by" = ( SELECT "auth"."uid"() AS "uid")) OR ( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role"))))));


--
-- Name: plans; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."plans" ENABLE ROW LEVEL SECURITY;

--
-- Name: published_role_schedules_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."published_role_schedules_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: published_role_schedules_v2 published_role_schedules_v2_manager_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "published_role_schedules_v2_manager_read" ON "public"."published_role_schedules_v2" FOR SELECT TO "authenticated" USING ((( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role") OR (EXISTS ( SELECT 1
   FROM ("public"."matrix_roles_v2" "role"
     JOIN "public"."matrix_scope_grants_v2" "grant_row" ON ((("grant_row"."role_logical_id" IS NULL) OR ("grant_row"."role_logical_id" = "role"."logical_id"))))
  WHERE (("role"."id" = "published_role_schedules_v2"."role_id") AND ("grant_row"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")) AND "grant_row"."active" AND ("grant_row"."app_role" = 'ROLE_MANAGER'::"public"."app_role"))))));


--
-- Name: published_schedule_variants_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."published_schedule_variants_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: published_schedule_variants_v2 published_schedule_variants_v2_manage_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "published_schedule_variants_v2_manage_read" ON "public"."published_schedule_variants_v2" FOR SELECT TO "authenticated" USING (((( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('HR_FINANCE'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('VERIFIER'::"public"."app_role") AS "has_app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."published_schedules_v2" "s"
  WHERE ("s"."id" = "published_schedule_variants_v2"."schedule_id")))));


--
-- Name: published_schedules_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."published_schedules_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: published_schedules_v2 published_schedules_v2_manage_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "published_schedules_v2_manage_read" ON "public"."published_schedules_v2" FOR SELECT TO "authenticated" USING ((( SELECT "public"."has_app_role"('OWNER'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('ADMIN'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('HR_FINANCE'::"public"."app_role") AS "has_app_role") OR ( SELECT "public"."has_app_role"('VERIFIER'::"public"."app_role") AS "has_app_role")));


--
-- Name: published_standby_assignments_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."published_standby_assignments_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: published_standby_assignments_v2 published_standby_self_or_manager_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "published_standby_self_or_manager_read_v2" ON "public"."published_standby_assignments_v2" FOR SELECT TO "authenticated" USING ((("employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ( SELECT "public"."can_manage_plans"() AS "can_manage_plans") OR ( SELECT "public"."has_app_role"('HR_FINANCE'::"public"."app_role") AS "has_app_role")));


--
-- Name: recovery_actions_v2 recovery_actions_manage_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_actions_manage_v2" ON "public"."recovery_actions_v2" FOR SELECT TO "authenticated" USING (( SELECT "public"."can_manage_plans"() AS "can_manage_plans"));


--
-- Name: recovery_actions_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_actions_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_ad_hoc_pool_v2 recovery_ad_hoc_manage_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_ad_hoc_manage_v2" ON "public"."recovery_ad_hoc_pool_v2" FOR SELECT TO "authenticated" USING (( SELECT "public"."can_manage_plans"() AS "can_manage_plans"));


--
-- Name: recovery_ad_hoc_pool_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_ad_hoc_pool_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_incident_rate_revisions_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_incident_rate_revisions_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_incidents_v2 recovery_incidents_manage_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_incidents_manage_v2" ON "public"."recovery_incidents_v2" FOR SELECT TO "authenticated" USING (( SELECT "public"."can_manage_plans"() AS "can_manage_plans"));


--
-- Name: recovery_incidents_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_incidents_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_month_revisions_v2 recovery_month_revisions_manage_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_month_revisions_manage_v2" ON "public"."recovery_month_revisions_v2" FOR SELECT TO "authenticated" USING (( SELECT "public"."can_manage_plans"() AS "can_manage_plans"));


--
-- Name: recovery_month_revisions_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_month_revisions_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_offer_responses_v2 recovery_offer_participant_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_offer_participant_v2" ON "public"."recovery_offer_responses_v2" FOR SELECT TO "authenticated" USING ((( SELECT "public"."can_manage_plans"() AS "can_manage_plans") OR ("employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid"))))));


--
-- Name: recovery_offer_responses_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_offer_responses_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: recovery_overrides_v2 recovery_overrides_manage_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "recovery_overrides_manage_v2" ON "public"."recovery_overrides_v2" FOR SELECT TO "authenticated" USING (( SELECT "public"."can_manage_plans"() AS "can_manage_plans"));


--
-- Name: recovery_overrides_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."recovery_overrides_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: role_plan_assignments; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."role_plan_assignments" ENABLE ROW LEVEL SECURITY;

--
-- Name: role_plan_assignments role_plan_assignments_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "role_plan_assignments_read" ON "public"."role_plan_assignments" FOR SELECT TO "authenticated" USING ("public"."can_manage_plans"());


--
-- Name: role_plan_sections; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."role_plan_sections" ENABLE ROW LEVEL SECURITY;

--
-- Name: roles; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."roles" ENABLE ROW LEVEL SECURITY;

--
-- Name: shift_definitions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."shift_definitions" ENABLE ROW LEVEL SECURITY;

--
-- Name: shift_swap_history_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."shift_swap_history_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: shift_swap_history_v2 shift_swap_history_visible_participants_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "shift_swap_history_visible_participants_v2" ON "public"."shift_swap_history_v2" FOR SELECT TO "authenticated" USING ((EXISTS ( SELECT 1
   FROM "public"."shift_swap_requests_v2" "request"
  WHERE ("request"."id" = "shift_swap_history_v2"."request_id"))));


--
-- Name: shift_swap_requests_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."shift_swap_requests_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: shift_swap_requests_v2 shift_swap_visible_participants_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "shift_swap_visible_participants_v2" ON "public"."shift_swap_requests_v2" FOR SELECT TO "authenticated" USING ((("proposer_employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("target_employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("accepted_by_employee_id" IN ( SELECT "employee"."id"
   FROM "public"."employees" "employee"
  WHERE ("employee"."auth_user_id" = ( SELECT "auth"."uid"() AS "uid")))) OR ("status" = 'OPEN'::"text") OR ( SELECT "public"."can_manage_plans"() AS "can_manage_plans")));


--
-- Name: shifts; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."shifts" ENABLE ROW LEVEL SECURITY;

--
-- Name: solver_feature_flags; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."solver_feature_flags" ENABLE ROW LEVEL SECURITY;

--
-- Name: solver_feature_flags solver_feature_flags_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "solver_feature_flags_read" ON "public"."solver_feature_flags" FOR SELECT TO "authenticated" USING (true);


--
-- Name: solver_feature_flags solver_feature_flags_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "solver_feature_flags_write" ON "public"."solver_feature_flags" TO "authenticated" USING (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role"))) WITH CHECK (("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: tasks; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."tasks" ENABLE ROW LEVEL SECURITY;

--
-- Name: team_conversation_members_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."team_conversation_members_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: team_conversations_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."team_conversations_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: team_messages_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."team_messages_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: time_records; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."time_records" ENABLE ROW LEVEL SECURITY;

--
-- Name: uat_environment_controls; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."uat_environment_controls" ENABLE ROW LEVEL SECURITY;

--
-- Name: user_permissions; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."user_permissions" ENABLE ROW LEVEL SECURITY;

--
-- Name: user_profiles_v1 user_profiles_self_insert_v1; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "user_profiles_self_insert_v1" ON "public"."user_profiles_v1" FOR INSERT TO "authenticated" WITH CHECK (("auth_user_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: user_profiles_v1 user_profiles_self_read_v1; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "user_profiles_self_read_v1" ON "public"."user_profiles_v1" FOR SELECT TO "authenticated" USING (("auth_user_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: user_profiles_v1 user_profiles_self_update_v1; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "user_profiles_self_update_v1" ON "public"."user_profiles_v1" FOR UPDATE TO "authenticated" USING (("auth_user_id" = ( SELECT "auth"."uid"() AS "uid"))) WITH CHECK (("auth_user_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: user_profiles_v1; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."user_profiles_v1" ENABLE ROW LEVEL SECURITY;

--
-- Name: notifications user_reads_own_notifications; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "user_reads_own_notifications" ON "public"."notifications" FOR SELECT TO "authenticated" USING (("recipient_id" = ( SELECT "auth"."uid"() AS "uid")));


--
-- Name: tasks user_reads_own_tasks; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "user_reads_own_tasks" ON "public"."tasks" FOR SELECT USING ((("assigned_to" = "auth"."uid"()) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: user_permissions users_read_own_permissions; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "users_read_own_permissions" ON "public"."user_permissions" FOR SELECT TO "authenticated" USING ((("auth_user_id" = "auth"."uid"()) OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")));


--
-- Name: workforce_calendar_events_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."workforce_calendar_events_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: workforce_event_demand_v2 workforce_event_demand_authenticated_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_event_demand_authenticated_read_v2" ON "public"."workforce_event_demand_v2" FOR SELECT TO "authenticated" USING (true);


--
-- Name: workforce_event_demand_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."workforce_event_demand_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: workforce_calendar_events_v2 workforce_events_authenticated_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_events_authenticated_read_v2" ON "public"."workforce_calendar_events_v2" FOR SELECT TO "authenticated" USING (true);


--
-- Name: workforce_hot_day_limits_v2; Type: ROW SECURITY; Schema: public; Owner: postgres
--

ALTER TABLE "public"."workforce_hot_day_limits_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: workforce_hot_day_limits_v2 workforce_hot_limits_authenticated_read_v2; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_hot_limits_authenticated_read_v2" ON "public"."workforce_hot_day_limits_v2" FOR SELECT TO "authenticated" USING (true);


--
-- Name: matrix_employee_duties_v2 workforce_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_admin_write" ON "public"."matrix_employee_duties_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_duties_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_employee_locations_v2 workforce_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_admin_write" ON "public"."matrix_employee_locations_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_locations_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_employee_roles_v2 workforce_v2_admin_write; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_admin_write" ON "public"."matrix_employee_roles_v2" TO "authenticated" USING ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text")))))) WITH CHECK ((("public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role") OR "public"."has_app_role"('HR_FINANCE'::"public"."app_role")) AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_roles_v2"."matrix_version_id") AND ("mv"."status" = 'DRAFT'::"text"))))));


--
-- Name: matrix_employee_duties_v2 workforce_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_read" ON "public"."matrix_employee_duties_v2" FOR SELECT TO "authenticated" USING (("public"."matrix_v2_can_manage_employee"("employee_id") AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_duties_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_employee_locations_v2 workforce_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_read" ON "public"."matrix_employee_locations_v2" FOR SELECT TO "authenticated" USING (("public"."matrix_v2_can_manage_employee"("employee_id") AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_locations_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: matrix_employee_roles_v2 workforce_v2_read; Type: POLICY; Schema: public; Owner: postgres
--

CREATE POLICY "workforce_v2_read" ON "public"."matrix_employee_roles_v2" FOR SELECT TO "authenticated" USING (("public"."matrix_v2_can_manage_employee"("employee_id") AND (EXISTS ( SELECT 1
   FROM "public"."matrix_versions" "mv"
  WHERE (("mv"."id" = "matrix_employee_roles_v2"."matrix_version_id") AND (("mv"."status" = 'ACTIVE'::"text") OR "public"."has_app_role"('OWNER'::"public"."app_role") OR "public"."has_app_role"('ADMIN'::"public"."app_role")))))));


--
-- Name: leader_variant_history_cursor_v2; Type: ROW SECURITY; Schema: solver_private; Owner: postgres
--

ALTER TABLE "solver_private"."leader_variant_history_cursor_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: leader_variant_history_v2; Type: ROW SECURITY; Schema: solver_private; Owner: postgres
--

ALTER TABLE "solver_private"."leader_variant_history_v2" ENABLE ROW LEVEL SECURITY;

--
-- Name: mx_k10_legacy_role_duty_archive; Type: ROW SECURITY; Schema: solver_private; Owner: postgres
--

ALTER TABLE "solver_private"."mx_k10_legacy_role_duty_archive" ENABLE ROW LEVEL SECURITY;

--
-- Name: SCHEMA "solver_private"; Type: ACL; Schema: -; Owner: postgres
--

GRANT USAGE ON SCHEMA "solver_private" TO "service_role";


--
-- Name: FUNCTION "calendar_event_allowed_uat_v1"("p_event_id" "uuid"); Type: ACL; Schema: authorization_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "authorization_private"."calendar_event_allowed_uat_v1"("p_event_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "calendar_payload_allowed_uat_v1"("p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb"); Type: ACL; Schema: authorization_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "authorization_private"."calendar_payload_allowed_uat_v1"("p_location_id" "uuid", "p_demands" "jsonb", "p_hot_limits" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "enter_resource_scope_uat_v1"(); Type: ACL; Schema: authorization_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "authorization_private"."enter_resource_scope_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_visible_employee_ids_uat_v1"(); Type: ACL; Schema: authorization_private; Owner: postgres
--

REVOKE ALL ON FUNCTION "authorization_private"."matrix_v2_visible_employee_ids_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "application_access_bulk_apply_uat_v1"("p_rows" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_access_bulk_apply_uat_v1"("p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_access_bulk_apply_uat_v1"("p_rows" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_access_bulk_apply_uat_v1"("p_rows" "jsonb") TO "service_role";


--
-- Name: FUNCTION "application_access_directory_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_access_directory_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_access_directory_uat_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_access_directory_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "application_access_materialize_uat_v1"("p_email" "text", "p_auth_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_access_materialize_uat_v1"("p_email" "text", "p_auth_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_access_materialize_uat_v1"("p_email" "text", "p_auth_user_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid", "p_location_id" "uuid", "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid", "p_location_id" "uuid", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid", "p_location_id" "uuid", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_access_save_uat_v1"("p_email" "text", "p_app_role" "text", "p_role_id" "uuid", "p_location_id" "uuid", "p_active" boolean) TO "service_role";


--
-- Name: FUNCTION "application_finance_visibility_current_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_finance_visibility_current_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_finance_visibility_current_uat_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_finance_visibility_current_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "application_finance_visibility_policy_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_finance_visibility_policy_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_finance_visibility_policy_uat_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_finance_visibility_policy_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."application_finance_visibility_save_uat_v1"("p_app_role" "text", "p_visibility" "text") TO "service_role";


--
-- Name: FUNCTION "assemble_role_plans"("p_month" "date", "p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."assemble_role_plans"("p_month" "date", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."assemble_role_plans"("p_month" "date", "p_name" "text") TO "service_role";


--
-- Name: FUNCTION "attendance_clock"("p_action" "text", "p_location" "text", "p_latitude" numeric, "p_longitude" numeric); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."attendance_clock"("p_action" "text", "p_location" "text", "p_latitude" numeric, "p_longitude" numeric) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."attendance_clock"("p_action" "text", "p_location" "text", "p_latitude" numeric, "p_longitude" numeric) TO "service_role";


--
-- Name: FUNCTION "availability_exception_review_before_phase1_uat_v1"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."availability_exception_review_before_phase1_uat_v1"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."availability_exception_review_before_phase1_uat_v1"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."availability_exception_review_uat_v2"("p_review_id" "uuid", "p_decision" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "budget_update"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."budget_update"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."budget_update"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) TO "service_role";


--
-- Name: FUNCTION "can_manage_plans"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."can_manage_plans"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_manage_plans"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_manage_plans"() TO "service_role";


--
-- Name: FUNCTION "can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code") TO "authenticated";
GRANT ALL ON FUNCTION "public"."can_view_assignment"("p_employee_id" "uuid", "p_role" "public"."employee_role", "p_location" "public"."location_code") TO "service_role";


--
-- Name: FUNCTION "claim_demo_owner"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."claim_demo_owner"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."claim_demo_owner"() TO "service_role";


--
-- Name: FUNCTION "complete_workspace"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."complete_workspace"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_workspace"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."complete_workspace"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "complete_workspace_before_b4f101_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."complete_workspace_before_b4f101_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."complete_workspace_before_b4f101_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "create_operational_event"("p_location" "public"."location_code", "p_event_type" "text", "p_title" "text", "p_description" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_expected_guests" integer, "p_status" "public"."event_status", "p_demand" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_operational_event"("p_location" "public"."location_code", "p_event_type" "text", "p_title" "text", "p_description" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_expected_guests" integer, "p_status" "public"."event_status", "p_demand" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_operational_event"("p_location" "public"."location_code", "p_event_type" "text", "p_title" "text", "p_description" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_expected_guests" integer, "p_status" "public"."event_status", "p_demand" "jsonb") TO "service_role";


--
-- Name: FUNCTION "create_role_plan_section"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."create_role_plan_section"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."create_role_plan_section"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") TO "service_role";


--
-- Name: FUNCTION "current_user_access"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."current_user_access"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_user_access"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_access"() TO "service_role";


--
-- Name: FUNCTION "current_user_access_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."current_user_access_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."current_user_access_v2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."current_user_access_v2"() TO "service_role";


--
-- Name: FUNCTION "emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."emergency_assign"("p_shift_id" "uuid", "p_employee_id" "uuid", "p_role" "public"."employee_role", "p_notify" boolean) TO "service_role";


--
-- Name: FUNCTION "employee_archive"("p_employee_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_archive"("p_employee_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_archive"("p_employee_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_availability_bulk_save_v2"("p_from" "date", "p_to" "date", "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_availability_days_save_uat_v3"("p_dates" "date"[], "p_kind" "text", "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_preferred_location_id" "uuid", "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v1"("p_employee_id" "uuid", "p_dates" "date"[]) TO "authenticated";


--
-- Name: FUNCTION "employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone) TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_availability_publication_conflicts_uat_v2"("p_employee_id" "uuid", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone) TO "authenticated";


--
-- Name: FUNCTION "employee_availability_save_month"("p_month" "date", "p_entries" "jsonb", "p_default_remaining_available" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_availability_save_month"("p_month" "date", "p_entries" "jsonb", "p_default_remaining_available" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_availability_save_month"("p_month" "date", "p_entries" "jsonb", "p_default_remaining_available" boolean) TO "service_role";


--
-- Name: FUNCTION "employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text", "p_contract_type" "text", "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text", "p_contract_type" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text", "p_contract_type" "text", "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_pay_rate_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_base_rate_minor" bigint, "p_currency" "text", "p_contract_type" "text", "p_active" boolean) TO "authenticated";


--
-- Name: FUNCTION "employee_portal_workspace"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_portal_workspace"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_portal_workspace"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."employee_portal_workspace"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_request_review_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_request_submit_uat_v1"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_request_submit_uat_v2"("p_request_type" "text", "p_dates" "date"[], "p_all_day" boolean, "p_local_start" time without time zone, "p_local_end" time without time zone, "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_restore"("p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_restore"("p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_restore"("p_employee_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_shift_preferences_save_self_v2"("p_month" "date", "p_preferences" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "employee_shift_preferences_self_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_shift_preferences_self_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_shift_preferences_self_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_shift_preferences_self_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "employee_time_constraint_revoke_v2"("p_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_time_constraint_revoke_v2"("p_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_time_constraint_revoke_v2"("p_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_time_constraint_revoke_v2"("p_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_time_constraint_save_v2"("p_id" "uuid", "p_employee_id" "uuid", "p_kind" "text", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_note" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_time_constraints_self_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_time_constraints_self_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "employee_update"("p_employee_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_update"("p_employee_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_update"("p_employee_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "employee_weekly_work_patterns_replace_before_phase1_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_weekly_work_patterns_replace_before_phase1_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_weekly_work_patterns_replace_before_phase1_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_weekly_work_patterns_replace_uat_v1"("p_employee_id" "uuid", "p_valid_from" "date", "p_valid_to" "date", "p_patterns" "jsonb", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."employee_weekly_work_patterns_workspace_uat_v1"("p_employee_id" "uuid", "p_on_date" "date") TO "authenticated";


--
-- Name: FUNCTION "employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."employer_cost_component_save_uat_v1"("p_logical_id" "uuid", "p_code" "text", "p_name" "text", "p_calculation_method" "text", "p_value" bigint, "p_contract_type" "text", "p_valid_from" "date", "p_valid_to" "date", "p_active" boolean, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "employer_cost_workspace_before_b4f101_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employer_cost_workspace_before_b4f101_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employer_cost_workspace_before_b4f101_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "employer_cost_workspace_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."employer_cost_workspace_uat_v1"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_plan"("p_month" "date", "p_name" "text", "p_scenario_code" "text", "p_optimization_mode" "text", "p_staffing_level" "text") TO "service_role";


--
-- Name: FUNCTION "generate_role_plan"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."generate_role_plan"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."generate_role_plan"("p_month" "date", "p_role_id" "uuid", "p_name" "text", "p_scenario" "text", "p_mode" "text", "p_staffing" "text") TO "service_role";


--
-- Name: FUNCTION "has_app_role"("required_role" "public"."app_role"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."has_app_role"("required_role" "public"."app_role") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."has_app_role"("required_role" "public"."app_role") TO "authenticated";
GRANT ALL ON FUNCTION "public"."has_app_role"("required_role" "public"."app_role") TO "service_role";


--
-- Name: FUNCTION "kadromierz_export"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."kadromierz_export"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."kadromierz_export"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "kadromierz_import_preferences"("p_file_name" "text", "p_rows" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."kadromierz_import_preferences"("p_file_name" "text", "p_rows" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."kadromierz_import_preferences"("p_file_name" "text", "p_rows" "jsonb") TO "service_role";


--
-- Name: FUNCTION "log_availability_change"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."log_availability_change"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."log_availability_change"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."log_availability_change"() TO "service_role";


--
-- Name: FUNCTION "manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."manager_standby_month_uat_v2"("p_month" "date", "p_scope_role_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."manager_standby_month_uat_v3"("p_month" "date", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "matrix_create_draft"("p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_create_draft"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_create_draft"("p_name" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_import_apply"("p_file_name" "text", "p_payload" "jsonb", "p_requested_permissions" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_import_apply"("p_file_name" "text", "p_payload" "jsonb", "p_requested_permissions" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_import_apply"("p_file_name" "text", "p_payload" "jsonb", "p_requested_permissions" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_publish_draft"("p_effective_from" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_publish_draft"("p_effective_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_publish_draft"("p_effective_from" "date") TO "service_role";


--
-- Name: FUNCTION "matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_register_import"("p_file_name" "text", "p_summary" "jsonb", "p_requested_permissions" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_save_demand"("p_shift_id" "uuid", "p_role_id" "uuid", "p_required" integer, "p_scenario" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_save_demand"("p_shift_id" "uuid", "p_role_id" "uuid", "p_required" integer, "p_scenario" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_save_demand"("p_shift_id" "uuid", "p_role_id" "uuid", "p_required" integer, "p_scenario" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_save_item"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_save_shift"("p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_save_shift"("p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_save_shift"("p_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_duty_id" "uuid", "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_duty_id" "uuid", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_duty_id" "uuid", "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_scope_grant_save_v2"("p_id" "uuid", "p_auth_user_id" "uuid", "p_app_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_duty_id" "uuid", "p_active" boolean) TO "authenticated";


--
-- Name: FUNCTION "matrix_shift_color_preserve_on_clone_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_shift_color_preserve_on_clone_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_shift_color_preserve_on_clone_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_alpha16"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_b4f118"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_categories_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_admin_save_before_mx_k10"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_before_mx_k10"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_groups_uat_v1"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_admin_save_before_standby_setting"("p_kind" "text", "p_id" "uuid", "p_data" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_can_manage_employee"("p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_can_manage_employee"("p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_employee"("p_employee_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_employee"("p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_assignment_uat_v1"("p_assignment_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_plan_issue_uat_v1"("p_issue_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_legacy_resource_uat_v1"("p_role_code" "text", "p_legacy_location_id" "uuid", "p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_can_manage_resource_uat_v1"("p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_compare_versions_uat_v2"("p_left_version_id" "uuid", "p_right_version_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_content_document"("p_matrix_version_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_content_document"("p_matrix_version_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_content_document"("p_matrix_version_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_create_draft"("p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_create_draft"("p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_create_draft"("p_name" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_create_draft"("p_name" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_discard_current_draft_uat_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_discard_current_draft_uat_v2"() TO "service_role";


--
-- Name: FUNCTION "matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_discard_draft_uat_v1"("p_matrix_version_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_duty_archive_preview_uat_v2"("p_duty_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_duty_archive_uat_v2"("p_duty_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_archive_v2"("p_employee_id" "uuid", "p_reason" "text", "p_archive" boolean) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_employee_directory_alpha16"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_directory_alpha16"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_directory_alpha16"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_directory_alpha16"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_employee_directory_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_directory_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_directory_v2"() TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_directory_v2"() TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_employee_save_alpha16"("p_employee_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_save_alpha16"("p_employee_id" "uuid", "p_data" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_employee_save_uat_v3"("p_employee_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_save_uat_v3"("p_employee_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_save_uat_v3"("p_employee_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid", "p_data" "jsonb") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_save_uat_v4"("p_employee_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_employee_save_v2"("p_employee_id" "uuid", "p_data" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_ensure_first_run_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_ensure_first_run_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_ensure_first_run_uat_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_ensure_first_run_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_import_apply_uat_v1"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_import_preview_uat_v1"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_finance_step_skip_uat_v2"("p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_apply_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_apply_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_preview_raw_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_full_import_preview_uat_v1"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_has_any_manager_scope_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_has_any_manager_scope_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_has_any_manager_scope_uat_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_has_any_manager_scope_uat_v1"() TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_apply_alpha16"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_alpha16"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_before_mx_k10"("p_payload" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v2"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v2"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v2"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v2"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v3"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v4"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_apply_uat_v5"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_preview_alpha16"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_alpha16"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_before_mx_k10"("p_payload" "jsonb") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_import_preview_uat_v2"("p_payload" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v2"("p_payload" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v2"("p_payload" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v2"("p_payload" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v3"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v4"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_import_preview_uat_v5"("p_payload" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_is_iso_4217_currency"("p_currency" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_is_iso_4217_currency"("p_currency" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_is_iso_4217_currency"("p_currency" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_is_supported_objective_config"("p_direction" "text", "p_parameters" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_is_supported_objective_config"("p_direction" "text", "p_parameters" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_is_supported_objective_config"("p_direction" "text", "p_parameters" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_is_supported_pay_condition"("p_condition" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_is_supported_pay_condition"("p_condition" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_is_supported_pay_condition"("p_condition" "jsonb") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_merge_equivalent_shifts_uat_v2"("p_apply" boolean) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_next_employee_no_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_next_employee_no_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_next_employee_no_v2"() TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_next_employee_no_v2"() TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_normalize_shift_periods_uat_v2"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_normalize_shift_periods_uat_v2"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_normalize_shift_periods_uat_v2"() TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_normalize_shift_periods_uat_v2"() TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_prevent_last_usable_delete_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_prevent_last_usable_delete_uat_v1"() FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_publication_readiness_alpha16"("p_effective_from" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_alpha16"("p_effective_from" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_base_uat006"("p_effective_from" "date", "p_schedule_month" "date") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_b4f115"("p_effective_from" "date", "p_schedule_month" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_before_simple_roles_uat_v1"("p_effective_from" "date", "p_schedule_month" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."matrix_v2_publication_readiness_uat_v2"("p_effective_from" "date", "p_schedule_month" "date") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_publish_draft"("p_effective_from" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publish_draft"("p_effective_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publish_draft"("p_effective_from" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_publish_draft"("p_effective_from" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_publish_draft_uat_v2"("p_effective_from" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_publish_draft_uat_v2"("p_effective_from" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_publish_draft_uat_v2"("p_effective_from" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_publish_draft_uat_v2"("p_effective_from" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_revision_history_uat_v2"("p_limit" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_revision_history_uat_v2"("p_limit" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_revision_history_uat_v2"("p_limit" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_revision_history_uat_v2"("p_limit" integer) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_scope_allows_resource_for_app_role_uat_v1"("p_manager_role" "public"."app_role", "p_role_id" "uuid", "p_location_id" "uuid", "p_employee_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_shift_staffing_save_uat_v3"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_stable_uuid"("p_value" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_stable_uuid"("p_value" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_stable_uuid"("p_value" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid", "p_shift_period" "text", "p_role_id" "uuid", "p_delta" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid", "p_shift_period" "text", "p_role_id" "uuid", "p_delta" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid", "p_shift_period" "text", "p_role_id" "uuid", "p_delta" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_staffing_bulk_adjust_uat_v2"("p_scenario_id" "uuid", "p_location_id" "uuid", "p_shift_period" "text", "p_role_id" "uuid", "p_delta" integer) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_staffing_rules_bulk_save_uat_v2"("p_scenario_id" "uuid", "p_shift_template_ids" "uuid"[], "p_role_id" "uuid", "p_duty_id" "uuid", "p_operation" "text", "p_count_value" integer, "p_multiplier_basis_points" integer, "p_active" boolean) TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1"("p_configuration" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_apply_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1"("p_configuration" "jsonb", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260814"("p_configuration" "jsonb", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_team_import_preview_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_team_import_preview_uat_v1_core_20260824"("p_configuration" "jsonb", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "matrix_v2_workspace"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_v2_workspace"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "matrix_v2_workspace_before_ad_hoc_projection_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_ad_hoc_projection_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_workspace_before_b4f52_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_b4f52_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_workspace_before_b4f91_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_b4f91_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_workspace_before_categories_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_categories_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_employee_privacy_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_v2_workspace_before_overtime_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_v2_workspace_before_overtime_uat_v1"("p_month" "date") FROM PUBLIC;


--
-- Name: FUNCTION "matrix_workspace"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."matrix_workspace"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."matrix_workspace"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "message_center_workspace_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."message_center_workspace_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_center_workspace_uat_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."message_center_workspace_uat_v1"() TO "authenticated";


--
-- Name: FUNCTION "message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text", "p_context_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text", "p_context_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text", "p_context_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."message_conversation_create_uat_v1"("p_recipient_auth_user_id" "uuid", "p_subject" "text", "p_message" "text", "p_context_type" "text", "p_context_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "message_display_name_uat_v1"("p_auth_user_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."message_display_name_uat_v1"("p_auth_user_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_display_name_uat_v1"("p_auth_user_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "message_mark_read_uat_v1"("p_conversation_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."message_mark_read_uat_v1"("p_conversation_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_mark_read_uat_v1"("p_conversation_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."message_mark_read_uat_v1"("p_conversation_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."message_send_uat_v1"("p_conversation_id" "uuid", "p_body" "text") TO "authenticated";


--
-- Name: FUNCTION "monthly_budgets_get_before_b4f52_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."monthly_budgets_get_before_b4f52_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."monthly_budgets_get_before_b4f52_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "monthly_budgets_get_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."monthly_budgets_get_uat_v1"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."monthly_budgets_save_uat_v1"("p_month" "date", "p_lines" "jsonb", "p_note" "text") TO "service_role";


--
-- Name: FUNCTION "operational_program_can_manage_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_can_manage_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_can_manage_uat_v1"() TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_can_manage_uat_v1"() TO "service_role";


--
-- Name: FUNCTION "operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_cancel_uat_v1"("p_event_id" "uuid", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text", "p_active" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text", "p_active" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text", "p_active" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_integration_save_uat_v1"("p_base_url" "text", "p_launch_path_template" "text", "p_active" boolean) TO "service_role";


--
-- Name: FUNCTION "operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text", "p_error" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text", "p_error" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_inventory_ack_uat_v1"("p_event_id" "uuid", "p_external_session_id" "text", "p_external_session_url" "text", "p_status" "text", "p_error" "text") TO "service_role";


--
-- Name: FUNCTION "operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid", "p_category_ids" "uuid"[], "p_role_ids" "uuid"[], "p_employee_ids" "uuid"[], "p_required_count" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid", "p_category_ids" "uuid"[], "p_role_ids" "uuid"[], "p_employee_ids" "uuid"[], "p_required_count" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid", "p_category_ids" "uuid"[], "p_role_ids" "uuid"[], "p_employee_ids" "uuid"[], "p_required_count" integer) TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_preview_uat_v1"("p_month" "date", "p_starts_at" timestamp with time zone, "p_ends_at" timestamp with time zone, "p_location_id" "uuid", "p_category_ids" "uuid"[], "p_role_ids" "uuid"[], "p_employee_ids" "uuid"[], "p_required_count" integer) TO "service_role";


--
-- Name: FUNCTION "operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb", "p_checklist" "jsonb", "p_participant_ids" "uuid"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb", "p_checklist" "jsonb", "p_participant_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb", "p_checklist" "jsonb", "p_participant_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_save_uat_v1"("p_event" "jsonb", "p_audience" "jsonb", "p_checklist" "jsonb", "p_participant_ids" "uuid"[]) TO "service_role";


--
-- Name: FUNCTION "operational_program_workspace_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."operational_program_workspace_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."operational_program_workspace_uat_v1"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."operational_program_workspace_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "optimizer_abort_finalize_v4"("p_run_id" "uuid", "p_error" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_abort_finalize_v4"("p_run_id" "uuid", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_abort_finalize_v4"("p_run_id" "uuid", "p_error" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_active_workspace_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_active_workspace_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_begin_finalize_v4"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_begin_finalize_v4"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_begin_finalize_v4"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_before_primary_rules_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_candidate_diagnostics_before_role_scope_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_checkpoint_v2"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_checkpoint_v2"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_checkpoint_v2"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_commit"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_commit"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_commit"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_complete_finalize_v4"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_complete_finalize_v4"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_complete_finalize_v4"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_configuration_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_configuration_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_create_leader_variant_uat_v1"("p_run_id" "uuid", "p_source_variant_id" "uuid", "p_name" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_create_manual_leader_studio_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_solver_version" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_demand_profiles_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_demand_profiles_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_demand_profiles_uat_v1"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_demand_profiles_uat_v1"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_emergency_assign_alpha16"("p_schedule_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_soft" boolean, "p_reason" "text", "p_notify" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_employee_availability_month_uat_v1"("p_variant_id" "uuid", "p_employee_ids" "uuid"[]) TO "authenticated";


--
-- Name: FUNCTION "optimizer_employee_published_schedule_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_employee_published_schedule_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_employee_schedule_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_employee_schedule_uat_v3"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v3"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v3"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_employee_schedule_uat_v3"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_fail_v3"("p_run_id" "uuid", "p_error" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_fail_v3"("p_run_id" "uuid", "p_error" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_fail_v3"("p_run_id" "uuid", "p_error" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_finalize_v2"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_finalize_v2"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_finalize_v2"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_finalize_v3"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_finalize_v3"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_finalize_v3"("p_run_id" "uuid", "p_name" "text", "p_candidates" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_generation_quota_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_generation_quota_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_generation_quota_uat_v1"() TO "authenticated";


--
-- Name: FUNCTION "optimizer_job_status_uat_v1"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_job_status_uat_v1"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_job_status_uat_v1"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_kadromierz_export_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_kadromierz_export_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_kadromierz_export_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_kadromierz_export_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_before_b4_details_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_before_b4_details_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_before_b4_details_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_before_daily_limit_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_context_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_preview_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_drag_uat_v1"("p_variant_id" "uuid", "p_source_assignment_id" "uuid", "p_target_assignment_id" "uuid", "p_target_issue_id" bigint, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_lock_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_locked" boolean, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_remove_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v3"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_save_uat_v4"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_reason" "text", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v1"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignment_validate_uat_v2"("p_variant_id" "uuid", "p_assignment_id" "uuid", "p_issue_id" bigint, "p_employee_id" "uuid", "p_allow_limit_override" boolean, "p_duty_transfer_assignment_id" "uuid", "p_approve_overtime" boolean) TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_assignments_bulk_uat_v1"("p_variant_id" "uuid", "p_assignment_ids" "uuid"[], "p_operation" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_checkpoint_create_uat_v1"("p_variant_id" "uuid", "p_name" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_checkpoint_restore_uat_v1"("p_variant_id" "uuid", "p_history_seq" bigint, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_draft_validate_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_history_move_uat_v1"("p_variant_id" "uuid", "p_direction" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_history_status_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_refill_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_refill_request_uat_v1"("p_variant_id" "uuid", "p_reason" "text", "p_idempotency_key" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_reoptimization_apply_uat_v1"("p_leader_variant_id" "uuid", "p_source_variant_id" "uuid", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_reoptimization_request_uat_v1"("p_variant_id" "uuid", "p_mode" "text", "p_reason" "text", "p_idempotency_key" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_variant_for_run_uat_v1"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_variant_workspace_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_workflow_status_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_leader_workflow_transition_uat_v1"("p_variant_id" "uuid", "p_target_status" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_materialize_candidate_v3"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_materialize_candidate_v3"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_materialize_candidate_v3"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_materialize_candidate_v4"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_materialize_candidate_v4"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_materialize_candidate_v4"("p_run_id" "uuid", "p_name" "text", "p_candidate" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_materialize_next_v4"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_materialize_next_v4"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_materialize_next_v4"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_operational_workspace_alpha16"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_operational_workspace_alpha16"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_prepare"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_prepare"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_prepare"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) TO "service_role";


--
-- Name: FUNCTION "optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_prepare_v2"("p_month" "date", "p_profile_code" "text", "p_scenario_code" "text", "p_seed" integer) TO "service_role";


--
-- Name: FUNCTION "optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publication_attempt_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publication_change_preview_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publication_readiness_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publish_company_variant_alpha16"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publish_company_variant_resolved_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text", "p_role_replacement_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_company_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_composite_before_phase1_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_composite_uat_v3"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text", "p_warning_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_composite_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[], "p_name" "text", "p_idempotency_key" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_variant_before_b4f121_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") TO "service_role";


--
-- Name: FUNCTION "optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_publish_role_variant_uat_v2"("p_run_id" "uuid", "p_variant_id" "uuid", "p_name" "text", "p_idempotency_key" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_published_schedule_alpha16"("p_schedule_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_published_schedule_alpha16"("p_schedule_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_published_schedule_v2"("p_schedule_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_published_schedule_v2"("p_schedule_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_published_schedule_v2"("p_schedule_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_published_schedule_v2"("p_schedule_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_request_before_nfjob_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_before_nfjob_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_request_cancel_before_nfjob_uat_v1"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_cancel_before_nfjob_uat_v1"("p_run_id" "uuid") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_request_cancel_v2"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_cancel_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_request_cancel_v2"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_request_job_uat_v1"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text") FROM PUBLIC;


--
-- Name: FUNCTION "optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_request_v2"("p_month" "date", "p_scenario_id" "uuid", "p_scope_type" "text", "p_scope_role_id" "uuid", "p_name" "text", "p_idempotency_key" "text", "p_frontend_version" "text") TO "authenticated";


--
-- Name: FUNCTION "optimizer_role_categories_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_categories_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_categories_uat_v1"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_role_categories_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "optimizer_role_colours_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_colours_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_colours_uat_v1"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_role_colours_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_candidates_before_categories_uat_v1"("p_month" "date", "p_scenario_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_role_composite_candidates_before_publication_fallback"("p_month" "date", "p_scenario_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_composite_candidates_before_publication_fallback"("p_month" "date", "p_scenario_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_candidates_before_publication_fallback"("p_month" "date", "p_scenario_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_candidates_v2"("p_month" "date", "p_scenario_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]) TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_role_composite_preflight_uat_v2"("p_month" "date", "p_scenario_id" "uuid", "p_variant_ids" "uuid"[]) TO "service_role";


--
-- Name: FUNCTION "optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_role_publication_overview_before_categories_uat_v1"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "optimizer_role_publication_overview_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_role_publication_overview_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_role_publication_overview_uat_v2"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_role_publication_overview_uat_v2"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "optimizer_run_state_v2"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_run_state_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_run_state_v2"("p_run_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_runs_catalog_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_runs_catalog_before_b4f101_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_runs_catalog_before_b4f101_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_runs_catalog_before_b4f101_alpha16"("p_month" "date", "p_scope_type" "text", "p_scope_role_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_save_init_v4"("p_run_id" "uuid", "p_expected_cursor" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_save_init_v4"("p_run_id" "uuid", "p_expected_cursor" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_save_init_v4"("p_run_id" "uuid", "p_expected_cursor" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_save_state_v3"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_save_state_v3"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_save_state_v3"("p_run_id" "uuid", "p_expected_generation" integer, "p_checkpoint" "jsonb", "p_metrics" "jsonb") TO "service_role";


--
-- Name: FUNCTION "optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_select_variant_v2"("p_run_id" "uuid", "p_variant_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_alpha16"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_selected_variant_workspace_v2"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_selected_variant_workspace_v2"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_status_v2"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_status_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_status_v2"("p_run_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_status_v2"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_b4_details_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_b4_details_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_b4_details_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_capacity_context_uat"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_capacity_context_uat"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_capacity_context_uat"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_primary_rules_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_profile_limits_uat_v"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_profile_limits_uat_v"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_profile_limits_uat_v"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_before_role_scope_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variant_issue_diagnostics_uat_v2"("p_variant_id" "uuid", "p_issue_id" bigint) TO "authenticated";


--
-- Name: FUNCTION "optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_before_shortage_guard_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v1"("p_variant_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid") TO "authenticated";
GRANT ALL ON FUNCTION "public"."optimizer_variant_standby_preview_uat_v2"("p_variant_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variant_workload_distribution_uat_v1"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variant_workspace_uat_v2"("p_variant_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_variants_before_b4f52_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variants_before_b4f52_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variants_before_b4f52_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "optimizer_variants_v2"("p_run_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variants_v2"("p_run_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variants_v2"("p_run_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variants_v2"("p_run_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "optimizer_variants_v3"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."optimizer_variants_v3"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."optimizer_variants_v3"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."optimizer_variants_v3"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "personal_action_workspace_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_action_workspace_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_action_workspace_uat_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_action_workspace_uat_v1"() TO "authenticated";


--
-- Name: FUNCTION "personal_message_action_route_uat_v1"("p_auth_user_id" "uuid", "p_conversation_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_message_action_route_uat_v1"("p_auth_user_id" "uuid", "p_conversation_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_message_action_route_uat_v1"("p_auth_user_id" "uuid", "p_conversation_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "personal_notification_mark_read_uat_v1"("p_notification_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_notification_mark_read_uat_v1"("p_notification_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_notification_mark_read_uat_v1"("p_notification_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_notification_mark_read_uat_v1"("p_notification_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text", "p_note_color" "text", "p_photo_path" "text", "p_ui_preferences" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text", "p_note_color" "text", "p_photo_path" "text", "p_ui_preferences" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text", "p_note_color" "text", "p_photo_path" "text", "p_ui_preferences" "jsonb") TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_profile_save_uat_v1"("p_display_name" "text", "p_avatar_mode" "text", "p_cat_avatar_key" "text", "p_note_color" "text", "p_photo_path" "text", "p_ui_preferences" "jsonb") TO "authenticated";


--
-- Name: FUNCTION "personal_profile_workspace_uat_v1"(); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_profile_workspace_uat_v1"() FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_profile_workspace_uat_v1"() TO "service_role";
GRANT ALL ON FUNCTION "public"."personal_profile_workspace_uat_v1"() TO "authenticated";


--
-- Name: FUNCTION "personal_request_manager_recipients_uat_v1"("p_employee_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."personal_request_manager_recipients_uat_v1"("p_employee_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."personal_request_manager_recipients_uat_v1"("p_employee_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "plan_workspace"("p_month" "date", "p_plan_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."plan_workspace"("p_month" "date", "p_plan_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."plan_workspace"("p_month" "date", "p_plan_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."plan_workspace"("p_month" "date", "p_plan_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "plan_workspace_before_b4f52_uat_v1"("p_month" "date", "p_plan_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."plan_workspace_before_b4f52_uat_v1"("p_month" "date", "p_plan_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."plan_workspace_before_b4f52_uat_v1"("p_month" "date", "p_plan_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "preference_save"("p_employee_id" "uuid", "p_from" "date", "p_to" "date", "p_type" "text", "p_value" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."preference_save"("p_employee_id" "uuid", "p_from" "date", "p_to" "date", "p_type" "text", "p_value" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."preference_save"("p_employee_id" "uuid", "p_from" "date", "p_to" "date", "p_type" "text", "p_value" "jsonb") TO "service_role";


--
-- Name: FUNCTION "publish_plan"("p_plan_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."publish_plan"("p_plan_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."publish_plan"("p_plan_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "published_company_calendar_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."published_company_calendar_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."published_company_calendar_uat_v2"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "published_employee_category_calendar_uat_v3"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."published_employee_category_calendar_uat_v3"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_action_select_candidate_uat_v1"("p_action_id" "uuid", "p_employee_id" "uuid", "p_expected_action_version" integer, "p_expected_revision" integer) TO "authenticated";


--
-- Name: FUNCTION "recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recovery_ad_hoc_save_uat_v1"("p_id" "uuid", "p_employee_id" "uuid", "p_display_name" "text", "p_email" "text", "p_phone" "text", "p_role_id" "uuid", "p_contract_type" "text", "p_rate_minor" bigint, "p_currency" "text", "p_available_from" "date", "p_available_to" "date", "p_notes" "text") TO "service_role";


--
-- Name: FUNCTION "recovery_center_workspace_before_b4f101_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_center_workspace_before_b4f101_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_center_workspace_before_b4f101_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "recovery_center_workspace_before_phase1_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_center_workspace_before_phase1_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_center_workspace_before_phase1_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "recovery_center_workspace_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_center_workspace_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_center_workspace_uat_v1"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_center_workspace_uat_v1"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "recovery_employee_offers_uat_v1"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_employee_offers_uat_v1"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_employee_offers_uat_v1"("p_month" "date") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recovery_employee_offers_uat_v1"("p_month" "date") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_apply_draft_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer) TO "authenticated";


--
-- Name: FUNCTION "recovery_incident_detail_before_b4f101_uat_v1"("p_incident_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_detail_before_b4f101_uat_v1"("p_incident_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_detail_before_b4f101_uat_v1"("p_incident_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_detail_before_b4f88_uat_v1"("p_incident_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_detail_before_b4f88_uat_v1"("p_incident_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_detail_before_b4f88_uat_v1"("p_incident_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_detail_before_phase1_uat_v1"("p_incident_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_detail_before_phase1_uat_v1"("p_incident_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_detail_before_phase1_uat_v1"("p_incident_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_detail_uat_v1"("p_incident_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_detail_uat_v1"("p_incident_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_detail_uat_v1"("p_incident_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_detail_uat_v1"("p_incident_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "recovery_incident_prepare_before_phase1_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_prepare_before_phase1_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_prepare_before_phase1_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_prepare_uat_v1"("p_incident_id" "uuid", "p_expected_revision" integer, "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_rate_decide_uat_v1"("p_rate_id" "uuid", "p_approve" boolean, "p_approved_rate_minor" bigint, "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "recovery_incident_rate_propose_before_phase1_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_rate_propose_before_phase1_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_rate_propose_before_phase1_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_rate_propose_uat_v1"("p_incident_id" "uuid", "p_employee_id" "uuid", "p_rate_minor" bigint, "p_currency" "text", "p_valid_from" "date", "p_valid_to" "date", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "recovery_incident_save_before_phase1_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_save_before_phase1_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_save_before_phase1_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") TO "service_role";


--
-- Name: FUNCTION "recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."recovery_incident_save_uat_v1"("p_month" "date", "p_expected_revision" integer, "p_incident_id" "uuid", "p_employee_id" "uuid", "p_role_id" "uuid", "p_location_id" "uuid", "p_incident_type" "text", "p_starts_on" "date", "p_ends_on" "date", "p_title" "text", "p_notes" "text", "p_mode" "text") TO "authenticated";


--
-- Name: FUNCTION "recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recovery_month_budget_save_uat_v1"("p_month" "date", "p_amount" numeric, "p_warning_percent" integer, "p_hard_limit" boolean) TO "service_role";


--
-- Name: FUNCTION "recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text") TO "authenticated";
GRANT ALL ON FUNCTION "public"."recovery_offer_respond_uat_v1"("p_response_id" "uuid", "p_accept" boolean, "p_message" "text") TO "service_role";


--
-- Name: FUNCTION "recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean) TO "authenticated";
GRANT ALL ON FUNCTION "public"."recovery_override_save_uat_v1"("p_incident_id" "uuid", "p_override_type" "text", "p_employee_id" "uuid", "p_role_id" "uuid", "p_starts_on" "date", "p_ends_on" "date", "p_numeric_value" bigint, "p_currency" "text", "p_justification" "text", "p_employee_acknowledged" boolean, "p_compliance_confirmed" boolean) TO "service_role";


--
-- Name: FUNCTION "role_plan_assignment_delete"("p_section_id" "uuid", "p_assignment_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."role_plan_assignment_delete"("p_section_id" "uuid", "p_assignment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."role_plan_assignment_delete"("p_section_id" "uuid", "p_assignment_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "role_plan_assignment_save"("p_section_id" "uuid", "p_assignment_id" "uuid", "p_data" "jsonb"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."role_plan_assignment_save"("p_section_id" "uuid", "p_assignment_id" "uuid", "p_data" "jsonb") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."role_plan_assignment_save"("p_section_id" "uuid", "p_assignment_id" "uuid", "p_data" "jsonb") TO "service_role";


--
-- Name: FUNCTION "role_plan_refresh_conflicts"("p_section_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."role_plan_refresh_conflicts"("p_section_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."role_plan_refresh_conflicts"("p_section_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "role_plan_workspace"("p_section_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."role_plan_workspace"("p_section_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."role_plan_workspace"("p_section_id" "uuid") TO "service_role";


--
-- Name: FUNCTION "schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."schedule_publication_resolve_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."schedule_publication_resolve_with_standby_uat_v2"("p_month" "date", "p_keep_source" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "schedule_publication_status_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."schedule_publication_status_uat_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "shift_candidates"("p_shift_id" "uuid", "p_role" "public"."employee_role"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_candidates"("p_shift_id" "uuid", "p_role" "public"."employee_role") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_candidates"("p_shift_id" "uuid", "p_role" "public"."employee_role") TO "service_role";


--
-- Name: FUNCTION "shift_minutes"("p_start" timestamp with time zone, "p_end" timestamp with time zone); Type: ACL; Schema: public; Owner: postgres
--

GRANT ALL ON FUNCTION "public"."shift_minutes"("p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "authenticated";
GRANT ALL ON FUNCTION "public"."shift_minutes"("p_start" timestamp with time zone, "p_end" timestamp with time zone) TO "service_role";


--
-- Name: FUNCTION "shift_swap_board_uat_v2"("p_month" "date"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_board_uat_v2"("p_month" "date") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_board_uat_v2"("p_month" "date") TO "service_role";
GRANT ALL ON FUNCTION "public"."shift_swap_board_uat_v2"("p_month" "date") TO "authenticated";


--
-- Name: FUNCTION "shift_swap_candidates_uat_v2"("p_assignment_id" "uuid"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_candidates_uat_v2"("p_assignment_id" "uuid") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_candidates_uat_v2"("p_assignment_id" "uuid") TO "service_role";
GRANT ALL ON FUNCTION "public"."shift_swap_candidates_uat_v2"("p_assignment_id" "uuid") TO "authenticated";


--
-- Name: FUNCTION "shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."shift_swap_employee_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text") TO "authenticated";


--
-- Name: FUNCTION "shift_swap_leader_decide_before_phase1_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_leader_decide_before_phase1_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_leader_decide_before_phase1_uat_v1"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") TO "service_role";


--
-- Name: FUNCTION "shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."shift_swap_leader_decide_uat_v2"("p_request_id" "uuid", "p_decision" "text", "p_reason" "text") TO "authenticated";


--
-- Name: FUNCTION "shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid", "p_message" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid", "p_message" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid", "p_message" "text") TO "service_role";
GRANT ALL ON FUNCTION "public"."shift_swap_request_create_uat_v2"("p_assignment_id" "uuid", "p_target_employee_id" "uuid", "p_message" "text") TO "authenticated";


--
-- Name: FUNCTION "solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer) FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_claim_next_v2"("p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer) TO "service_role";


--
-- Name: FUNCTION "solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text"); Type: ACL; Schema: public; Owner: postgres
--

REVOKE ALL ON FUNCTION "public"."solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text") FROM PUBLIC;
GRANT ALL ON FUNCTION "public"."solver_claim_run_v2"("p_target_run_id" "uuid", "p_dispatch_nonce" "uuid", "p_worker_id" "text", "p_worker_version" "text", "p_task_attempt" integer, "p_lease_seconds" integer, "p_gateway_version" "text") TO "service_role";


