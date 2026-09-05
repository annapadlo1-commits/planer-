-- An inactive historical location grant may deliberately have every access
-- flag cleared.  The previous check ignored `active`, so a repeat Matrix
-- import failed while first deactivating old grants before upserting the
-- workbook's complete location set.

alter table public.matrix_employee_locations_v2
  drop constraint if exists matrix_employee_locations_v2_check;

alter table public.matrix_employee_locations_v2
  add constraint matrix_employee_locations_v2_check check (
    not active or standard_allowed or overtime_allowed or home_location
  );

comment on constraint matrix_employee_locations_v2_check
  on public.matrix_employee_locations_v2 is
  'Active grants require at least one capability; inactive versioned rows may retain no access.';
