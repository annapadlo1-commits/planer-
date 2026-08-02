-- Authoritative Matrix v2 draft clone body. This synchronizes development
-- branches created from earlier drafts with the final source migration.

create or replace function public.matrix_v2_create_draft(p_name text default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_active public.matrix_versions%rowtype;
  v_draft_id uuid;
  v_version integer;
begin
  if not (public.has_app_role('OWNER') or public.has_app_role('ADMIN')) then
    raise exception 'FORBIDDEN';
  end if;
  perform pg_advisory_xact_lock(hashtext('matrix-v2-lifecycle'));

  select mv.id into v_draft_id
  from public.matrix_versions mv
  where mv.status='DRAFT' and mv.schema_version>=2
  order by mv.version desc limit 1;
  if v_draft_id is not null then return v_draft_id; end if;

  select * into v_active from public.matrix_versions mv
  where mv.status='ACTIVE' and mv.schema_version>=2
  order by mv.version desc limit 1;
  select coalesce(max(mv.version),0)+1 into v_version from public.matrix_versions mv;

  insert into public.matrix_versions(
    version,name,status,effective_from,settings,created_by,schema_version,base_version_id
  ) values(
    v_version,coalesce(nullif(trim(p_name),''),'Matrix v2 v'||v_version),'DRAFT',
    coalesce(v_active.effective_from,current_date),
    coalesce(v_active.settings,'{}'::jsonb),auth.uid(),2,v_active.id
  ) returning id into v_draft_id;

  if v_active.id is null then return v_draft_id; end if;

  -- Keep the last legacy-compatible projection beside Matrix v2. Until the
  -- feature flag leaves ALPHA15 this prevents publishing a v2 draft from
  -- activating a Matrix version with empty legacy tables.
  insert into public.matrix_roles(matrix_version_id,code,name,color,sort_order,active)
  select v_draft_id,r.code,r.name,r.color,r.sort_order,r.active
  from public.matrix_roles r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations(matrix_version_id,code,name,active)
  select v_draft_id,l.code,l.name,l.active
  from public.matrix_locations l where l.matrix_version_id=v_active.id;

  insert into public.matrix_functions(matrix_version_id,code,name,description,active)
  select v_draft_id,f.code,f.name,f.description,f.active
  from public.matrix_functions f where f.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates(
    matrix_version_id,location_id,code,name,starts_at,ends_at,day_mask,sort_order,active
  )
  select v_draft_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,s.day_mask,
    s.sort_order,s.active
  from public.matrix_shift_templates s
  join public.matrix_locations old_location on old_location.id=s.location_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_functions(role_id,function_id,assignment_mode)
  select nr.id,nf.id,rf.assignment_mode
  from public.matrix_role_functions rf
  join public.matrix_roles old_role on old_role.id=rf.role_id
  join public.matrix_functions old_function on old_function.id=rf.function_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_role.matrix_version_id=v_active.id
    and old_function.matrix_version_id=v_active.id;

  insert into public.matrix_demand(
    shift_template_id,role_id,function_id,scenario_code,required_count
  )
  select nsh.id,nr.id,nf.id,d.scenario_code,d.required_count
  from public.matrix_demand d
  join public.matrix_shift_templates old_shift on old_shift.id=d.shift_template_id
  join public.matrix_locations old_location on old_location.id=old_shift.location_id
  join public.matrix_roles old_role on old_role.id=d.role_id
  left join public.matrix_functions old_function on old_function.id=d.function_id
  join public.matrix_locations nl
    on nl.matrix_version_id=v_draft_id and nl.code=old_location.code
  join public.matrix_shift_templates nsh
    on nsh.matrix_version_id=v_draft_id and nsh.location_id=nl.id and nsh.code=old_shift.code
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  left join public.matrix_functions nf
    on nf.matrix_version_id=v_draft_id and nf.code=old_function.code
  where old_shift.matrix_version_id=v_active.id
    and old_role.matrix_version_id=v_active.id
    and (old_function.id is null
      or old_function.matrix_version_id=v_active.id);

  insert into public.matrix_employee_roles(
    matrix_version_id,employee_id,role_id,is_primary,can_lead
  )
  select v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead
  from public.matrix_employee_roles er
  join public.matrix_roles old_role on old_role.id=er.role_id
  join public.matrix_roles nr
    on nr.matrix_version_id=v_draft_id and nr.code=old_role.code
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios(
    matrix_version_id,code,name,description,color,active,sort_order
  )
  select v_draft_id,s.code,s.name,s.description,s.color,s.active,s.sort_order
  from public.matrix_scenarios s where s.matrix_version_id=v_active.id;

  insert into public.optimizer_profiles(
    matrix_version_id,code,name,weights,population_size,generations,elite_count,
    mutation_rate,alternatives_count,active
  )
  select v_draft_id,p.code,p.name,p.weights,p.population_size,p.generations,
    p.elite_count,p.mutation_rate,p.alternatives_count,p.active
  from public.optimizer_profiles p where p.matrix_version_id=v_active.id;

  insert into public.matrix_roles_v2(
    id,matrix_version_id,logical_id,code,name,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,r.logical_id,r.code,r.name,r.color,r.sort_order,r.active
    from public.matrix_roles_v2 r where r.matrix_version_id=v_active.id;

  insert into public.matrix_locations_v2(
    id,matrix_version_id,logical_id,code,name,timezone,sort_order,active
  ) select gen_random_uuid(),v_draft_id,l.logical_id,l.code,l.name,l.timezone,l.sort_order,l.active
    from public.matrix_locations_v2 l where l.matrix_version_id=v_active.id;

  insert into public.matrix_duties_v2(
    id,matrix_version_id,logical_id,code,name,description,color,sort_order,active
  ) select gen_random_uuid(),v_draft_id,d.logical_id,d.code,d.name,d.description,d.color,d.sort_order,d.active
    from public.matrix_duties_v2 d where d.matrix_version_id=v_active.id;

  insert into public.matrix_shift_templates_v2(
    id,matrix_version_id,logical_id,location_id,code,name,starts_at,ends_at,
    ends_next_day,day_mask,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,nl.id,s.code,s.name,s.starts_at,s.ends_at,
    s.ends_next_day,s.day_mask,s.sort_order,s.active
  from public.matrix_shift_templates_v2 s
  join public.matrix_locations_v2 ol on ol.id=s.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  where s.matrix_version_id=v_active.id;

  insert into public.matrix_role_duties_v2(
    id,matrix_version_id,role_id,duty_id,assignment_mode,minimum_count,active
  )
  select gen_random_uuid(),v_draft_id,nr.id,nd.id,rd.assignment_mode,
    rd.minimum_count,rd.active
  from public.matrix_role_duties_v2 rd
  join public.matrix_roles_v2 orole on orole.id=rd.role_id
  join public.matrix_duties_v2 od on od.id=rd.duty_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where rd.matrix_version_id=v_active.id;

  insert into public.matrix_scenarios_v2(
    id,matrix_version_id,logical_id,code,name,description,color,is_default,active,
    sort_order,valid_from,valid_to,settings_overrides
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,s.color,
    s.is_default,s.active,s.sort_order,s.valid_from,s.valid_to,s.settings_overrides
  from public.matrix_scenarios_v2 s where s.matrix_version_id=v_active.id;

  update public.matrix_scenarios_v2 child
  set parent_scenario_id=np.id
  from public.matrix_scenarios_v2 old_child
  join public.matrix_scenarios_v2 old_parent on old_parent.id=old_child.parent_scenario_id
  join public.matrix_scenarios_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=old_parent.logical_id
  where child.matrix_version_id=v_draft_id
    and child.logical_id=old_child.logical_id
    and old_child.matrix_version_id=v_active.id;

  insert into public.matrix_staffing_rules_v2(
    id,matrix_version_id,scenario_id,shift_template_id,role_id,duty_id,
    operation,count_value,multiplier_basis_points,active,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nsh.id,nr.id,nd.id,sr.operation,
    sr.count_value,sr.multiplier_basis_points,sr.active,sr.source_metadata
  from public.matrix_staffing_rules_v2 sr
  join public.matrix_scenarios_v2 osc on osc.id=sr.scenario_id
  join public.matrix_shift_templates_v2 osh on osh.id=sr.shift_template_id
  join public.matrix_roles_v2 orole on orole.id=sr.role_id
  left join public.matrix_duties_v2 od on od.id=sr.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=osh.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where sr.matrix_version_id=v_active.id;

  insert into public.matrix_strategies_v2(
    id,matrix_version_id,logical_id,code,name,description,solver_code,solver_options,
    legacy_weights,sort_order,active
  )
  select gen_random_uuid(),v_draft_id,s.logical_id,s.code,s.name,s.description,
    s.solver_code,s.solver_options-array[
      'legacyPopulationSize','legacyGenerations','legacyMutationRate'
    ],s.legacy_weights,s.sort_order,s.active
  from public.matrix_strategies_v2 s where s.matrix_version_id=v_active.id;

  insert into public.matrix_strategy_objectives_v2(
    id,matrix_version_id,strategy_id,tier,sort_order,metric_code,direction,
    weight,tolerance,parameters,active
  )
  select gen_random_uuid(),v_draft_id,ns.id,o.tier,o.sort_order,o.metric_code,
    o.direction,o.weight,o.tolerance,o.parameters,o.active
  from public.matrix_strategy_objectives_v2 o
  join public.matrix_strategies_v2 os on os.id=o.strategy_id
  join public.matrix_strategies_v2 ns
    on ns.matrix_version_id=v_draft_id and ns.logical_id=os.logical_id
  where o.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_strategies_v2(
    id,matrix_version_id,scenario_id,strategy_id,sort_order,active,
    objective_overrides,solver_overrides
  )
  select gen_random_uuid(),v_draft_id,nsc.id,nst.id,ss.sort_order,ss.active,
    ss.objective_overrides,ss.solver_overrides
  from public.matrix_scenario_strategies_v2 ss
  join public.matrix_scenarios_v2 osc on osc.id=ss.scenario_id
  join public.matrix_strategies_v2 ost on ost.id=ss.strategy_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_strategies_v2 nst
    on nst.matrix_version_id=v_draft_id and nst.logical_id=ost.logical_id
  where ss.matrix_version_id=v_active.id;

  insert into public.matrix_employee_roles_v2(
    id,matrix_version_id,employee_id,role_id,is_primary,can_lead,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,er.employee_id,nr.id,er.is_primary,er.can_lead,
    er.active,er.valid_from,er.valid_to
  from public.matrix_employee_roles_v2 er
  join public.matrix_roles_v2 old_role on old_role.id=er.role_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where er.matrix_version_id=v_active.id;

  insert into public.matrix_employee_locations_v2(
    id,matrix_version_id,employee_id,location_id,standard_allowed,overtime_allowed,
    home_location,active,valid_from,valid_to
  )
  select gen_random_uuid(),v_draft_id,el.employee_id,nl.id,el.standard_allowed,
    el.overtime_allowed,el.home_location,el.active,el.valid_from,el.valid_to
  from public.matrix_employee_locations_v2 el
  join public.matrix_locations_v2 old_location on old_location.id=el.location_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where el.matrix_version_id=v_active.id;

  insert into public.matrix_employee_duties_v2(
    id,matrix_version_id,employee_id,duty_id,role_id,location_id,active,
    valid_from,valid_to,source
  )
  select gen_random_uuid(),v_draft_id,ed.employee_id,nd.id,nr.id,nl.id,ed.active,
    ed.valid_from,ed.valid_to,ed.source
  from public.matrix_employee_duties_v2 ed
  join public.matrix_duties_v2 old_duty on old_duty.id=ed.duty_id
  left join public.matrix_roles_v2 old_role on old_role.id=ed.role_id
  left join public.matrix_locations_v2 old_location on old_location.id=ed.location_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where ed.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rules_v2(
    id,matrix_version_id,logical_id,code,name,description,calculation_method,
    amount_minor,rate_minor_per_hour,percent_basis_points,multiplier_basis_points,
    threshold_minutes,currency,priority,stacking_group,stacking_mode,day_mask,
    local_start,local_end,ends_next_day,valid_from,valid_to,condition_expression,
    formula_expression,active
  )
  select gen_random_uuid(),v_draft_id,p.logical_id,p.code,p.name,p.description,
    p.calculation_method,p.amount_minor,p.rate_minor_per_hour,p.percent_basis_points,
    p.multiplier_basis_points,p.threshold_minutes,p.currency,p.priority,p.stacking_group,
    p.stacking_mode,p.day_mask,p.local_start,p.local_end,p.ends_next_day,p.valid_from,
    p.valid_to,p.condition_expression,p.formula_expression,p.active
  from public.matrix_pay_rules_v2 p where p.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_roles_v2(matrix_version_id,pay_rule_id,role_id)
  select v_draft_id,np.id,nr.id
  from public.matrix_pay_rule_roles_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_roles_v2 old_role on old_role.id=x.role_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=old_role.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_duties_v2(matrix_version_id,pay_rule_id,duty_id,match_mode)
  select v_draft_id,np.id,nd.id,x.match_mode
  from public.matrix_pay_rule_duties_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_duties_v2 old_duty on old_duty.id=x.duty_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=old_duty.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_locations_v2(matrix_version_id,pay_rule_id,location_id)
  select v_draft_id,np.id,nl.id
  from public.matrix_pay_rule_locations_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_locations_v2 old_location on old_location.id=x.location_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=old_location.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_pay_rule_shifts_v2(matrix_version_id,pay_rule_id,shift_template_id)
  select v_draft_id,np.id,nsh.id
  from public.matrix_pay_rule_shifts_v2 x
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_shift_templates_v2 old_shift on old_shift.id=x.shift_template_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  join public.matrix_shift_templates_v2 nsh
    on nsh.matrix_version_id=v_draft_id and nsh.logical_id=old_shift.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_pay_rule_overrides_v2(
    id,matrix_version_id,scenario_id,pay_rule_id,enabled,amount_minor,
    rate_minor_per_hour,percent_basis_points,multiplier_basis_points,formula_expression
  )
  select gen_random_uuid(),v_draft_id,nsc.id,np.id,x.enabled,x.amount_minor,
    x.rate_minor_per_hour,x.percent_basis_points,x.multiplier_basis_points,x.formula_expression
  from public.matrix_scenario_pay_rule_overrides_v2 x
  join public.matrix_scenarios_v2 osc on osc.id=x.scenario_id
  join public.matrix_pay_rules_v2 op on op.id=x.pay_rule_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  join public.matrix_pay_rules_v2 np
    on np.matrix_version_id=v_draft_id and np.logical_id=op.logical_id
  where x.matrix_version_id=v_active.id;

  insert into public.matrix_scenario_budgets_v2(
    id,matrix_version_id,scenario_id,budget_month,location_id,role_id,duty_id,
    operation,amount_minor,multiplier_basis_points,currency,hard_limit,
    warning_percent,source_metadata
  )
  select gen_random_uuid(),v_draft_id,nsc.id,b.budget_month,nl.id,nr.id,nd.id,
    b.operation,b.amount_minor,b.multiplier_basis_points,b.currency,b.hard_limit,
    b.warning_percent,b.source_metadata
  from public.matrix_scenario_budgets_v2 b
  join public.matrix_scenarios_v2 osc on osc.id=b.scenario_id
  left join public.matrix_locations_v2 ol on ol.id=b.location_id
  left join public.matrix_roles_v2 orole on orole.id=b.role_id
  left join public.matrix_duties_v2 od on od.id=b.duty_id
  join public.matrix_scenarios_v2 nsc
    on nsc.matrix_version_id=v_draft_id and nsc.logical_id=osc.logical_id
  left join public.matrix_locations_v2 nl
    on nl.matrix_version_id=v_draft_id and nl.logical_id=ol.logical_id
  left join public.matrix_roles_v2 nr
    on nr.matrix_version_id=v_draft_id and nr.logical_id=orole.logical_id
  left join public.matrix_duties_v2 nd
    on nd.matrix_version_id=v_draft_id and nd.logical_id=od.logical_id
  where b.matrix_version_id=v_active.id;

  return v_draft_id;
end;
$$;

revoke all on function public.matrix_v2_create_draft(text)
  from public,anon,authenticated;
grant execute on function public.matrix_v2_create_draft(text)
  to authenticated;
