# Alpha 16 — zakres i kryteria odbioru

> **Historyczny zakres Alpha 16.** Zachowano go jako dowód wcześniejszych kryteriów. Aktualne decyzje i statusy należy sprawdzać w nadrzędnych `DECISIONS.md`, `PROJECT_STATUS.md` i rejestrze Excel.

## Pakiet P0

| # | Obszar | Zrealizowany kontrakt | Kryterium testu użytkowego |
|---:|---|---|---|
| 1 | Zapis Matrixa | Jeden wersjonowany zapis Matrix v2; błędy RPC są tłumaczone i nie znikają bez komunikatu. | Zmiana wersji roboczej pozostaje po odświeżeniu, a publikacja wskazuje brakujące dane. |
| 2 | Numer pracownika | Numer jest opcjonalny na wejściu; baza wybiera pierwszy wolny `GP-###` pod blokadą transakcyjną. | Dwóch nowych pracowników otrzymuje różne kolejne numery bez ręcznego wpisywania. |
| 3 | Wiele okien dostępności | Portal zapisuje dowolną liczbę dokładnych przedziałów `AVAILABLE_WINDOW` i `UNAVAILABLE`. | Dwa okna jednego dnia pozostają po odświeżeniu i można je osobno odwołać. |
| 4 | Wiele lokali | Wszystkie zaznaczone lokale są równorzędnymi lokalami zwykłej pracy; `homeLocation` nie wpływa na solver. | Pracownik może być zaplanowany w obu lokalach w ramach jednego nominału i limitu. |
| 5 | Preferencje zmianowe | Preferencje używają trzech pór: rano, środek, wieczór. | Lista nie zależy od dni tygodnia ani od sztywnej listy zmian. |
| 6 | Preferencje pracownika i firmy | Portal zapisuje preferencję pracownika, a jawna wartość pracodawcy z Matrixa ma pierwszeństwo. | Portal pokazuje wartość efektywną i informację o nadrzędnej decyzji firmy. |
| 7 | Import Excel | Szablon zawiera instrukcję, słowniki i cztery arkusze danych; podgląd waliduje wszystkie wiersze, zapis jest atomowy. | Błędny kod lub nieistniejący numer blokuje cały import; poprawny plik zapisuje całość. |
| 8 | Rola i obowiązek zmianowy | Powiązanie rola–obowiązek ma flagę obowiązku zmianowego oraz porę `MORNING/MIDDLE/EVENING`. | Obowiązek wymagany dla jednej pory nie jest wymagany na pozostałych. |
| 9 | Portal dostępności | Stary miesięczny modal i jego przycisk `OK` zostały usunięte z aktywnej ścieżki zapisu. | Dodanie/odwołanie przedziału daje komunikat i aktualizuje listę bez utraty danych. |
| 10 | Diagnostyka braków | Alert zawiera datę, lokal, godziny, zmianę, rolę, obowiązek, wymaganą/faktyczną obsadę i powody dla każdego kandydata. | Z alertu można przejść do pełnej listy rozważonych pracowników. |
| 11 | Szczegóły kandydata | Widok pokazuje zmiany i godziny miesiąca/tygodnia, nominał, limity, sąsiednie zmiany, kolejne dni, dostępność i preferencję. | Kandydaci są rozdzieleni na dozwolonych, miękkie ostrzeżenia i twarde blokady. |
| 12 | Dopisanie awaryjne | Zapis operacyjny jest atomowy, blokuje reguły twarde, wymaga powodu dla miękkich, zapisuje audyt i dopiero po sukcesie tworzy powiadomienie. | Po dopisaniu alert i licznik braków aktualizują się, a wariant źródłowy pozostaje niezmieniony. |
| 13 | Kalendarz ról | Daty wynikają z miesiąca i danych wariantu, bez wpisanego na sztywno lipca 2026. | Lipiec, sierpień, luty i rok przestępny mają prawidłową liczbę i pozycje dni. |
| 14 | Role i OR-Tools | Generator roli używa tego samego katalogu scenariuszy, wariantów i wersji solvera co firma; publikacja następuje dopiero po globalnym scaleniu. | Wybrany wariant roli jest widoczny w kompozycie, a globalna kontrola wykrywa kolizje. |
| 15 | Scenariusze i warianty | Generator pokazuje wszystkie aktywne scenariusze, historię uruchomień, wiele wariantów, metryki, wybór i publikację. | Poprzednie generowania nie są nadpisywane; można porównać koszt, braki, naruszenia i obciążenie. |
| 16 | Generator a operacje | Generator służy do tworzenia i wyboru; Grafik operacyjny pokazuje wyłącznie opublikowaną wersję i korekty. | Wariant roboczy nie zmienia grafiku operacyjnego bez jawnej publikacji. |
| 17 | Jedno źródło pracowników | Matrix jest jedynym administracyjnym edytorem; „Pracownicy i role” jest katalogiem z linkiem do właściwego pracownika w Matrixie. | Zmiana w Matrixie pojawia się po odświeżeniu katalogu, generatora i portalu. |
| 18 | Publikacja | Kontrola gotowości zwraca polskie blokady i szczegółowe alerty; próba jest audytowana, a publikacja z brakami wymaga powodu. | Nie pojawia się sam kod `PLAN_NOT_READY`; szczegół prowadzi do alertu wariantu. |
| 19 | Dynamiczna obsada | Zmiany i reguły zapotrzebowania są rekordami bez limitu siedmiu pól; wspierają `SET`, `ADD` i `REMOVE`. | Można dodać m.in. niedzielny blok `12:00–15:00 +2` i sobotni `15:00–17:00 +3`. |

## Audyt pozostałości Alpha 15

Usunięte z aktywnego runtime'u:

- źródło Edge Function `schedule-optimizer` i wszystkie wywołania z frontendu;
- generowanie, publikacja, awaryjna obsada, Matrix, pracownicy, dostępność, preferencje, ewidencja oraz importy zapisujące do starego modelu;
- stary duplikat modułów administracyjnych i techniczna nazwa `CompleteModules`;
- bezpośrednie wywołanie poprzedniego endpointu publikacji OR-Tools, które omijałoby audyt Alpha 16.

Świadomie zachowane do kontrolowanego cutoveru:

- wartość flagi `ALPHA15`, aby produkcja nie przełączyła silnika przed uruchomieniem workera i gatewaya;
- wyłącznie odczyt starych, już opublikowanych grafików oraz czterech trwających runów;
- historyczne funkcje i migracje bez grantów zapisu, potrzebne do odtworzenia schematu i jawnego rollbacku właścicielskiego;
- zdalna funkcja `schedule-optimizer` do czasu formalnego zakończenia starych runów; jej kod nie jest już częścią nowego release'u.

Moduły bez nowego, wersjonowanego kontraktu (np. ewidencja czasu) są jawnie zablokowane zamiast zapisywać do Alpha 15.
