# GRAFIK PRO 3.0 — Alpha 12 Matrix & Calendar

Alpha 12 rozwija działającą bazę Alpha 11 bez usuwania danych źródłowych Alpha 5:
76 pracowników (`GP-001`–`GP-076`), dwa lokale, ustalone role, funkcje, godziny i zapotrzebowanie.

## Zakres Alpha 12

- czytelny, filtrowany Matrix według lokalu, dnia i scenariusza;
- wersjonowany import/eksport Matrixa w Excelu (import zawsze tworzy szkic);
- sugestie dostępów z Excela nie zmieniają chronionych uprawnień aplikacji;
- ręczna edycja, dodawanie i usuwanie przydziałów w grafikach ról;
- ponowne generowanie pustego grafiku roli;
- klikalne konflikty z wymaganiami, brakami i listą osób niedostępnych;
- miesięczny kalendarz dostępności pracownika (zielony/czerwony) z historią;
- preferencje w osobnej sekcji, z polami zależnymi od rodzaju preferencji;
- miesięczny kalendarz opublikowanych zmian pracownika, eksport XLSX/ICS i podgląd współpracowników;
- niedostępność z portalu i Kadromierza wyklucza pracownika z generatora;
- dodana po generowaniu niedostępność tworzy konflikt krytyczny, nie usuwa przydziału po cichu.

## Aktualizacja istniejącej Alpha 11

1. W Supabase SQL Editor uruchom cały plik
   `supabase/migrations/0008_alpha12_matrix_calendar_and_access.sql`.
2. Oczekiwany wynik: `Success. No rows returned`.
3. Dopiero po sukcesie wgraj kod do GitHub/Vercel.

Nie uruchamiaj ponownie migracji `0001`–`0007` na istniejącej bazie.

## Kontrola kodu

```bash
npm ci
npm run lint
npm run build
```

Obie kontrole przechodzą w paczce Alpha 12.

## Zmienne Vercel

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
```

Obsługiwany jest również alias `NEXT_PUBLIC_SUPABASE_ANON_KEY`.
