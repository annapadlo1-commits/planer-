# Audyt pozostałości starego interfejsu — 2026-08-20

Powiązany rekord: `B4F-116`.

## Zakres i metoda

- Środowisko: wyłącznie UAT `nhthrtpkfpmufmrmdyjg`; bez mutacji danych.
- Stan odczytany podczas audytu: konfiguracja `v15 robocza`, 86 osób.
- Skan przeglądarkowy: 18 głównych tras w zalogowanym Chrome, po pełnym załadowaniu danych. Sprawdzono obliczone kolory tekstu, tła i obramowań.
- Skan statyczny: wszystkie pliki `.css`, `.ts` i `.tsx` w `app`, `components` i `lib`. Kolor uznano za fioletowy lub liliowy, gdy jego odcień mieścił się w zakresie 245–325° przy nasyceniu co najmniej 18%.
- Liczba w kolumnie „wykrycia” oznacza liczbę odrębnych podpisów obliczonego stylu na ekranie, a nie liczbę wszystkich elementów DOM.

## Wynik na żywym UAT

| Obszar | Wykrycia | Przykładowe pozostałości | Ocena |
|---|---:|---|---|
| Start | 0 | — | brak widocznego fioletu w badanym stanie |
| Zespół | 0 | — | brak widocznego fioletu w badanym stanie |
| Grafiki zespołów | 2 | znacznik i nagłówek kategorii `#6D4BEF` | do rozdzielenia: kolor danych kontra chrome UI |
| Scalenie | 23 | panel, ikony, etykiety i obramowania `role-composite` | najpilniejsza kompletna pozostałość starego modułu |
| Opublikowany grafik | 0 | — | brak widocznego fioletu w badanym stanie |
| Generator | 3 | ikona dodawania, licznik i obramowanie workbencha | do naprawy |
| Wydarzenia | 3 | liliowe obramowania pól i filtrów | do naprawy |
| Centrum napraw | 0 | — | brak w bieżącym pustym stanie; CSS nadal zawiera stare tokeny |
| Alerty | 0 | — | brak widocznego fioletu w badanym stanie |
| Kalendarz | 0 | — | brak widocznego fioletu w badanym stanie |
| Wiadomości | 1 | obramowanie dymku rozmowy | do naprawy; pozostałe stany wiadomości mają więcej literalnych fioletów w CSS |
| Podgląd pracownika | 0 | — | brak widocznego fioletu w badanym stanie |
| Eksport | 0 | — | brak widocznego fioletu w badanym stanie |
| Budżet | 0 | — | brak danych po publikacji w badanym miesiącu |
| Czas pracy | 0 | — | ekran przejściowy bez aktywnego modułu |
| Konfiguracja firmy | 14 | teksty akcji, obramowania filtrów i kart, stare kolory zapisane w danych, domyślny `#7257D8` | drugi najpilniejszy obszar |
| HR — skrót | 0 | — | brak widocznego fioletu w badanym stanie |
| Finanse — skrót | 0 | — | brak widocznego fioletu w badanym stanie |

Wniosek: widoczne pozostałości starego interfejsu wystąpiły w 6 z 18 głównych obszarów. Brak wykrycia w konkretnym stanie nie zamyka modułu, jeżeli jego CSS ma stare tokeny wykorzystywane dopiero po otwarciu danych, szuflady albo wariantu.

## Pełny indeks źródeł statycznych

