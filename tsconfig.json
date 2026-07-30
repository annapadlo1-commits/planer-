-- Uruchom WYŁĄCZNIE po przerwanym wykonaniu 0002_demo_seed.sql.
-- Czyści dane demonstracyjne, ale zachowuje strukturę, typy, RLS i polityki z 0001.

truncate table
  public.audit_log,
  public.attendance_events,
  public.notifications,
  public.tasks,
  public.assignments,
  public.shifts,
  public.plans,
  public.event_demand_changes,
  public.operational_events,
  public.demand_rules,
  public.shift_definitions,
  public.user_permissions,
  public.employee_capabilities,
  public.employee_locations,
  public.employees,
  public.roles,
  public.locations
restart identity cascade;
