-- GRAFIK PRO 3.0 — kompletna, sztuczna baza demonstracyjna.
-- Każdy pracownik ma unikatowy numer oraz unikatowe imię i nazwisko.

insert into public.locations (code, name) values
  ('KRUCZA', 'Krucza'),
  ('PAWILONY', 'Pawilony');

insert into public.roles (code, name) values
  ('KELNER', 'Kelner'),
  ('BARMAN', 'Barman'),
  ('PIZZABAR', 'Pizzabar'),
  ('PREP', 'Prep'),
  ('POMOC', 'Pomoc');

with source as (
  select
    n,
    (array['Alicja','Marek','Karolina','Zofia','Michał','Łukasz','Aleksandra','Tomasz',
      'Kinga','Antoni','Patrycja','Jakub','Natalia','Mateusz','Julia','Filip','Oliwia',
      'Kamil','Wiktoria','Piotr'])[1 + ((n - 1) % 20)] as first_name,
    (array['Nowak','Kozłowski','Pawlak','Sikora','Wrona','Król','Piotrowska','Nowicki',
      'Kaczmarek','Borkowski','Sobczak','Maj','Lis','Czarnecki','Sokołowska','Witkowski',
      'Dąbrowska','Zalewski','Michalska','Ostrowski','Górska','Jankowski','Mazur','Wójcik',
      'Kubiak','Grabowski','Rutkowski','Krawczyk','Zając','Chmielewski','Sawicka','Baran',
      'Tomaszewski','Pietrzak','Marciniak','Jaworski','Kołodziej','Adamczyk','Dudek',
      'Walczak','Błaszczyk','Głowacki','Kurek','Szczepański','Kaźmierczak','Mazurek',
      'Bednarek','Cieślak','Urban','Mikołajczyk','Olejniczak','Rogowski','Stefański',
      'Musiał','Polak','Wasilewski','Kania','Tomczak','Kowalik','Włodarczyk','Sadowski',
      'Mucha','Przybylski','Kowal','Kruk','Nawrocki','Wilk','Kopeć','Bielecki','Rybak',
      'Stępień','Bąk','Makowski','Andrzejewski','Kędzierski','Leśniak'])[n] as last_name,
    case
      when n <= 30 then 'KELNER'::public.employee_role
      when n <= 54 then 'BARMAN'::public.employee_role
      when n <= 64 then 'PIZZABAR'::public.employee_role
      when n <= 70 then 'PREP'::public.employee_role
      else 'POMOC'::public.employee_role
    end as role
  from generate_series(1, 76) n
)
insert into public.employees (
  employee_no, first_name, last_name, email, primary_role,
  monthly_nominal_minutes, max_weekly_minutes, employment_start
)
select
  'GP-' || lpad(n::text, 3, '0'),
  first_name,
  last_name,
  'demo.' || lpad(n::text, 3, '0') || '@grafikpro.test',
  role,
  case when n % 5 = 0 then 5040 else 10080 end,
  case when n % 5 = 0 then 1440 else 2400 end,
  date '2025-01-01'
from source;

-- Lokalizacje: kelnerzy i prep wyłącznie Krucza; pozostali zgodnie z pulą stałą/rotacyjną.
insert into public.employee_locations (employee_id, location_id, standard_allowed, overtime_allowed, home_location)
select e.id, l.id,
  case
    when e.primary_role in ('KELNER','PREP') then l.code = 'KRUCZA'
    when right(e.employee_no, 1)::int % 3 = 0 then true
    when right(e.employee_no, 1)::int % 2 = 0 then l.code = 'KRUCZA'
    else l.code = 'PAWILONY'
  end,
  case
    when e.primary_role in ('KELNER','PREP') then l.code = 'KRUCZA'
    else true
  end,
  case
    when e.primary_role in ('KELNER','PREP') then l.code = 'KRUCZA'
    when right(e.employee_no, 1)::int % 2 = 0 then l.code = 'KRUCZA'
    else l.code = 'PAWILONY'
  end
from public.employees e cross join public.locations l
where e.primary_role not in ('KELNER','PREP') or l.code = 'KRUCZA';

-- HOST jest funkcją dodatkową kelnera, a nie osobną rolą podstawową.
insert into public.employee_capabilities (employee_id, capability, scope_role, scope_location)
select id, 'HOST', 'KELNER', 'KRUCZA'
from public.employees where primary_role = 'KELNER' order by employee_no limit 9;

-- Zamykanie zmiany dotyczy wyłącznie kelnerów i barmanów.
insert into public.employee_capabilities (employee_id, capability, scope_role, scope_location)
select id, 'CLOSE_SHIFT', primary_role,
  case when primary_role = 'BARMAN' and employee_no in ('GP-031','GP-032') then
    case when employee_no = 'GP-031' then 'KRUCZA'::public.location_code else 'PAWILONY'::public.location_code end
  else null end
from public.employees
where employee_no in ('GP-001','GP-002','GP-003','GP-031','GP-032','GP-033','GP-034','GP-035','GP-036');

-- Jeden menadżer na rolę; barmani mają dwóch menadżerów, po jednym prowadzącym lokal.
insert into public.employee_capabilities (employee_id, capability, scope_role, scope_location)
select id, 'ROLE_MANAGER', primary_role,
  case
    when employee_no = 'GP-031' then 'KRUCZA'::public.location_code
    when employee_no = 'GP-032' then 'PAWILONY'::public.location_code
    else null
  end
from public.employees
where employee_no in ('GP-001','GP-031','GP-032','GP-055','GP-065','GP-071');

insert into public.employee_capabilities (employee_id, capability, scope_role, scope_location)
select id, 'ROTATIONAL', 'BARMAN', null
from public.employees where primary_role = 'BARMAN' and employee_no between 'GP-040' and 'GP-047';