| Plik | Wystąpienia fioletowych/liliowych HEX | Znaczenie |
|---|---:|---|
| `app/product-journey.css` | 143 | Studio lidera, asystenci, historia, wakaty, fullscreen i część ekranów prowadzonych |
| `app/uat-overhaul.css` | 125 | konfiguracja firmy, wydarzenia, kalendarze, filtry i starsze moduły UAT |
| `app/globals.css` | 79 | globalne i historyczne tokeny; wymaga ostrożnego sprzątania bez regresji |
| `app/matrix-v2.css` | 42 | konfiguracja firmy i jej formularze |
| `app/next-batch.css` | 42 | wiadomości, rozmowy, część komunikacji i kolejnego batcha |
| `app/alpha16.css` | 24 | generator oraz starsze powierzchnie alpha16 |
| `app/solver-v2.css` | 23 | generator i karty wariantów |
| `app/recovery-center.css` | 17 | Centrum napraw w stanach z danymi, dialogami i aktywnymi kartami |
| `app/alpha12.css` | 13 | historyczne powierzchnie nadal obecne w bundlu |
| `app/role-composite.css` | 7 | cały panel Scalenia widoczny na UAT |
| `app/standby-manager.css` | 7 | rezerwa i jej stany zarządcze |
| `app/complete.css` | 4 | starsze elementy kompletnego widoku |
| `components/SolverV2Workspace.tsx` | 3 | literalne akcenty w danych prezentacyjnych Studia/grafiku |
| `components/RecoveryCenter.tsx` | 1 | literalny domyślny kolor roli |
| `app/alpha11.css` | 0 HEX, 3 nazwy | historyczne odwołania słowne |
| `app/brand-streetart.css` | 0 HEX, 33 aliasy nazw | aliasy zgodności mapowane na obecną paletę; nie są same w sobie widocznym fioletem |
| `app/page.tsx` | 0 HEX, 4 nazwy | nazwy zmiennych/kluczy zgodności, nie kolory renderowane w badanym stanie |

## Root cause

1. Nowa warstwa `brand-streetart.css` została dołożona nad starszym systemem, ale nie zastąpiła wszystkich reguł źródłowych.
2. Moduły Scalenia, Generatora, Wiadomości, konfiguracji oraz Studia mają własne historyczne arkusze CSS z literalnymi wartościami, więc globalny rebrand nie objął wszystkich stanów.
3. Część kolorów pochodzi z danych biznesowych ról i kategorii; nie wolno ich automatycznie traktować jak kolor interfejsu ani migrować bez jawnej reguły.
4. W `MatrixV2Editor` istniały domyślne fioletowe wartości inline. Zostały lokalnie zastąpione paletą SZAFUNEK w ramach `B4F-117`, ale zmiana nie jest jeszcze wdrożona na UAT.
5. Testy źródłowe deklarujące brak „lavender controls” nie wykonują pełnego przeglądu obliczonych stylów wszystkich danych i otwartych stanów. Dlatego przechodziły mimo widocznego fioletu.

## Zalecana kolejność naprawy

1. Scalenie: zastąpić `role-composite.css` tokenami aplikacji i wykonać E2E całego panelu.
2. Konfiguracja firmy: usunąć stare tokeny z `matrix-v2.css` i właściwych fragmentów `uat-overhaul.css`; oddzielić kolory danych od chrome UI.
3. Generator i Studio lidera: wspólne tokeny dla `solver-v2.css`, `alpha16.css` i części `product-journey.css`.
4. Wiadomości i wydarzenia: `next-batch.css` oraz pola formularzy w `uat-overhaul.css`.
5. Stany warunkowe: Centrum napraw, rezerwa, portale i szuflady, które w bieżącym stanie nie miały danych.
6. Po naprawie wykonać ponownie automatyczny computed-style scan 18 tras oraz fizyczny E2E desktop/mobile z otwartymi dialogami, danymi i Studio lidera.

## Kryterium zamknięcia

- Zero starego fioletowego/liliowego chrome UI na 18 głównych trasach oraz w otwartych stanach warunkowych.
- Kolory ról/kategorii są jawnie oznaczone jako dane biznesowe i pochodzą wyłącznie z opublikowanej konfiguracji.
- Wszystkie domyślne akcenty, obramowania, ikony, stany aktywne i placeholdery pochodzą ze wspólnej palety SZAFUNEK.
- Brak regresji desktop/mobile, filtrów, scrolla, Studio lidera i ekranów z danymi.
- Wdrożenie na UAT, czysta konsola Chrome i potwierdzenie właścicielki; dopiero potem rekord może otrzymać końcowy PASS/CLOSED.
