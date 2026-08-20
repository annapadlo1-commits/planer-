# Pełny batch zaległości do UAT — 2026-08-20

## Cel i granica odbioru

Batch obejmuje drogę właściciela od pustej firmy UAT, przez konfigurację, pracowników, stawki, role, dokładną obsadę zmian i publikację konfiguracji, do wygenerowania trzech wariantów oraz ręcznej pracy w Studiu Lidera. Produkcja i `main` nie są objęte.

Żadna pozycja nie otrzymuje końcowego `PASS` ani `CLOSED` bez testu właścicielki produktu. Zielone testy techniczne i zalogowane Chrome E2E oznaczają wyłącznie gotowość do jej UAT.

## Wynik audytu całego rejestru

- Rejestr zawiera 245 fizycznych pozycji, lecz przed naprawą integralności tylko 243 unikalne ID. `B4F-109` i `B4F-110` występują podwójnie, a historyczne `B4F-40` i `B4F-41` zostały nadpisane. Batch przywraca dwa historyczne rekordy, zachowuje nowsze ID i dopisuje osobne znalezisko integralności rejestru.
- Wiele pozycji ma już dowód wdrożenia technicznego i oczekuje wyłącznie właścicielskiego UAT albo wskazanego retestu. Stara liczba `126` pochodziła z niepełnej klasyfikacji, która nie uwzględniała wszystkich dowodów zapisanych bezpośrednio w bieżących rekordach; batch przelicza ten zbiór po pełnym podziale A/B/C/D zamiast utrwalać błędną liczbę.
- Faktyczne blokery kodowe drogi do generatora: `F4`, `MX-K10`, `MX-K12`, granica DRAFT/ACTIVE w onboardingu oraz `B4F-108`–`B4F-110`.
- `M5` i pierwotne `MX-K11` są wdrożone lub zastąpione nowszym kontraktem. `P3` działa funkcjonalnie, ale wymaga twardego testu round-trip i ochrony integralności okresów, realizowanej wspólnie z `F4`.
- `UI-G01`, `UI-G02` i `UI2` są zasadami globalnymi. W tym batchu usuwane są potwierdzone naruszenia na ścieżce do generatora; pełny właścicielski przegląd wszystkich powierzchni pozostaje aktywny.

## Batch A — implementacja i retest w tym wydaniu

| Zakres / ID | Naprawa | Dowód wymagany przed przekazaniem |
|---|---|---|
| `B4F-109`, `B4F-80`, `B4F-71` | Osobna, wcześniejsza ochrona przed możliwymi do uniknięcia `0 h` dla każdej strategii. Dodatni wynik wolno zaakceptować wyłącznie po formalnym dowodzie, że twarde ograniczenia czynią go nieuniknionym. | Testy solvera dla wszystkich strategii i kategorii; świeży run SALA; rozkład godzin całego rosteru. |
| `B4F-111`, `B4F-72`, `B4F-77` | Wszystkie aktywne role pracownika są kwalifikacjami. Rola dodatkowa nie usuwa podstawowej; Tejlor pozostaje Kelnerem. Studio pobiera pełny roster kategorii, również osoby z `0 h`. | SQL UAT dla GP-067; Tejlor widoczna i przypisywalna jako Kelner; brak regresji roli Host jako dodatkowej awaryjnej. |
| `B4F-112`, `B4F-102`, `B4F-108`, `B4F-110` | Desktop: stała pula osób i natychmiastowy drag-and-drop na dokładny wakat albo przydział. Mobile: dwa tapnięcia w dowolnej kolejności. Brak zwykłego przycisku zapisu; wyjątki pozostają osobno audytowane. Historyczne kryterium osobnego przycisku zapisu w `B4F-110` jest zastąpione tą zaakceptowaną decyzją właścicielki, bez przepisywania historii starego ID. | DnD oraz obie kolejności mobile; jedna mutacja na gest; blokada double tap/re-entry; no-op bez nowej rewizji; zachowanie filtrów i scrolla. |
| `B4F-95`, `B4F-101` | `Sprawdź cały grafik` łączy naruszenia twarde z wakatami, `0 h`, brakami do celu, nadgodzinami i preferencjami dla dokładnej rewizji. Każda kolejna edycja unieważnia raport. | Test konfliktu rewizji; raport po serii edycji; blokada workflow w trakcie mutacji. |
| `B4F-113` / onboarding / publikacja | Gotowy DRAFT prowadzi do publikacji konfiguracji. Generator odblokowuje dopiero ponownie odczytana wersja ACTIVE i nie używa po cichu starej wersji. | Pusty start właściciela UAT → dane → kontrola → publikacja → generator. |
| `F4`, `GLOB-01`, `P3` | Jeden dwukierunkowy invariant bazy: stawka nie wychodzi poza zatrudnienie, a skrócenie zatrudnienia nie może pozostawić stawek poza zakresem. Zamknięcie starego RPC omijającego kontrolę. | Direct SQL/RPC, formularz profilu, ręczna stawka, import finansów i pełny import; round-trip zapis → publikacja → snapshot. |
| `MX-K10`, `MX-K12`, `M2`, `UI-G02` | Zapotrzebowanie istnieje wyłącznie dla konkretnej zmiany (`shift_template_id`). Usunięcie runtime i importu szerokich okresów RANO/ŚRODEK/WIECZÓR oraz cichego minimum z relacji rola–obowiązek. | Zmiana → rola → opcjonalny obowiązek → liczba; dwie zmiany o tej samej porze, wymaganie tylko na jednej; import fail-closed dla starego pola. |
| `UI-G01` | Zapis istniejącego profilu, formularza konfiguracji i preferencji pozostaje w otwartym kontekście; nowy rekord może zamknąć kreator po utworzeniu. | Zachowanie draweru, aktywnej karty, filtrów, pozycji scrolla i fokusu. |
| `UI-G02`, `UI2` | Na objętej ścieżce usunięcie surowych statusów i technicznych fallbacków; konkretne zmiany są prezentowane biznesową nazwą i godzinami. | Audyt tekstów oraz brak surowych kodów w E2E objętego przepływu. |

