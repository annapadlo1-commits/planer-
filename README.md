# GRAFIK PRO 3.0 — Alpha 11 Repair

Alpha 11 zastępuje wadliwą Alpha 10. Zachowuje bazę 76 pracowników
`GP-001`–`GP-076`, dwa lokale, ustalone godziny i reguły Alpha 5.

## Najważniejsze naprawy

- poprawny ciemno-śliwkowy pasek nawigacji,
- wszystkie panele edycji wyświetlane ponad warstwą przyciemnienia,
- polskie etykiety statusów, scenariuszy, trybów, uprawnień i alertów,
- edycja definicji zmian oraz zapotrzebowania według lokalu, dni, godzin i ról,
- grafik roli odizolowany od aktywnego grafiku operacyjnego,
- miesięczny kalendarz grafiku roli,
- jawne przekazanie, zatwierdzenie i scalenie grafików ról,
- Centrum dowodzenia zmienia się dopiero po utworzeniu i publikacji grafiku operacyjnego,
- portal powiązany z `auth.uid()` zamiast pracownikiem wybranym demonstracyjnie,
- działające zgłoszenia pracownika,
- rozpoczęcie i zakończenie pracy z wyborem dozwolonego lokalu i geolokalizacją,
- migracja odłącza błędne techniczne plany ról Alpha 10 od Centrum dowodzenia.

## Aktualizacja wdrożonej Alpha 10

1. W Supabase SQL Editor uruchom cały plik:
   `supabase/migrations/0007_alpha11_repair_workflows.sql`.
2. Oczekiwany wynik: `Success. No rows returned`.
3. Dopiero po sukcesie wgraj kod do GitHub i uruchom wdrożenie Vercel.

Nie uruchamiaj ponownie migracji `0001`–`0006` na istniejącej bazie.

## Kontrola kodu

```bash
npm ci
npm run lint
npm run build
```

Kontrola TypeScript i produkcyjny build przechodzą dla tej paczki.

## Zmienne Vercel

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
```

Obsługiwany jest także alias `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
