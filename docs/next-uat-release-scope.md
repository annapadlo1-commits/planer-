# GRAFIK PRO — zakres kolejnego UAT

Ten dokument jest bramką zakresu. Każda pozycja odwołuje się do pełnego opisu w
`uat-findings-2026-08-04.md`. Produkcja pozostaje poza zakresem.

## A. Błędy blokujące wiarygodny UAT

| Id | Rezultat wymagany przed wdrożeniem |
| --- | --- |
| ENV1 | Stałe oznaczenie środowiska, projektu, wersji Matrixa i liczby pracowników. |
| I1–I3 | Eksport bieżącej bazy, jawny tryb importu, pełny podgląd, atomowy zapis bez duplikatów, kompletne zależności RPC i dokładne błędy. |
| F1–F4, P2–P3 | Jeden spójny profil pracownika, działająca edycja stawki, chronologia dodania, walidacja okresów oraz poprawna nawigacja blokad publikacji. |
| S1, B1 | Prawidłowa klasyfikacja zmian i działająca, audytowana korekta. |
| G1–G2 | Generowanie roli, poprawna domyślna dostępność, diagnostyka kandydatów i jednoznaczne odświeżanie. |
| PUB1 | Jedno skuteczne źródło grafiku; konkurencyjna publikacja jest blokowana i pokazywana jako konflikt do rozstrzygnięcia. |

## B. Użyteczność istniejących modułów

| Id | Rezultat wymagany przed wdrożeniem |
| --- | --- |
| P1 | Kalendarz dostępności: domyślnie zielony, zakresy, wyjątki pomarańczowe/czerwone, bez długiej listy i bez opuszczania strony po zapisie. |
| M1–M2A | Logiczny Matrix: pracownik/umowa w jednym miejscu, role–obowiązki razem, zmiany per lokal, kompaktowa obsada i jednoznaczne limity. |
| M3 | Warianty różniące się realnym skutkiem i opisane językiem biznesowym. |
| M4, M6 | Historia wersji, audit trail oraz wyszukiwanie po osobie, roli, lokalu i obowiązku. |
| UI1–UI3 | Formularze mieszczą się w kartach; brak długich list jednokrotnego wyboru; brak etykiet „Dowolny” i technicznych operacji. |
| M5 | Matrix jest jedynym miejscem edycji; pozostałe zakładki są katalogiem albo procesem o odrębnych uprawnieniach. |

## C. Nowe przepływy testowane w kolejnym UAT

| Id | Zakres pierwszej kompletnej ścieżki UAT |
| --- | --- |
| N1, N6 | Tablica zamian: propozycja, przyjęcie/odrzucenie, akceptacja lidera, kontrola roli/lokalu/kompetencji i audit; wspólny grafik do odczytu. |
| N2–N5 | Eventy, HOT DAY, ogłoszenia i agregaty dostępności widoczne we wszystkich kalendarzach; event zwiększa wejście obsadowe solvera. |
| N7 | Dwie osoby stand-by na rolę i dzień, Tier 1/Tier 2, brak kolizji, osobny widok pracownika i ponowna walidacja przed aktywacją. |
| UAT1–UAT2 | Reset wyłącznie izolowanego UAT oraz stale oznaczony tryb testowania person pracownik/lider/HR/finanse/właściciel. |

## D. Integracje i decyzje nieblokujące kodowania podstaw

- INT1: przygotować audytowany outbox powiadomień. Faktyczne połączenie z Discordem
  wymaga później wskazania serwera/kanału i bezpiecznego sekretu.
- PUB1: do czasu zatwierdzenia zasad nadpisania konflikt jest blokowany; system nie
  wybiera samodzielnie zwycięzcy.
- N7: gotowość nie nalicza godzin ani kosztu przed aktywacją, zgodnie ze specyfikacją.
  Model wynagrodzenia samej gotowości pozostaje konfigurowalny i niewłączony.

## Obowiązkowa bramka

Każda funkcja przechodzi: akcja UI → RPC → zapis → ponowne odczytanie → zgodny UI.
Testy samych kontrolek lub samego SQL nie zaliczają funkcji. Wdrożenie następuje
wyłącznie do odizolowanego UAT po przejściu builda, testów solvera, testów migracji,
advisors Supabase i pełnego desktopowego E2E.
