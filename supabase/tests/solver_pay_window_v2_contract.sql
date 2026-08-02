-- Exact, DST-safe payroll-window contract. All values are immutable JSON and
-- the transaction performs no persistent writes.

begin;

do $$
declare
  v_snapshot jsonb:=jsonb_build_object(
    'settings',jsonb_build_object('timezone','Europe/Warsaw'),
    'locations',jsonb_build_array(jsonb_build_object(
      'id','location-test','timezone','Europe/Warsaw'
    ))
  );
  v_rule jsonb:=jsonb_build_object(
    'id','pay-window','localStart','22:00','localEnd','06:00',
    'conditions','[]'::jsonb
  );
  v_partial jsonb:=jsonb_build_object(
    'locationId','location-test','start','2026-08-01T16:00:00+02:00',
    'end','2026-08-01T23:00:00+02:00','durationMinutes',420
  );
  v_dst_rule jsonb:=jsonb_build_object(
    'id','pay-dst-window','localStart','01:00','localEnd','04:00',
    'conditions','[]'::jsonb
  );
  v_dst jsonb:=jsonb_build_object(
    'locationId','location-test','start','2026-10-24T22:00:00+02:00',
    'end','2026-10-25T06:00:00+01:00','durationMinutes',540
  );
begin
  if solver_private.pay_rule_billable_minutes_v2(
    v_snapshot,v_rule,v_partial
  )<>60 then raise exception 'PARTIAL_PAY_WINDOW_NOT_PRORATED'; end if;
  if solver_private.pay_rule_billable_minutes_v2(
    v_snapshot,v_dst_rule,v_dst
  )<>240 then raise exception 'DST_PAY_WINDOW_NOT_PRORATED'; end if;
  if has_function_privilege(
    'authenticated',
    'solver_private.pay_rule_billable_minutes_v2(jsonb,jsonb,jsonb)',
    'EXECUTE'
  ) then raise exception 'PAY_WINDOW_HELPER_EXPOSED'; end if;
end;
$$;

rollback;