-- Definicje zmian z realnymi godzinami. DOW: 0=niedziela, 6=sobota.
insert into public.shift_definitions (location_id, code, name, day_of_week, start_time, end_time, ends_next_day)
select l.id, v.code, v.name, v.dow, v.starts, v.ends, v.next_day
from public.locations l
join (values
  ('KRUCZA', 'RANO', 'Zmiana poranna', 0, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 1, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 2, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 3, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 4, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 5, time '10:00', time '17:00', false),
  ('KRUCZA', 'RANO', 'Zmiana poranna', 6, time '10:00', time '17:00', false),
  ('KRUCZA', 'SRODEK', 'Zmiana środkowa', 0, time '15:00', time '23:00', false),
  ('KRUCZA', 'SRODEK', 'Zmiana środkowa', 5, time '15:00', time '23:00', false),
  ('KRUCZA', 'SRODEK', 'Zmiana środkowa', 6, time '15:00', time '23:00', false),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 0, time '17:00', time '03:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 1, time '17:00', time '01:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 2, time '17:00', time '01:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 3, time '17:00', time '01:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 4, time '17:00', time '01:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 5, time '17:00', time '03:00', true),
  ('KRUCZA', 'WIECZOR', 'Zmiana wieczorna', 6, time '17:00', time '03:00', true),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 0, time '10:00', time '17:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 1, time '10:00', time '17:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 2, time '10:00', time '17:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 3, time '10:00', time '17:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 4, time '10:00', time '17:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 5, time '12:00', time '19:00', false),
  ('PAWILONY', 'RANO', 'Zmiana poranna', 6, time '12:00', time '19:00', false),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 0, time '17:00', time '01:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 1, time '17:00', time '01:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 2, time '17:00', time '01:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 3, time '17:00', time '01:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 4, time '17:00', time '01:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 5, time '19:00', time '05:00', true),
  ('PAWILONY', 'WIECZOR', 'Zmiana wieczorna', 6, time '19:00', time '05:00', true)
) as v(location_code, code, name, dow, starts, ends, next_day)
  on l.code::text = v.location_code;

-- Bazowa macierz obsady wynikająca z uzgodnionych realnych warunków.
insert into public.demand_rules (location_id, shift_definition_id, role, required_count, required_capability)
select sd.location_id, sd.id, d.role::public.employee_role, d.required_count, d.capability
from public.shift_definitions sd
join public.locations l on l.id = sd.location_id
join lateral (
  select *
  from (values
    ('KELNER', case when sd.code='RANO' then case when sd.day_of_week in (0,5,6) then 6 else 4 end when sd.code='SRODEK' then 2 else 8 end, null::text),
    ('BARMAN', case when sd.code='RANO' then case when sd.day_of_week in (0,5,6) then 3 else 2 end when sd.code='SRODEK' then 1 else case when sd.day_of_week in (0,5,6) then 5 else 3 end end, null::text),
    ('PIZZABAR', case when sd.code='RANO' then case when sd.day_of_week in (0,5,6) then 3 else 2 end when sd.code='SRODEK' then 0 else case when sd.day_of_week in (0,5,6) then 5 else 4 end end, null::text),
    ('PREP', case when sd.code='RANO' then 5 else 0 end, null::text),
    ('POMOC', case when sd.code='RANO' then 1 when sd.code='SRODEK' then 0 else case when sd.day_of_week in (0,5,6) then 2 else 1 end end, null::text)
  ) x(role, required_count, capability)
) d on true
where l.code = 'KRUCZA' and d.required_count > 0;

insert into public.demand_rules (location_id, shift_definition_id, role, required_count)
select sd.location_id, sd.id, d.role::public.employee_role, d.required_count
from public.shift_definitions sd
join public.locations l on l.id = sd.location_id
cross join lateral (values ('BARMAN', case when sd.code='RANO' then 1 else 2 end), ('PIZZABAR', case when sd.code='RANO' then 1 else 2 end)) d(role, required_count)
where l.code = 'PAWILONY';

-- Twarde wymagania funkcjonalne: HOST oraz osoba zamykająca zmianę.
insert into public.demand_rules (location_id, shift_definition_id, role, required_count, required_capability)
select sd.location_id, sd.id, 'KELNER', 1, 'HOST'
from public.shift_definitions sd join public.locations l on l.id=sd.location_id
where l.code='KRUCZA' and sd.code in ('RANO','WIECZOR');

insert into public.demand_rules (location_id, shift_definition_id, role, required_count, required_capability)
select sd.location_id, sd.id, r.role, 1, 'CLOSE_SHIFT'
from public.shift_definitions sd
join public.locations l on l.id=sd.location_id
cross join lateral (
  select unnest(case when l.code='KRUCZA' then array['KELNER','BARMAN']::public.employee_role[] else array['BARMAN']::public.employee_role[] ) role
) r
where sd.code='WIECZOR';

insert into public.operational_events (
  location_id, event_type, title, description, starts_at, ends_at,
  expected_guests, status, verification_due_at
)
select id, 'EVENT', 'Wesele — Sala Kryształowa',
  'Event demonstracyjny wymagający potwierdzenia i zwiększenia obsady.',
  timestamptz '2026-07-11 18:00:00+02', timestamptz '2026-07-12 02:00:00+02',
  120, 'NEEDS_VERIFICATION', timestamptz '2026-07-05 12:00:00+02'
from public.locations where code='KRUCZA';

insert into public.event_demand_changes (event_id, role, shift_code, additional_count)
select e.id, x.role::public.employee_role, 'WIECZOR', x.additional_count
from public.operational_events e
cross join (values ('KELNER',2),('BARMAN',1),('POMOC',1)) x(role, additional_count)
where e.title='Wesele — Sala Kryształowa';
