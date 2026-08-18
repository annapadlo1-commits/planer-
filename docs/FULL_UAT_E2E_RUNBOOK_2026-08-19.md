# GRAFIK PRO — pełny UAT E2E od onboardingu do analiz

Ten dokument jest wykonywalną bramką wydania, a nie raportem historycznym. Test dotyczy dokładnego commita wdrożonego na kanonicznym UAT i wyłącznie projektu Supabase `nhthrtpkfpmufmrmdyjg`.

## Zasady dowodu

- Każdy etap zapisuje czas, rolę testera i dowód fizyczny w `docs/full-uat-evidence.json`.
- `PASS` oznacza rzeczywisty przebieg w zalogowanym Chrome, nie test kontraktowy ani odczyt kodu.
- Konsola musi zakończyć się z `0` błędów i `0` nieobsłużonych błędów strony.
- Nie wolno zmieniać `main`, produkcyjnego Vercel ani Supabase `bdybebzvzapihjdauehg`.
- Końcową kontrolę wykonuje `npm run test:full-uat-evidence`. Polecenie celowo zwraca błąd, dopóki choć jeden etap lub UAT właścicielki nie ma pełnego dowodu `PASS`.

## Etapy

1. `onboarding_import_excel` — pobierz prosty plik, uzupełnij strukturę i zespół, sprawdź, zastosuj, opublikuj konfigurację oraz pobierz ponownie plik; potwierdź automatyczne numery GP i brak błędów formuł.
2. `google_sheets_export_import` — utwórz natywny arkusz przez Google OAuth na kanonicznym hoście, edytuj go, pobierz jako `.xlsx`, wykonaj `Sprawdź plik`, zastosuj i ponownie wyeksportuj.
3. `team_and_access` — potwierdź jedyne źródło zespołu, role podstawowe/dodatkowe, lokale, stały wzorzec pracy oraz poziomy dostępu właściciela, managera i pracownika, w tym ukrycie finansów.
4. `published_configuration` — sprawdź rozdzielenie wersji roboczej i opublikowanej, historię, datę obowiązywania i to, że generator czyta właściwą publikację.
5. `generator_all_strategies` — dla reprezentatywnych kategorii uruchom trzy strategie; sprawdź twardą niedostępność, osiągalny cel, sprawiedliwość, koszty, role, obowiązki, braki i prawdziwe wyjaśnienia kandydatów.
6. `leader_studio_manual_and_generated` — otwórz Studio z wariantu oraz od pustej obsady; filtruj rolę, przeciągaj na wakaty kalendarza, przenoś przydziały, wykonaj kontrolę bez zapisu, zapisz z powodem, użyj operacji zbiorczych, historii i uzupełnienia wyłącznie wakatów; potwierdź brak nakładania panelu ryzyka.
7. `publication_and_employee_portal` — przeprowadź workflow akceptacji, publikację kategorii i firmy, a następnie rzeczywisty login pracownika: kalendarz, dostępność, współpracownicy, rezerwa i zamiana bez ujawnienia niedozwolonych danych.
8. `analytics_and_staffing_risk` — sprawdź koszt, pokrycie, jakość planu i ryzyko obsady per dzień/rola/lokal, drill-down oraz potwierdzenie publikacji z brakami.
9. `state_filters_scroll_and_console` — podczas całego przebiegu sprawdź trwałość filtrów, perspektywy, pozycji scrolla i fokusu oraz brak błędów konsoli na desktopie, tablecie i telefonie.

Każdy `FAIL` otrzymuje istniejące ID z nowym dowodem albo nowe ID, jeśli ma niezależną przyczynę lub kryterium akceptacji. Żaden aktywny rekord nie otrzymuje `CLOSED` przed potwierdzeniem właścicielki.
