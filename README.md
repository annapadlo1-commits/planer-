# GRAFIK PRO 3.0 — Alpha 3

Nowy rdzeń aplikacji planowania dla KRUCZEJ i PAWILONÓW.

## Architektura

- Next.js + TypeScript: frontend właściciela, menadżera i pracownika.
- Supabase PostgreSQL: główna baza danych.
- Supabase Auth + RLS: logowanie i dostęp według roli oraz zakresu.
- Supabase Realtime: zadania, powiadomienia i status generowania.
- Supabase Storage: załączniki i opcjonalne dowody obecności.
- Python + OR-Tools + Cloud Run Job: generator oraz prognozy.
- Google Sheets / XLSX / CSV / PDF: import i eksport, nie baza produkcyjna.

## Działający przekrój Alpha 3

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

## Uruchomienie

1. `npm install`
2. Skopiuj `.env.example` do `.env.local`.
3. Uruchom migracje `0001_core_schema.sql`, a następnie `0002_demo_seed.sql`.
4. `npm run dev`

Po utworzeniu projektu Supabase skopiuj `.env.example` do `.env.local` i uzupełnij publiczny URL oraz klucz anon. Klucza `service_role` nie wolno umieszczać w kodzie przeglądarki.

Frontend używa obecnie bezpiecznych danych demonstracyjnych w pamięci. Następny etap
zastąpi je zapytaniami Supabase oraz uruchomi logowanie i uprawnienia użytkowników.
