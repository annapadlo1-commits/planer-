# SZAFUNEK — pełny UAT E2E od onboardingu do analiz

Ten dokument jest wykonywalną bramką wydania, a nie raportem historycznym. Test dotyczy dokładnego commita wdrożonego na kanonicznym UAT i wyłącznie projektu Supabase `nhthrtpkfpmufmrmdyjg`.

## Zasady dowodu

- Każdy etap zapisuje czas, rolę testera i dowód fizyczny w `docs/full-uat-evidence.json`.
- `PASS` oznacza rzeczywisty przebieg w zalogowanym Chrome, nie test kontraktowy ani odczyt kodu.
- Konsola musi zakończyć się z `0` błędów i `0` nieobsłużonych błędów strony.
- Nie wolno zmieniać `main`, produkcyjnego Vercel ani Supabase `bdybebzvzapihjdauehg`.
- Końcową kontrolę wykonuje `npm run test:full-uat-evidence`. Polecenie celowo zwraca błąd, dopóki choć jeden etap lub UAT właścicielki nie ma pełnego dowodu `PASS`.

## Bramka środowiska przed testem Google Sheets

Przed etapem `google_sheets_export_import` potwierdź na tym samym wdrożeniu UAT:

- kanoniczny host to `https://uat.szafunek.pl`; `https://szafunek.pl` jest produkcją i nie wolno używać go do UAT;
- `NEXT_PUBLIC_CANONICAL_APP_ORIGIN` i `GOOGLE_OAUTH_REDIRECT_ORIGIN` wskazują dokładnie ten sam publiczny host HTTPS;
- host nie jest technicznym, zmiennym adresem pojedynczego deploymentu;
- `GOOGLE_OAUTH_CLIENT_ID`/`NEXT_PUBLIC_GOOGLE_CLIENT_ID` odpowiadają klientowi Google Cloud używanemu w UAT;
- `GOOGLE_OAUTH_CLIENT_SECRET` istnieje wyłącznie jako sekret środowiska UAT;
- Google Cloud ma dokładnie dozwolony callback `https://uat.szafunek.pl/api/google-drive/oauth/callback`;
- oba konta testowe są odbiorcami aplikacji OAuth, jeżeli ekran zgody pozostaje w trybie testowym.

Brak któregokolwiek punktu oznacza `BLOCKED`, a nie błąd konta użytkownika. Nie testuj OAuth na losowym adresie preview.

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
