# GRAFIK PRO 3.0 — Alpha 8 Complete Matrix

Kompletna, interaktywna wersja demonstracyjna modułów Matrixa, pracowników oraz
grafików generowanych według roli. Cały interfejs jest po polsku i wraca do
zaakceptowanego kierunku wizualnego: śliwkowa nawigacja, jasna przestrzeń robocza
i kalendarz jako główny widok planowania.

## Najważniejsze działające elementy

- Matrix organizacji: role, funkcje, wzorce zmian i zapotrzebowanie,
- tworzenie kolejnych wersji Matrixa i widoczna historia,
- edycja, archiwizacja i przywracanie ról,
- lista dokładnie 76 unikalnych pracowników demonstracyjnych z rolą, lokalem, umową, limitem godzin
  i uprawnieniami kierownika zmiany,
- dodawanie, edycja i archiwizacja pracowników,
- oddzielne grafiki dla ról: Kelner, Barman, Pizzabar, Prep i Pomoc,
- generowanie rzeczywistych przydziałów na cały miesiąc,
- widok kalendarza grafiku roli oraz edycja pracownika, lokalu, godzin, zmiany
  i funkcji na zmianie,
- polski obieg: wersja robocza → przekazany do zatwierdzenia → zatwierdzony,
- wspólny grafik operacyjny, analizy oraz eksport CSV,
- dwa lokale: Krucza i Pawilony,
- zapis zmian demonstracyjnych w pamięci przeglądarki (`localStorage`).

Istniejące migracje `0001`–`0005` oraz silnik Supabase z Alpha 6 pozostają w
pakiecie. Interaktywny moduł Alpha 8 jest bezpieczną warstwą demonstracyjną:
można go przeglądać i modyfikować bez naruszania danych wdrożonej bazy.

## Uruchomienie

```bash
npm ci
npm run dev
```

Kontrola produkcyjna:

```bash
npm run lint
npm run build
```

## Wdrożenie przez Codespaces

Po rozpakowaniu zawartości do katalogu repozytorium:

```bash
npm ci
npm run lint
npm run build
git add .
git commit -m "GRAFIK PRO 3.0 Alpha 8 Complete Matrix"
git push origin main
```

Nie kopiuj katalogów `.next` ani `node_modules`. Vercel zbuduje je ponownie.
