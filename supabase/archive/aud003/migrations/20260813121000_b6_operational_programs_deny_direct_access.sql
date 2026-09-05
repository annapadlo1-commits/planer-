-- B6 operational programs are exposed only through scope-aware SECURITY DEFINER RPCs.
-- Explicit deny-all policies make the intended access model visible to security tooling.

create policy "operational events use rpc only"
  on public.operational_program_events_v1
  for all to authenticated
  using (false) with check (false);

create policy "operational audiences use rpc only"
  on public.operational_program_audience_rules_v1
  for all to authenticated
  using (false) with check (false);

create policy "operational participants use rpc only"
  on public.operational_program_participants_v1
  for all to authenticated
  using (false) with check (false);

create policy "operational checklists use rpc only"
  on public.operational_program_checklist_items_v1
  for all to authenticated
  using (false) with check (false);

create policy "operational inventory links use rpc only"
  on public.operational_program_inventory_links_v1
  for all to authenticated
  using (false) with check (false);

create policy "operational audit uses rpc only"
  on public.operational_program_audit_v1
  for all to authenticated
  using (false) with check (false);

create policy "business integrations use rpc only"
  on public.business_app_integrations_v1
  for all to authenticated
  using (false) with check (false);
