# AUD-2026-09-01-014 — klasyfikacja 176 brakujących indeksów FK

## Granica i źródła

- Projekt: `nhthrtpkfpmufmrmdyjg` (`dynamic-matrix-solver-v2`, `PREVIEW`).
- Świeży odczyt Performance Advisor przez konektor projektu: 2026-09-05 12:30 CEST (`observed_at=2026-09-05T10:30:22.562Z`).
- URL odczytu: `https://supabase.com/dashboard/project/nhthrtpkfpmufmrmdyjg/advisors/performance`.
- Filtr: `Unindexed foreign keys`; `aria-rowcount=177`, czyli 176 wyników oraz nagłówek.
- Katalog bazowy: `supabase/baseline/aud003/uat-catalog-2026-09-03.json` (`capturedAtUtc=2026-09-03T18:57:09.596292`, `transactionReadOnly=on`, 331 FK, 340 indeksów; wszystkie indeksy użyte do porównania miały `ready=true` i `valid=true`).
- Warstwa indeksów po katalogu: `20260905110000_aud014_priority_foreign_key_indexes.sql` (5 indeksów) oraz `20260905130000_aud014_evidence_backed_fk_indexes.sql` (3 indeksy). Osiem indeksów pokrywa dziewięć constraintów, redukując wynik z 185 do 176; liczba jest zgodna ze świeżym panelem UAT.

## Metoda

1. Dla każdego FK wyodrębniono uporządkowaną listę kolumn.
2. Za pokrycie uznano wyłącznie poprawny i gotowy indeks B-tree, którego lewy prefiks jest równy pełnej liście kolumn FK.
3. Dodano osiem dokładnych definicji indeksów z dwóch migracji AUD-014.
4. Pięć krótszych FK, które mogłyby w przyszłości współdzielić indeks z dłuższym FK, również oznaczono `N`: taki wspólny indeks obecnie nie istnieje, więc nie są jeszcze faktycznie pokryte ani redundantne.
5. Wszystkie pozostałe 176 oznaczono `N`: nie ma obecnie constraint-specific dowodu z EXPLAIN, selektywności ani workloadu UAT, który uzasadniałby DDL. `N` nie znaczy „nigdy nie indeksować”; znaczy „nie tworzyć indeksu bez pomiaru”.

## Słownik klas

- `N` — `NIEUZASADNIONY_DO_DDL_NA_OBECNYM_DOWODZIE`.
- Wśród bieżących 176: `wymagany=0`, `już_pokryty=0`, `redundantny=0`, `nieuzasadniony=176`.
- Dziewięć constraintów już pokrytych przez osiem indeksów AUD-014 nie znajduje się w CSV, ponieważ nie występuje w bieżących 176 ostrzeżeniach.

## Dziewięć usuniętych ostrzeżeń i dokładne indeksy

- `matrix_employee_profiles_v2_employee_id_fkey` → `matrix_employee_profiles_v2_employee_id_fk_idx`.
- `matrix_roles_v2_category_fk` → `matrix_roles_v2_category_fk_idx`.
- `matrix_staffing_rules_v2_matrix_version_id_duty_id_fkey` → `matrix_staffing_rules_v2_duty_fk_idx`.
- `matrix_staffing_rules_v2_matrix_version_id_role_id_fkey` → `matrix_staffing_rules_v2_role_fk_idx`.
- `matrix_strategy_objectives_v2_matrix_version_id_fkey` → `matrix_strategy_objectives_v2_strategy_fk_idx`.
- `matrix_strategy_objectives_v2_matrix_version_id_strategy_i_fkey` → `matrix_strategy_objectives_v2_strategy_fk_idx`.
- `application_access_directory_v1_auth_user_id_fkey` → `application_access_directory_v1_auth_user_id_fk_idx`.
- `audit_log_actor_id_fkey` → `audit_log_actor_id_fk_idx`.
- `employee_preferences_employee_id_fkey` → `employee_preferences_employee_id_fk_idx`.

Pierwsza warstwa pięciu indeksów zmniejszyła liczbę alertów `185 → 179`, a druga warstwa trzech indeksów `179 → 176`. Dlatego historyczna liczba 179 i świeża liczba 176 opisują dwa różne, zgodne momenty tego samego środowiska.

## Świeży pomiar katalogowy i statystyczny UAT

Odczyt 2026-09-05 12:31–12:34 CEST wykonano wyłącznie zapytaniami `SELECT` na dokładnym projekcie `nhthrtpkfpmufmrmdyjg`. Nie odczytywano wierszy biznesowych i nie wykonano DDL, `EXPLAIN ANALYZE` ani resetu statystyk.

- Niezależne wyliczenie z `pg_constraint` i poprawnych/gotowych `pg_index`, z wymaganiem pełnego lewego prefiksu kolumn FK, zwróciło dokładnie `176` niepokrytych constraintów — tyle samo co świeży Advisor.
- Ostrzeżenia dotyczą `77` relacji: `63` relacje mają szacunkowo `0` żywych wierszy, `14` ma od `1` do `99`, żadna nie ma `100` ani więcej. Największa relacja z ostrzeżeniem ma szacunkowo `98` wierszy i `393216` bajtów łącznie.
- Największe niepuste relacje z ostrzeżeniami to: `matrix_employee_roles_v2` (`98` wierszy, 2 ostrzeżenia), `matrix_employee_profiles_v2` (`86`, 3), `employees` (`86`, 1), `employee_hr_profiles` (`86`, 1) i `employee_pay_rates_v2` (`86`, 2).
- `pg_stat_statements` jest zainstalowane, ale same zbiorcze liczniki tabel nie dowodzą, że konkretny niepokryty FK uczestniczy w kosztownym `DELETE`/`UPDATE` rodzica albo selektywnym filtrze. Dlatego nie użyto ich do automatycznego awansowania żadnej pozycji do klasy `wymagany`.
- Całe UAT ma w `public` i `solver_private` 126 relacji ze statystykami, około `10904` żywych wierszy, `3287528` skanów sekwencyjnych, `7642427` skanów indeksowych i `73660` zapisów od ostatniego resetu statystyk. Te wartości są kontekstem środowiska, a nie per-FK benchmarkiem.

## Wniosek i ograniczenie dowodu

Świeży pomiar nie uzasadnia kolejnej migracji indeksów: wszystkie 176 pozycji pozostają `NIEUZASADNIONY_DO_DDL_NA_OBECNYM_DOWODZIE`. Utworzenie indeksu dla któregokolwiek `N` wymaga osobnego dowodu workloadu dla konkretnego constraintu: znormalizowanego zapytania, selektywności oraz porównania planu i czasu przed/po na reprezentatywnych danych. Bez takiego dowodu dodatkowy indeks zwiększa koszt zapisu, rozmiar i utrzymanie, ale nie ma potwierdzonej korzyści.
