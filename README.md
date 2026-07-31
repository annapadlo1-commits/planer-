# GRAFIK PRO 3.0 — Alpha 10 Correct Base

Ta paczka rozwija właściwy silnik Alpha 5/6 i Supabase. Nie zawiera atrap opartych na
`localStorage` ani losowych pracowników, godzin lub wyników.

## Nienaruszona baza ustaleń

- dokładnie 76 pracowników demonstracyjnych `GP-001`–`GP-076`,
- 30 kelnerów, 24 barmanów, 10 osób Pizzabar, 6 Prep i 6 Pomoc,
- lokale Krucza i Pawilony,
- godziny, obsada, HOST, zamknięcia, menadżerowie i rotacje z `0002_demo_seed.sql`,
- działający generator PostgreSQL z Alpha 5.

## Moduły tej paczki

- polski interfejs i responsywny układ,
- lista aktywnych pracowników oraz widoczne archiwum z przywracaniem,
- edycja danych pracownika, HR i chronionych stawek,
- wersjonowany Matrix: role, funkcje, lokale, zachowanie historii i publikacja wersji,
- definicje zmian i zapotrzebowanie przeniesione z realnej bazy Alpha 5,
- grafiki generowane oddzielnie dla ról wyłącznie po kliknięciu `Generuj`,
- niezależny status, wersja, liczba rzeczywistych przydziałów i konflikty grafiku roli,
- zgłoszenia dostępności, preferencji, urlopów i nieobecności,
- chroniony budżet, ewidencja czasu oraz import/eksport CSV Kadromierza.

## Aktualizacja istniejącej instalacji

1. W Supabase SQL Editor uruchom tylko nową migrację:
   `supabase/migrations/0006_complete_product_modules.sql`.
2. Oczekiwany komunikat: `Success. No rows returned`.
3. Dopiero potem wgraj zawartość paczki do repozytorium i wykonaj push.
4. Vercel zbuduje aplikację automatycznie.

Migracja `0006` nie usuwa ani nie ponownie seeduje pracowników. Rozszerza istniejącą
bazę, dlatego liczba aktywnych osób pozostaje zgodna z jej faktycznym stanem.

## Nowa, pusta baza

Uruchom kolejno migracje `0001`–`0006`. Nie pomijaj żadnego numeru.

## Zmienne Vercel

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
```

Obsługiwany jest również starszy alias `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
Klucza `SUPABASE_SERVICE_ROLE_KEY` nigdy nie wolno dodawać do frontendu.

## Kontrola techniczna

```bash
npm ci
npm run lint
npm run build
```

Obie kontrole przechodzą dla tej paczki.
