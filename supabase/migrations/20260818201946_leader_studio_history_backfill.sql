-- Existing UAT working copies predate the history trigger. Their current state
-- becomes the explicit baseline; no generated or published plan is changed.
do $$
declare v_variant record;
begin
  for v_variant in
    select id,revision,last_edited_by from public.plan_variants_v2 variant
    where variant.variant_kind='LEADER_COPY'
      and variant.status in ('READY','SELECTED')
      and not exists(select 1 from solver_private.leader_variant_history_v2 history
        where history.variant_id=variant.id)
  loop
    perform solver_private.record_leader_variant_history_v2(
      v_variant.id,v_variant.revision,'Stan początkowy po aktualizacji Studia',v_variant.last_edited_by
    );
  end loop;
end;
$$;
