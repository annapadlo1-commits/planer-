# GRAFIK PRO 3.0 — Alpha 4

Nowy rdzeń aplikacji planowania dla KRUCZEJ i PAWILONÓW.

## Architektura

- Next.js + TypeScript: frontend właściciela, menadżera i pracownika.
- Supabase PostgreSQL: główna baza danych.
- Supabase Auth + RLS: logowanie i dostęp według roli oraz zakresu.
- Supabase Realtime: zadania, powiadomienia i status generowania.
- Supabase Storage: załączniki i opcjonalne dowody obecności.
- Python + OR-Tools + Cloud Run Job: generator oraz prognozy.
- Google Sheets / XLSX / CSV / PDF: import i eksport, nie baza produkcyjna.

## Zakres funkcjonalny

- responsywne Centrum dowodzenia,
- przełączanie lokalizacji,
- tygodniowy kalendarz KRUCZEJ i PAWILONÓW,
- rzeczywiste godziny zmian obu lokali,
- klikalne KPI, braki, zmiany i wydarzenia,
- panel eventu wymagającego weryfikacji,
- formularz nowego wariantu planu,
- sygnał budżetowy i wykres plan kontra wykonanie,
- mobilna nawigacja,
- pierwszy schemat Supabase z RLS.
- miesięczny kalendarz menadżerski: lokal / rola / pracownik,
- miniatury zespołu, poziomy obsady, eventy i szczegóły dnia,
- widok grafiku pojedynczego pracownika,
- prawdziwy eksport widoku pracownika i rejestru czasu do CSV,
- rozpoczęcie i zakończenie zmiany z koncepcją QR + geolokalizacja,
- historia obecności i pozycje wymagające weryfikacji,
- seed 76 unikatowych pracowników z rolami, funkcjami i lokalizacjami,
- realne definicje zmian i pełna bazowa macierz obsady.

## Nowości Alpha 4

- połączenie przeglądarki i serwera z Supabase,
- logowanie i rejestracja przez Supabase Auth,
- bezpieczna obsługa potwierdzania adresu e-mail,
- pierwsze konto może przejąć rolę właściciela środowiska demo,
- pobieranie rzeczywistej liczby pracowników, lokalizacji, zmian i eventów,
- status połączenia z bazą w nagłówku aplikacji,
- odczyt roli użytkownika i powiązanego profilu pracownika,
- ekran oczekiwania dla kont bez nadanych uprawnień,
- wylogowanie i odświeżanie sesji,
- migracja RLS dla tabel konfiguracyjnych i operacyjnych,
- fallback do statycznego trybu demo, jeśli zmienne Supabase nie są ustawione.

## Uruchomienie

1. `npm install`
2. Skopiuj `.env.example` do `.env.local`.
3. Uruchom kolejno migracje `0001_core_schema.sql`, `0002_demo_seed.sql`
   oraz `0003_auth_and_access.sql`.
4. `npm run dev`

Jeżeli wcześniejsze wykonanie `0002_demo_seed.sql` zostało przerwane, najpierw
uruchom `supabase/reset_demo_data.sql`, a dopiero potem poprawny plik `0002_demo_seed.sql`.

Po utworzeniu projektu Supabase skopiuj `.env.example` do `.env.local` i uzupełnij publiczny URL oraz klucz anon. Klucza `service_role` nie wolno umieszczać w kodzie przeglądarki.

Frontend używa obecnie bezpiecznych danych demonstracyjnych w pamięci. Następny etap
rozszerzy zapis operacji, eventów i planów do Supabase.

## Konfiguracja Vercel

Ustaw dla Production, Preview i Development:

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
```

Obsługiwany jest też starszy alias `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
Nie umieszczaj `SUPABASE_SERVICE_ROLE_KEY` w zmiennej dostępnej dla przeglądarki.

W Supabase w `Authentication → URL Configuration` ustaw `Site URL` na domenę
produkcyjną Vercel i dodaj adres podglądowy w `Redirect URLs`, aby potwierdzenia
e-mail wracały do `/auth/callback`.
