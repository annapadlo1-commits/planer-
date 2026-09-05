# GRAFIK PRO 3.0 — Alpha 14 / Optimization Engine V2

> **Dokument historyczny — nie wykonywać jako bieżącej instrukcji wdrożenia.** Aktualne środowiska, migracje i bramki są zapisane w nadrzędnych `AGENTS.md`, `PROJECT_STATUS.md` oraz rejestrze Excel.

Paczka jest nakładką na aktualne repozytorium i nie spłaszcza struktury.

## Kolejność wdrożenia

1. Wgraj całą zawartość ZIP do katalogu głównego repozytorium.
2. W Supabase wykonaj migrację `supabase/migrations/0011_optimizer_v2_checkpointed.sql`.
3. Wdróż `supabase/functions/schedule-optimizer/index.ts` jako funkcję `schedule-optimizer` z takim samym ustawieniem JWT jak aktywna wersja.
4. Wdróż frontend z `app/page.tsx`.

Nie wdrażaj samej funkcji przed frontendem: protokół generatora jest etapowy (`START`, `STEP`, `FINALIZE`).

## Co zmienia silnik

- rozdziela hard constraints od soft constraints;
- traktuje niedostępność, urlop i L4 jako wymagania twarde;
- ocenia kandydatów leksykograficznie: naruszenia twarde, braki obsady, cele miękkie;
- tworzy checkpoint po każdym pokoleniu i wznawia obliczenia po utracie połączenia;
- korzysta z najlepszego istniejącego planu jako chronionego rodzica;
- tworzy populację, krzyżuje, mutuje i naprawia kandydatów;
- używa naprawy typu augmenting swap dla trudnych wakatów;
- waliduje twarde ograniczenia w silniku i ponownie w PostgreSQL przed zapisem;
- grupuje alerty według dnia, zmiany, roli i funkcji, zachowując liczbę brakujących osób;
- pokazuje rzeczywisty postęp optymalizacji w interfejsie.

## Warunek akceptacji

Wdrożenia nie należy uznać za gotowe na podstawie samego statusu `ACTIVE`/`Ready`. Test musi potwierdzić pełną ścieżkę `START → co najmniej 8 STEP → FINALIZE`, `hardViolations = 0`, zapis planu i brak regresji liczby nieobsadzonych stanowisk względem najlepszego historycznego rodzica po jego ponownej walidacji.
