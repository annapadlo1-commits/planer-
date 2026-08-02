-- Synchronize branches created before pay-window proration was added to the
-- final solver API migration. The helper computes exact overlap minutes in the
-- versioned Matrix timezone and remains private to the solver boundary.

create or replace function solver_private.pay_rule_billable_minutes_v2(
  p_snapshot jsonb,p_rule jsonb,p_slot jsonb
)
returns bigint
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_condition jsonb;
  v_window jsonb;
  v_window_count integer:=0;
  v_start time;
  v_end time;
  v_timezone text:=solver_private.slot_timezone_v2(p_snapshot,p_slot);
  v_slot_start timestamptz:=(p_slot->>'start')::timestamptz;
  v_slot_end timestamptz:=(p_slot->>'end')::timestamptz;
  v_minutes bigint;
begin
  for v_condition in
    select value
    from jsonb_array_elements(coalesce(p_rule->'conditions','[]'::jsonb))
  loop
    if lower(coalesce(v_condition->>'field',''))='local_time'
      and upper(coalesce(v_condition->>'operator',''))='OVERLAPS_TIME' then
      v_window_count:=v_window_count+1;
      v_window:=v_condition->'value';
    end if;
  end loop;
  if nullif(p_rule->>'localStart','') is not null then
    v_window_count:=v_window_count+1;
    v_window:=jsonb_build_object(
      'start',p_rule->>'localStart','end',p_rule->>'localEnd'
    );
  end if;
  if v_window_count=0 then return (p_slot->>'durationMinutes')::bigint; end if;
  if v_window_count<>1 or jsonb_typeof(v_window)<>'object'
    or nullif(v_window->>'start','') is null
    or nullif(v_window->>'end','') is null then
    raise exception 'PAY_RULE_TIME_WINDOW_AMBIGUOUS';
  end if;
  v_start:=(v_window->>'start')::time;
  v_end:=(v_window->>'end')::time;

  select coalesce(sum(floor(extract(epoch from
    least(v_slot_end,window_end)-greatest(v_slot_start,window_start)
  )/60)) filter(where window_end>v_slot_start and window_start<v_slot_end),0)::bigint
  into v_minutes
  from generate_series(
    (v_slot_start at time zone v_timezone)::date-1,
    (v_slot_end at time zone v_timezone)::date+1,
    interval '1 day'
  ) day_anchor
  cross join lateral (
    select
      ((day_anchor::date+v_start) at time zone v_timezone) window_start,
      ((day_anchor::date+case when v_end<=v_start then 1 else 0 end+v_end)
        at time zone v_timezone) window_end
  ) window_bounds;
  return greatest(v_minutes,0);
end;
$$;

revoke all on function solver_private.pay_rule_billable_minutes_v2(jsonb,jsonb,jsonb)
  from public,anon,authenticated;
grant execute on function solver_private.pay_rule_billable_minutes_v2(jsonb,jsonb,jsonb)
  to service_role;