## Batch B — wdrożone technicznie, tylko retest właścicielski

Do tej grupy należą rekordy oznaczone w Excelu jako wdrożone technicznie / gotowe do retestu po odjęciu pozycji z batchy A, C i D. Obejmują między innymi: import i eksport, wersjonowanie konfiguracji, role i obowiązki, dostępność w strefie firmy, portal pracownika, standby, publikację kategorii i firmy, koszty, uprawnienia, operacje, checkpointy Studia oraz serię `B4F-33`–`B4F-107` w zakresie opisanym indywidualnie w rejestrze. Liczba tej grupy jest wyliczana z pełnego bieżącego rekordu oraz najnowszej historii, a nie ze starej wartości `126`.

Nie wolno nadać im zbiorczego `PASS`. Każdy rekord zachowuje własne kryterium i dowód; pełna kolejność retestu znajduje się w runbooku E2E oraz w arkuszu `Rejestr`.

## Batch C — decyzja właścicielki albo zależność zewnętrzna

Poniższych pozycji nie wolno domyślać ani wdrażać jako „naprawy”:

- `B4F-33` — docelowy model współdzielenia jednej osoby/obowiązku między lokalami;
- `N4` — ostateczny model HOT DAY;
- `N7.5` — rozliczenie, kanał, czas odpowiedzi i zakres standby;
- `INT1` i pozostałe integracje zewnętrzne — wybór systemu, zakres danych i poświadczenia;
- `B4F-114` — self-service pierwszego właściciela/tenantu: UAT ma bezpieczny pusty start z istniejącego konta OWNER; publiczny bootstrap nowej firmy wymaga osobnego modelu bezpieczeństwa i lifecycle tenantu;
- OAuth, domeny, przeglądy prawne/kadrowo-płacowe i fizyczne testy urządzeń — zależności środowiskowe lub właścicielskie.

## Batch D — świadomie odłożone lub zastąpione

- `DEF-01`, `DEF-02`, `DEF-03` pozostają odłożone zgodnie z decyzją i nie blokują tego UAT.
- `M5` nie jest już brakującym drugim modułem edycji: `Kadra` jest katalogiem, a HR/Finanse prowadzą do jednego profilu w konfiguracji firmy.
- `MX-K11` nie używa już nazwy ani kodu zmiany do wyznaczania pory; residual kompatybilności kategorii wymaga osobnego testu, nie przywrócenia starej heurystyki.
- Historyczne wdrożenia nie są kasowane ani przepisywane. Nowszy rekord może jedynie udokumentować zastąpienie lub regresję.

## Bramka wydania do UAT

1. Testy ukierunkowane i regresje objętych modułów.
2. Pełny pakiet Node, pełny pytest solvera, TypeScript i build — uruchamiane kolejno.
3. Migracje wyłącznie na Supabase UAT `nhthrtpkfpmufmrmdyjg`, testy SQL/RPC/RLS i postflight.
4. Ten sam commit na Vercel oraz workerze/gatewayu Northflank.
5. Zalogowane Chrome E2E właściciela/managera i — gdzie dotyczy — pracownika, bez błędów konsoli.
6. Aktualizacja Excela: przywrócenie integralności, osobne nowe ID, commit, migracje, testy, wdrożenie, E2E i pozostałe ryzyko.
7. Status końcowy wydania: `READY FOR OWNER UAT`, nigdy automatyczny `PASS`.
