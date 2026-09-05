# AUD-2026-09-01-014 — klasyfikacja 176 brakujących indeksów FK

## Granica i źródła

- Projekt: `nhthrtpkfpmufmrmdyjg` (`dynamic-matrix-solver-v2`, `PREVIEW`).
- Świeży odczyt panelu Performance Advisor: 2026-09-05 10:05 CEST.
- URL odczytu: `https://supabase.com/dashboard/project/nhthrtpkfpmufmrmdyjg/advisors/performance`.
- Filtr: `Unindexed foreign keys`; `aria-rowcount=177`, czyli 176 wyników oraz nagłówek.
- Katalog bazowy: `supabase/baseline/aud003/uat-catalog-2026-09-03.json` (`capturedAtUtc=2026-09-03T18:57:09.596292`, `transactionReadOnly=on`, 331 FK, 340 indeksów; wszystkie indeksy użyte do porównania miały `ready=true` i `valid=true`).
- Warstwa indeksów po katalogu: `20260905110000_aud014_priority_foreign_key_indexes.sql` (5 indeksów) oraz `20260905130000_aud014_evidence_backed_fk_indexes.sql` (3 indeksy). Osiem indeksów pokrywa dziewięć constraintów, redukując wynik z 185 do 176; liczba jest zgodna ze świeżym panelem UAT.

## Metoda

1. Dla każdego FK wyodrębniono uporządkowaną listę kolumn.
2. Za pokrycie uznano wyłącznie poprawny i gotowy indeks B-tree, którego lewy prefiks jest równy pełnej liście kolumn FK.
3. Dodano osiem dokładnych definicji indeksów z dwóch migracji AUD-014.
4. Z pozostałych 176 constraintów pięć oznaczono `R`, ponieważ ich pojedyncza kolumna jest lewym prefiksem dłuższego FK tej samej tabeli; osobny indeks byłby redundantny wobec indeksu dla dłuższego FK.
5. Pozostałe 171 oznaczono `N`: nie ma obecnie constraint-specific dowodu z EXPLAIN, selektywności ani workloadu UAT, który uzasadniałby DDL. `N` nie znaczy „nigdy nie indeksować”; znaczy „nie tworzyć indeksu bez pomiaru”.

## Słownik klas

- `R` — `REDUNDANTNY_WZGLEDEM_DLUZSZEGO_FK`.
- `N` — `NIEUZASADNIONY_DO_DDL_NA_OBECNYM_DOWODZIE`.
- Wśród bieżących 176: `wymagany=0`, `już_pokryty=0`, `redundantny=5`, `nieuzasadniony=171`.
- Dziewięć constraintów już pokrytych przez osiem indeksów AUD-014 nie znajduje się w CSV, ponieważ nie występuje w bieżących 176 ostrzeżeniach.

## Pięć relacji redundantnych

- `matrix_scenario_pay_rule_overrides_v2_matrix_version_id_fkey` → lewy prefiks dłuższych FK tej tabeli.
- `matrix_scenario_strategies_v2_matrix_version_id_fkey` → lewy prefiks dłuższych FK tej tabeli.
- `workforce_calendar_events_v2_matrix_version_id_fkey` → lewy prefiks `workforce_calendar_events_v2_matrix_version_id_location_id_fkey`.
- `workforce_event_demand_v2_matrix_version_id_fkey` → lewy prefiks dłuższych FK tej tabeli.
- `workforce_hot_day_limits_v2_matrix_version_id_fkey` → lewy prefiks `workforce_hot_day_limits_v2_matrix_version_id_role_id_fkey`.

## Ograniczenie dowodu

Nie uruchomiono SQL ani EXPLAIN na żywym UAT. Dostępny konektor Supabase zwracał wyłącznie projekt produkcyjny `bdybebzvzapihjdauehg`, więc zgodnie z zasadą fail-closed nie użyto go. Dalsze awansowanie klasy `N` do `wymagany` wymaga dokładnego, read-only pomiaru na UAT: rozmiaru i selektywności tabeli, `pg_stat_statements`/rzeczywistego workloadu oraz `EXPLAIN (ANALYZE, BUFFERS)` bez mutacji danych.
