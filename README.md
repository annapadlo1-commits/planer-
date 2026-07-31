# GRAFIK PRO 3.0 — Alpha 5 Live Engine

Pełny demonstracyjny przepływ planowania dla KRUCZEJ i PAWILONÓW:
Next.js/Vercel jako frontend oraz Supabase jako bezpieczna baza i silnik.

## Co działa w Alpha 5

- generowanie pełnego miesiąca bez limitu czasu przeglądarki (RPC PostgreSQL),
- trwały zapis wariantu, zmian, przydziałów, kosztów i alertów,
- pięć niezależnych pul ról oraz wspólny grafik,
- ograniczenie pracownika do jednej roli podstawowej,
- lokalizacje stałe, rotacyjne i nadgodziny w drugim lokalu,
- HOST jako dodatkowa funkcja kelnera,
- CLOSE_SHIFT dla kelnera/barmana i wymagane zamknięcia wieczorne,
- menadżerowie roli i lokalizacji,
- dostępność, brak kolizji, 11 godzin odpoczynku, limity tygodniowe i miesięczne,
- poziomy obsady 85%, 100% i 110%,
- tryb zrównoważony, minimalny koszt i preferencje,
- scenariusze bazowy, eventowy i oszczędny dające różne wyniki,
- potwierdzone eventy zwiększające obsadę i unieważniające wcześniejszy plan,
- zamknięcie lokalu wyłączające zmianę,
- zapis i publikowanie wariantów,
- grafik operacyjny z filtrami lokal/rola/data,
- miesięczny kalendarz z eventami i miniaturami zespołu,
- widok obciążenia per pracownik,
- lista realnych braków i naruszeń kompetencji,
- awaryjne dopisanie pracownika z kontrolą roli, lokalu i kolizji,
- opcjonalne powiadomienie dopisanego pracownika posiadającego konto,
- koszt planu i podział kosztów według roli,
- eksport CSV grafiku i widoku pracowników,
- Supabase Auth, właściciel demo i ograniczanie danych według zakresu dostępu.

## Instalacja / aktualizacja istniejącego demo

W Supabase SQL Editor uruchom tylko nową migrację:

```text
supabase/migrations/0004_planning_engine.sql
```

Oczekiwany wynik: `Success. No rows returned`.

Następnie wypchnij kod do GitHub. Vercel automatycznie uruchomi build.
Po otwarciu aplikacji wybierz `Nowy wariant`, ustaw parametry i kliknij
`Generuj i zapisz wariant`. Wynik pojawi się w Grafiku operacyjnym.

Przy nowej, pustej bazie uruchom kolejno:

1. `0001_core_schema.sql`
2. `0002_demo_seed.sql`
3. `0003_auth_and_access.sql`
4. `0004_planning_engine.sql`

## Zmienne Vercel

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
```

Obsługiwany jest również starszy alias `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
Nigdy nie dodawaj `SUPABASE_SERVICE_ROLE_KEY` do frontendu.

W Supabase → Authentication → URL Configuration:

```text
Site URL: https://planer-lemon.vercel.app
Redirect URL: https://planer-lemon.vercel.app/auth/callback
```

## Ważne

Generator jest transakcyjny: nie zapisze „częściowo gotowego” planu jako READY.
Jeżeli brakuje odpowiednich osób, wariant nadal zostaje zapisany, ale tworzy
precyzyjne alerty `SHORTAGE` lub `CAPABILITY_MISSING`. Dzięki temu menadżer widzi
konkretną datę, zmianę, rolę oraz liczbę brakujących osób.

## Zakres silnika

Alpha 5 zawiera funkcjonalny rdzeń planowania i zapisuje rzeczywiste dane w
Supabase. Nie jest jeszcze finalnym systemem produkcyjnym: przed wykorzystaniem
do ewidencji czasu pracy lub naliczania wynagrodzeń potrzebne będą testy
obciążeniowe, testy reguł prawa pracy, konfiguracja wiadomości e-mail/SMS oraz
końcowy audyt uprawnień dla konkretnej organizacji.
