# GRAFIK PRO — znaleziska UAT z 4 sierpnia 2026

## Status dokumentu

- Rejestr znalezisk, wymagań i stanu realizacji zbiorczej poprawki.
- Po poleceniu „DO DZIEŁA” zakres `N1`–`UAT2` został włączony do kandydata kolejnego UAT. Wcześniejsze diagnozy i liczby pozostają niżej jako historyczny zapis znalezisk, nie jako opis aktualnej bazy.
- Migracje kandydata zostały trwale zastosowane wyłącznie w izolowanym projekcie Supabase `nhthrtpkfpmufmrmdyjg`. Produkcja nie została zmieniona.
- Stan danych po naprawie importu: dokładnie 76 aktywnych pracowników w tabeli głównej, 76 w aktywnym Matrixie v4 oraz 76 w roboczym Matrixie v5. Nie ma dodatkowych rekordów z błędnego importu.
- Frontend i worker pozostają kandydatem gałęzi UAT do czasu zakończenia publikacji i pełnego E2E.
- Nie podejmować decyzji produktowych bez akceptacji użytkowniczki.
- Obowiązują wcześniejsze wymagania: całe UI po polsku, techniczne kody niewidoczne, Matrix nie może być długą listą, baza nie może wymyślać danych pracowników.

## Stan realizacji lokalnej

| Obszar | Stan | Zakres poprawki |
| --- | --- | --- |
| Import Matrixa | zaimplementowany, bramka lokalna zaliczona | Eksport aktualnej bazy, tryby „aktualizuj” i „synchronizuj”, podgląd skutków, dopasowanie po stabilnej tożsamości, role, lokale standard/nadgodziny, obowiązki wraz z ich wycofaniem po odznaczeniu, umowa, stawka, daty i ograniczenia pracownika. |
| Integralność pracownika i stawek | zaimplementowana, kontrakty bazy zaliczone | Spójne pola profilu, kontrolowany krok finansowy po dodaniu pracownika, walidacja okresu stawki względem zatrudnienia, kontrola pokrycia całego miesiąca grafiku i poprawna nawigacja z blokady publikacji. |
| Grafik roli | zaimplementowany, testy silnika zaliczone | Poprawiona interpretacja dostępności ZLECENIA/B2B, bezpieczna finalizacja, widoczny wynik odświeżenia, diagnostyka kandydatów i powodów odrzucenia. |
| Portal pracownika | zaimplementowany, bramka lokalna zaliczona | Jeden kalendarz miesiąca, domyślnie zielona dostępność, zaznaczanie zakresów, wyjątki pomarańczowe i czerwone, chronione wpisy pracodawcy/urlopu/L4 tylko do odczytu, opcjonalne godziny/lokal/notatka, zapis bez opuszczania widoku. |
| Role, obowiązki, lokale i zmiany | zaimplementowany roboczo, do oceny w UAT | Pierwszy etap Matrixa, połączone zależności roli i obowiązków, zmiany pogrupowane per lokal zamiast jednej długiej listy. |
| Wymagana obsada | zaimplementowana roboczo, do oceny w UAT | Kompaktowy widok, wybór wielu zmian, język biznesowy operacji, edycja zbiorcza i usunięcie mylącego obowiązku „Dowolny”. |
| Strategie i warianty | zaimplementowane roboczo, do oceny w UAT | Porównanie rzeczywistych priorytetów strategii oraz wyjaśnienie, dlaczego różne strategie mogą zwrócić ten sam skład. |
| Historia Matrixa i audit trail | zaimplementowane roboczo, kontrakty bazy zaliczone | Lista wersji, podgląd, porównanie i historia zmian bez nadpisywania wcześniejszych wersji. |
| Klasyfikacja pór zmian | naprawa zastosowana w izolowanym UAT | Automatyczna normalizacja tylko jednoznacznych nazw/kodów oraz blokada publikacji przy nierozstrzygniętej niezgodności. |
| UAT MASTER | zaimplementowany i zabezpieczony | Właściciel może wyszukać pracownika, otworzyć jego portal oraz testować dostępność i preferencje. Wybór i zapisy są audytowane; funkcja jest włączona wyłącznie w izolowanym UAT. |

Po przejściu testów lokalnych paczka może zostać przedstawiona do wdrożenia na osobne środowisko UAT. Samo wdrożenie pozostaje poza zakresem tej sesji i wymaga osobnego polecenia.

## Bramka jakości wykonana lokalnie

- produkcyjny build Next.js: zaliczony,
- kontrola typów TypeScript: zaliczona,
- silnik OR-Tools, worker i kontrakt gatewaya: 79/79 testów oraz 26 podtestów zaliczonych,
- parser importu Matrixa: 5/5 testów zaliczonych,
- rzeczywisty plik `matrix-alpha16-szablon (1).xlsx`: odczytano 76 pracowników i 62 kompetencje; rekord Weroniki Dąbrowskiej zachował e-mail, rolę BARMAN, lokale Krucza i Pawilony, datę rozpoczęcia, ZLECENIE i stawkę 25 zł,
- migracje kandydata: zastosowane w izolowanym Supabase; testy zapisu MASTER wykonane w transakcji z wycofaniem,
- końcowy smoke grafiku roli wykrył i zatrzymał regresję identyfikatora pustego obowiązku (`||` zamiast `|-|`); kontrakt snapshotu został ponownie utrwalony po migracjach stand-by/eventów,
- ponowiony przebieg roli PREP zakończył się `READY`: trzy strategie zapisano jako trzy różne rozwiązania; transakcyjny test wyboru i publikacji utworzył 60 wpisów stand-by (Tier 1 + Tier 2 dla każdego z 30 dni), po czym został w całości wycofany bez pozostawienia publikacji testowej,
- kontrola białych znaków i konfliktów patcha: zaliczona.

Przed przekazaniem nowego adresu nadal obowiązuje bramka: publikacja gałęzi UAT, wdrożenie workera z tej samej rewizji oraz pełne desktopowe E2E UI. Produkcja pozostaje poza zakresem.

## Świadomie poza tą paczką

- pełne dostosowanie mobilne,
- osobny proces wnioskowania o urlop,
- dodatkowe hasło przy wejściu do chronionej sekcji finansowej.

Te elementy zostały odłożone zgodnie z decyzją użytkowniczki i nie blokują obecnej poprawki silnika, danych oraz podstawowych przepływów desktopowych.

## Zasada globalna interfejsu

**SAVE ma zapisywać w miejscu.** Po zapisie użytkownik pozostaje w tej samej zakładce, sekcji, rozwiniętym elemencie i możliwie tej samej pozycji przewijania. Zapis nie może przenosić na początek Matrixa ani do innego modułu.

## P1 — Portal pracownika

### P1.1 Wygląd portalu

- Obecny wygląd wymaga przebudowy.
- Zachować widoczne podsumowanie miesięczne pracownika, ale uporządkować relacje pomiędzy profilem, dostępnością, preferencjami i kalendarzem grafiku.

### P1.2 Dostępność domyślna

- Po otwarciu miesiąca wszystkie dni mają być domyślnie zaznaczone jako **MOGĘ PRACOWAĆ**.
- Pracownik przede wszystkim odznacza lub zmienia dni, w których nie może albo woli nie pracować.
- Nie wolno wymagać zaznaczania każdego dostępnego dnia osobno.

### P1.3 Jeden kalendarz zamiast listy wpisów

- Usunąć długą listę „Zapisane dni i przedziały”.
- Zastąpić ją jednym kalendarzem miesiąca pokazującym stan każdego dnia:
  - zielony — **MOGĘ**,
  - pomarańczowy — **WOLĘ NIE PRACOWAĆ / miękka preferencja**,
  - czerwony — **NIE MOGĘ / twarda blokada**.
- Kliknięcie dnia ma otwierać edycję lub odwołanie jego statusu.
- Po zmianie i zapisie użytkownik pozostaje w kalendarzu dostępności.

### P1.4 Elementy, których sposobu prezentacji nie rozstrzygamy bez makiety

- konkretne godziny dostępności,
- preferowany lokal,
- notatka,
- sposób pokazania dnia zawierającego więcej niż jedną informację.

Przed implementacją należy przedstawić użytkowniczce makietę tego kalendarza do akceptacji.

## M1 — Kolejność i architektura informacji Matrixa

### M1.1 Pierwszy widok

Pierwszą zakładką po wejściu do Matrixa ma być **ROLE, LOKALE I ZMIANY**.

### M1.2 Role, obowiązki i ich powiązania

- „Role”, „Obowiązki” oraz „Obowiązki przypisane do ról” stanowią jeden logiczny proces i mają zostać połączone w jedną spójną sekcję.
- Użytkownik ma przejść logicznie od roli do jej obowiązków i powiązań bez szukania dalszego ciągu na dole strony.
- HOST i Runner pozostają obowiązkami/funkcjami, a nie rolami bazowymi.

### M1.3 Lokale i zmiany

- Obecna długa lista zmian i bloków zapotrzebowania jest nieakceptowalna.
- Widok ma być kompaktowy i pogrupowany co najmniej per lokal.
- Przykład oczekiwanego poziomu nawigacji przekazany w UAT:
  - Krucza,
  - obecnie dostępne zmiany,
  - „Dodaj zmianę”,
  - RANO — zobacz/edytuj,
  - ŚRODEK — zobacz/edytuj,
  - WIECZÓR — zobacz/edytuj.
- Do przedstawienia przed implementacją: makieta tabeli albo wielostopniowego widoku. Nie wybierać samodzielnie finalnego wariantu.

### M1.4 Pracownicy i umowy

- Dane pracownika, rodzaj umowy, zasady czasu pracy, role, obowiązki i lokale stanowią jeden logiczny proces.
- Sekcje mają zostać scalone albo rozmieszczone obok siebie tak, aby nie wymagały skakania po całym Matrixie.
- Nie wolno domyślnie przypisywać umowy o pracę ani wymyślać limitów pracownika.

## M2 — Wymagana obsada

- Obecne „Reguły wymaganej obsady” jako długa lista są nieczytelne i trudne do edycji.
- Widok ma umożliwić szybkie zrozumienie: dla jakiego scenariusza, lokalu, zmiany, roli i obowiązku obowiązuje dana liczba osób.
- Wymagane są:
  - czytelne filtrowanie,
  - kompaktowy widok tabelaryczny albo zatwierdzony widok wielostopniowy,
  - łatwa edycja pojedyncza,
  - edycja zbiorcza,
  - brak wielostronicowego przewijania.
- Przed implementacją należy przedstawić makietę, która pomaga namierzyć regułę i pokazuje użytkownikowi, na co patrzy.

## M2A — Nominał a maksymalny limit pracownika

### Znalezisko GP-057 — Oliwia Kania

- Widok „Pracownicy i role” pokazuje **Limit miesięczny: 210 godz.**
- Profil w Matrixie pokazuje **Nominał: 168 godz./mies.** oraz **Limit tygodniowy: 40 godz.**
- To nie są dwa konkurencyjne źródła ani wartości z różnych wersji. W aktywnym Matrixie v5, roboczym Matrixie v6 i tabeli zgodności zapisano jednocześnie:
  - nominał miesięczny: 10 080 minut = 168 godzin,
  - maksymalny limit miesięczny: 12 600 minut = 210 godzin,
  - maksymalny limit tygodniowy: 2 400 minut = 40 godzin,
  - forma współpracy: UMOWA_O_PRACĘ,
  - polityka czasu pracy: CONTRACT_DEFAULT.
- Snapshot przekazany do OR-Tools zawiera obie wartości.
- Dla umowy o pracę silnik traktuje:
  - 168 godzin jako punkt odniesienia do odchylenia od nominału i naliczania nadgodzin,
  - 210 godzin jako twardy miesięczny limit, którego nie wolno przekroczyć,
  - 40 godzin jako osobny twardy limit tygodniowy.
- Dla elastycznego ZLECENIA/B2B bez indywidualnej polityki CUSTOM silnik pomija nominał oraz limity miesięczny/tygodniowy i opiera się na dostępności oraz pozostałych twardych regułach.

### Błąd interfejsu

- Dwa widoki pokazują dwa różne parametry tej samej osoby bez wspólnego kontekstu.
- Użytkownik nie widzi, która wartość jest celem, która limitem i jak wpływają na silnik.
- W jednym logicznym miejscu muszą być widoczne razem: nominał, maksymalny limit miesięczny, limit tygodniowy, forma współpracy i informacja, czy dane ograniczenie jest aktywne dla silnika.
- Finalne nazwy i układ wymagają akceptacji makiety; nie wdrażać samodzielnie.

## M3 — Warianty biznesowe i strategie scenariuszy

### Potwierdzona diagnoza bieżącego stanu

- Wszystkie trzy strategie zawierają te same osiem kryteriów w tej samej kolejności.
- Różnice są zapisane głównie w ukrytych wagach liczbowych.
- Obecny komunikat sugerujący, że priorytety są realizowane „w pokazanej kolejności”, jest więc mylący: kolejność widoczna dla użytkownika jest taka sama w każdej karcie.
- Silnik może wygenerować różne przydziały, ponieważ ukryte wagi są różne, ale obecny interfejs nie wyjaśnia ani konfiguracji, ani skutków tych różnic.
- To jest błąd projektu interfejsu, a nie brak wiedzy użytkownika.

### Wymaganie produktowe

- Sekcja ma wprost wyjaśniać:
  - czym dokładnie różnią się trzy warianty,
  - co użytkownik może zmienić,
  - jak zmiana wpłynie na wynik silnika,
  - czym są „Strategie dostępne w scenariuszach” i dlaczego dany wariant jest przypisany do scenariusza.
- Nie pokazywać użytkownikowi trzech pozornie identycznych kart.
- Nie wymagać rozumienia surowych wag, kodów metryk ani pojęć „minimalizuj/maksymalizuj” bez przełożenia na efekt biznesowy.
- Przed kodowaniem należy przedstawić i zatwierdzić model biznesowych kontrolek oraz porównania wariantów. Nie wybierać samodzielnie suwaków, poziomów ani presetów.

## M4 — Historia wersji i audit trail

### Potwierdzony stan danych

- W bazie istnieją wersje Matrixa:
  - v1–v4 — archiwalne,
  - v5 — aktywna,
  - v6 — wersja robocza UAT.
- W bazie istnieje `audit_log` z wpisami między innymi dla publikacji, ustawień, zmian, reguł obsady, obowiązków ról, scenariuszy i pracowników.
- Aktualny interfejs nie udostępnia użytkownikowi ani historii wersji, ani audit trail. To jest brak funkcjonalny UI.

### Wymagana funkcjonalność

- Widoczna lista wszystkich wersji z nazwą, numerem, statusem, datami i autorem operacji.
- Możliwość otwarcia poprzedniej wersji tylko do odczytu.
- Porównanie dwóch wersji w języku biznesowym.
- Archiwizacja i przywracanie poprzez bezpieczne utworzenie nowej wersji roboczej — bez nadpisywania historii.
- Audit trail pokazujący: kto, kiedy, co zmienił oraz wartość przed i po zmianie.
- Filtry audit trail według sekcji/obiektu, użytkownika i daty.
- Techniczne identyfikatory nie mogą być główną treścią widoku.

## Zakres oceny projektowej podczas kolejnego UAT

Po późniejszym poleceniu rozpoczęcia prac poniższe obszary otrzymały roboczą implementację. Nie oznacza to akceptacji finalnego projektu. W następnym UAT użytkowniczka ocenia co najmniej:

1. kalendarza dostępności pracownika,
2. połączonej sekcji role–obowiązki–powiązania,
3. zmian pogrupowanych per lokal,
4. wymaganej obsady,
5. wariantów biznesowych,
6. historii wersji i audit trail.

Do czasu tej akceptacji nie uruchamiać wdrożenia produkcyjnego.

## G1 — Grafiki roli: błąd generowania i nieskuteczne „Odśwież”

### Zaobserwowane w UAT

- Generowanie grafiku roli nie zakończyło się wynikiem dostępnym do wyboru.
- Przycisk „Odśwież” nie daje użytkownikowi widocznego potwierdzenia działania ani wyjaśnienia, czy stan faktycznie został ponownie pobrany.

### Potwierdzony stan techniczny

- Przebieg roli **Kelner** `f4544303-65a0-41be-babe-9b0aac6211e3` zakończył się błędem `RPC_ERROR`: finalizacja `solver_finalize_v2` zwróciła HTTP 400.
- Wszystkie trzy strategie tego przebiegu zostały oznaczone jako `FAILED`, więc nie powstał zestaw wariantów do wyboru.
- Następna próba roli **Kelner** `c7be159b-8b6f-46c7-a748-1fe7a59c9cfb` została przyjęta przez worker i w chwili diagnostyki nadal pracowała: przebieg 23%, pierwsza strategia 45%, aktywny heartbeat i ważna dzierżawa workera.
- Sam przycisk „Odśwież” wywołuje odczyt `optimizer_status_v2`, ale przy poprawnym odczycie nie pokazuje czasu ostatniej aktualizacji, komunikatu sukcesu ani informacji „bez zmian”. Z perspektywy użytkownika wygląda więc tak, jakby nie działał.

### Wymagania do zbiorczej poprawy

- Ustalić i usunąć przyczynę HTTP 400 podczas finalizacji przebiegu roli; nie maskować jej ogólnym komunikatem.
- Po ręcznym odświeżeniu pokazać jednoznaczny rezultat: nowy stan i czas aktualizacji albo komunikat „status sprawdzony — bez zmian”.
- Rozróżnić w interfejsie: trwa obliczanie, oczekiwanie w kolejce, ponowiona próba, błąd oraz przebieg wymagający odzyskania.
- Dla błędu pokazać zrozumiały powód i właściwą akcję: „spróbuj ponownie” nie może być mylone z samym „odśwież”.
- Przycisk nie może pozostać bez reakcji wizualnej; podczas żądania powinien mieć stan ładowania, a po nim wynik operacji.
- Przetestować pełną ścieżkę per rola dla co najmniej dwóch ról i wszystkich trzech wariantów, łącznie z błędem, ponowieniem, odświeżaniem i wyborem wariantu.

Nie wdrażać tej poprawki w trakcie zbierania znalezisk UAT.

## I1 — Import Matrixa: pusty szablon dopisuje dane zamiast zastępować bazę

### Zaobserwowane w UAT

- Funkcja „Pobierz szablon Excel” pobiera pusty skoroszyt, mimo że import dotyczy istniejącego Matrixa z pracownikami.
- Użytkowniczka wypełniła pusty plik jako docelową bazę pracowników, oczekując zastąpienia danych demonstracyjnych.
- Import dopisał pracowników do istniejących zamiast zastąpić albo zsynchronizować bazę.
- Interfejs nie informuje przed zapisem, że import ma wyłącznie charakter przyrostowy.
- Nie istnieje spójna ścieżka zbiorczego usunięcia lub archiwizacji pracowników demonstracyjnych.

### Potwierdzona diagnoza techniczna

- Eksport tworzy wyłącznie nagłówki arkuszy; nie umieszcza w pliku aktualnej zawartości Matrixa.
- Import pracowników działa jako `upsert`: aktualizuje rekord rozpoznany po numerze pracownika lub e-mailu, a nierozpoznany rekord tworzy jako nową osobę.
- Brak pracownika w importowanym pliku nie powoduje żadnej operacji na istniejącym rekordzie.
- Import pracowników nie posiada kolumny ani operacji `REMOVE`/`ARCHIVE`.
- Dostępna w skoroszycie operacja `REMOVE` dotyczy wyłącznie reguł wymaganej obsady; instrukcja i interfejs nie wyjaśniają tego dostatecznie.
- Import z UAT zapisał 76 wierszy pracowników. W rezultacie roboczy Matrix v6 zawiera obecnie 152 aktywnych pracowników i 1 archiwalnego, podczas gdy aktywny Matrix v5 ma 76 aktywnych i 1 archiwalnego.
- Dane zostały zmienione wyłącznie w wersji roboczej v6; aktywny Matrix v5 nie został nadpisany.

### Wymagania do zatwierdzenia przed implementacją

- Eksport do edycji ma zawierać aktualną bazę pracowników i stabilne identyfikatory, tak aby można było wykonać bezpieczny cykl: **pobierz → edytuj → podgląd różnic → importuj**.
- Import musi jawnie pytać o tryb i pokazywać jego konsekwencje. Proponowane do akceptacji tryby:
  1. **Aktualizuj i dodaj** — aktualizuje rozpoznanych pracowników, dodaje nowych i nie zmienia pozostałych.
  2. **Synchronizuj/zastąp bazę pracowników** — plik jest kompletną bazą docelową; osoby niewystępujące w pliku trafiają do podglądu jako kandydaci do archiwizacji.
- Nie usuwać fizycznie pracowników powiązanych z historią grafików. Operacja zbiorcza powinna archiwizować ich z zachowaniem audit trail; finalny mechanizm wymaga akceptacji.
- Podgląd przed zapisem musi podawać osobno: ilu pracowników zostanie dodanych, zaktualizowanych, pozostawionych bez zmian, zarchiwizowanych oraz odrzuconych jako niejednoznaczni.
- Użytkownik musi zobaczyć imienną listę osób przeznaczonych do archiwizacji i potwierdzić ją przed zapisem.
- Dodać bezpieczny sposób zbiorczego wycofania danych demonstracyjnych z wersji roboczej bez ręcznego otwierania każdego profilu.
- Nazwa „szablon” nie może sugerować pełnego eksportu danych. Interfejs powinien rozdzielić co najmniej „Pobierz pusty szablon” i „Pobierz aktualny Matrix do edycji”, jeżeli oba warianty zostaną zachowane.

### Stan bieżącej wersji roboczej

- Nie publikować Matrixa v6 w obecnym stanie 152 aktywnych pracowników.
- Nie wykonywać automatycznego czyszczenia ani archiwizacji podczas zbierania znalezisk UAT.

## I2 — KRYTYCZNE: import nie odwzorowuje kompletu danych pracownika

### Przykład kontrolny — Weronika Dąbrowska

- W przesłanym Excelu, arkusz `Pracownicy`, wiersz 36, zapisano:
  - imię i nazwisko: Weronika Dąbrowska,
  - e-mail: `barman.07@demo.pl`,
  - rola: BARMAN,
  - lokale: KRUCZA i PAWILONY,
  - data rozpoczęcia: 2025-01-01,
  - minimalny odpoczynek: 8 godzin,
  - stawka: 25 PLN/h,
  - umowa: ZLECENIE,
  - obowiązek `CLOSE_SHIFT`: TAK.
- W roboczym Matrixie v6 pracownik został utworzony jako GP-112. Baza zawiera poprawnie rolę, dwa lokale, datę zatrudnienia, stawkę, typ umowy i obowiązek zamknięcia.
- Interfejs nie prezentuje tych danych jako jednego kompletnego profilu zaimportowanego pracownika. Stawka i umowa są ukryte w osobnej sekcji historii, a formularz pod historią domyślnie wygląda jak pusty rekord do ponownego wpisania.
- Użytkownik otrzymuje wrażenie, że musi ręcznie uzupełnić wszystkie 76 osób, mimo że część danych znajduje się już w bazie.

### Niedopuszczalne wartości wymyślone przez importer

- W Excelu Weroniki puste są: nominał miesięczny, limit miesięczny, limit tygodniowy i maksymalna liczba kolejnych dni.
- Importer mimo to zapisał automatycznie:
  - 168 godzin nominału miesięcznego,
  - 210 godzin maksymalnego limitu miesięcznego,
  - 40 godzin limitu tygodniowego,
  - 6 kolejnych dni.
- Te wartości nie pochodzą z pliku. Import nie może zamieniać pustych komórek na niejawne dane pracownika, szczególnie dla umowy ZLECENIE.

### Wymagania krytyczne

- Po imporcie wszystkie obsługiwane pola z Excela mają być widoczne i edytowalne w jednym logicznym profilu pracownika; pracodawca nie może przepisywać 76 rekordów.
- Puste pole musi pozostać puste albo zostać jawnie oznaczone jako dziedziczące regułę firmową. Nie wolno zapisywać domyślnych wartości jako danych indywidualnych bez wiedzy użytkownika.
- Podgląd importu musi pokazać wynik pola po polu, w tym wartości przyjęte z pliku, odziedziczone oraz odrzucone.
- Test importu przed kolejnym UAT ma porównać wszystkie 76 wierszy i wszystkie kolumny źródłowe z rekordami zapisanymi w bazie oraz z tym, co pokazuje UI.
- Niezgodność choćby jednego pola blokuje wydanie do UAT.

## F1 — KRYTYCZNE: zapis stawki wygląda na martwy i nie obsługuje konfliktu okresów

### Potwierdzona diagnoza

- Cztery próby zapisu stawki dotarły do API i wszystkie zakończyły się HTTP 400.
- Baza zwróciła `OVERLAPPING_ACTIVE_PAY_RATE`.
- Weronika ma już aktywną stawkę 25 PLN/h od 2026-08-03 bez daty końcowej. Próba dodania kolejnej aktywnej stawki od września nakłada się na istniejący okres.
- Interfejs nie tłumaczy tego konfliktu i nie ma dla niego polskiego komunikatu, dlatego użytkownik widzi pozornie niedziałający przycisk.

### Wymagania

- Bieżąca stawka i rodzaj umowy mają być od razu widoczne w profilu, bez pustego formularza sugerującego brak danych.
- Rozdzielić jednoznacznie akcje: „Edytuj bieżącą stawkę” oraz „Dodaj stawkę od nowej daty”.
- Przed wysłaniem żądania wykrywać nakładanie okresów i wyjaśniać, którą istniejącą stawkę trzeba zakończyć lub zmienić.
- Ewentualne automatyczne zakończenie poprzedniego okresu wymaga osobnego potwierdzenia i akceptacji projektu; nie wdrażać go samodzielnie.
- Przycisk ma pokazywać stan zapisu, sukces albo czytelny błąd przy samym formularzu.
- Testy przed UAT: edycja istniejącej stawki, dodanie kolejnego niekolidującego okresu, konflikt okresów, dezaktywacja oraz zachowanie historii.

## UI1 — Formularze wychodzą poza kartę

- W sekcji nadrzędnych ograniczeń przycisk „Dodaj” wychodzi poza prawą krawędź karty.
- Układ formularza stawki jest przeciążony i również nie zachowuje bezpiecznej szerokości kontenera.
- Żaden element formularza ani przycisk nie może wychodzić poza kartę lub zasłaniać treści przy typowej szerokości pulpitu.
- Wymagany test responsywności co najmniej na szerokościach desktopowych używanych w UAT oraz przy powiększeniu przeglądarki.

## S1 — KRYTYCZNE: filtry pory zmian działają na błędnej klasyfikacji danych

### Potwierdzona diagnoza

- Wszystkie 32 szablony zmian w aktywnym Matrixie v5 i roboczym Matrixie v6 mają w bazie `shift_period = MIDDLE`.
- Dotyczy to również kodów i nazw jednoznacznie porannych (`RANO_*`) i wieczornych (`WIECZOR_*`).
- Dlatego filtr „Poranne” pokazuje 0 z 32 zmian, mimo że w bazie istnieją zmiany poranne.
- To nie jest wyłącznie błąd wyświetlania: klasyfikacja pory jest używana również w dopasowaniu preferencji i reguł pracownika w backendzie, więc może wpływać na wynik silnika.

### Wymagania

- Naprawić źródło klasyfikacji i bezpiecznie skorygować pory istniejących zmian na podstawie zatwierdzonych danych, nie wyłącznie nazwy lub niejawnego domysłu.
- Przed poprawą danych przedstawić mapowanie wszystkich 32 zmian: lokal, kod, godziny, obecna pora i proponowana prawidłowa pora.
- Testować każdy filtr osobno, wszystkie sensowne kombinacje, wyszukiwanie tekstowe, stan bez wyników oraz wyczyszczenie filtrów.
- Test musi używać rzeczywistych danych UAT i sprawdzać konkretne oczekiwane liczby, a nie tylko renderowanie kontrolek.
- Zweryfikować wpływ poprawionej klasyfikacji na preferencje pracowników, wymagania ról i generowanie grafiku.

## UI2 — Zakaz długich list jednokrotnego wyboru

### Zaobserwowane w formularzu „Dodaj regułę obsady”

- Pole „Zmiana” pokazuje długą, przewijaną listę 32 bardzo podobnych wpisów.
- Można wybrać tylko jedną zmianę, mimo że użytkownik często chce zastosować tę samą regułę do wielu zmian.
- Powtarzające się nazwy bez logicznej nawigacji po lokalu, porze i dniach utrudniają rozpoznanie właściwej pozycji.

### Zasada globalna

- W żadnym miejscu aplikacji nie są akceptowalne długie, niepogrupowane listy jednokrotnego wyboru jako podstawowy sposób pracy z większym zbiorem danych.
- Należy przeprowadzić przegląd całej aplikacji pod kątem takich kontrolek, nie ograniczać poprawki do jednego formularza.

### Wymagania do makiety

- Formularz reguły obsady musi umożliwiać logiczne zawężenie co najmniej według lokalu, pory i dni oraz wybór wielu zmian naraz.
- Użytkownik ma widzieć wszystkie objęte regułą pozycje i liczbę zmian przed zapisem.
- Potrzebna jest obsługa zbiorczego zastosowania reguły oraz czytelny podgląd skutków.
- Ostateczny model nawigacji, grupowania i wielokrotnego wyboru wymaga przedstawienia makiety do akceptacji przed implementacją.

## Obowiązkowa bramka jakości przed następnym UAT

- Sam fakt, że kontrolka jest widoczna, nie oznacza zaliczonego testu.
- Każda zmieniona funkcja musi przejść test pełnego działania na rzeczywistym zbiorze UAT: akcja użytkownika → żądanie → zapis/odczyt w bazie → ponowne załadowanie → zgodny wynik w interfejsie.
- Przed przekazaniem kolejnego UAT przygotować tabelę przypadków testowych i wyniki dla importu, filtrów, formularzy finansowych, edycji zbiorczej oraz zachowania pozycji po zapisie.

## UI3 — Reguła obsady: mylący „Dowolny” obowiązek i techniczne operacje

### „Obowiązek: Dowolny” — etykieta zakazana

- Obecna pozycja „Dowolny” może zostać zrozumiana jako informacja, że wybrana rola albo pracownik może wykonywać dowolny obowiązek. To byłoby nieprawdziwe i niebezpieczne dla konfiguracji silnika.
- Technicznie brak `duty_id` oznacza obecnie wyłącznie miejsce obsady wymagające wskazanej roli, ale bez dodatkowego wymogu konkretnej kompetencji. Nie przyznaje pracownikowi wszystkich obowiązków.
- Słowo „Dowolny” należy całkowicie usunąć z tego kontekstu.
- Do makiety: domyślnie reguła wymaga tylko roli, a osobna, jasno nazwana opcja „Ta obsada wymaga konkretnego obowiązku/kompetencji” odsłania wybór obowiązku.
- Po wybraniu roli lista możliwych obowiązków nie może zawierać elementów, które nie są przypisane do tej roli.
- Finalny tekst i sposób sterowania wymagają akceptacji przed implementacją.

### „Operacja: Ustaw wartość” — techniczny mechanizm niewłaściwy dla użytkownika

- Obecna lista pokazuje wewnętrzne operacje dziedziczenia konfiguracji: `SET`, `ADD`, `MULTIPLY`, `REMOVE`.
- Ich faktyczne znaczenie:
  - `SET` — ustaw dokładną liczbę osób i zastąp wcześniejszą/odziedziczoną wartość,
  - `ADD` — dodaj wskazaną liczbę osób do wartości odziedziczonej,
  - `MULTIPLY` — pomnóż wartość odziedziczoną,
  - `REMOVE` — wyzeruj/wyłącz odziedziczone wymaganie.
- Użytkownik nie powinien znać tych kodów ani domyślać się znaczenia „operacji”.
- W scenariuszu bazowym nie ma wartości nadrzędnej, więc formularz powinien pytać po prostu: „Ile osób tej roli jest potrzebnych?”. Pokazywanie `ADD`, `MULTIPLY` i `REMOVE` w tym miejscu jest nielogiczne.
- W scenariuszu dziedziczącym interfejs powinien używać decyzji biznesowych, np. zachowaj bazową obsadę, ustaw inną liczbę, zwiększ/zmniejsz albo wyłącz wymaganie. Ostateczny model wymaga makiety i akceptacji.
- Podsumowanie przed zapisem musi pokazywać wynik końcowy w języku biznesowym, np. „Na każdej wybranej zmianie wieczornej w Kruczej wymaganych będzie 2 pracowników roli BARBACK; bez dodatkowego wymogu kompetencji”.

## P2 — Chronologia dodawania pracownika i uzupełnienia stawki

### Wymagany przebieg

1. Użytkownik zapisuje podstawowe dane nowego pracownika.
2. Aplikacja pozostaje w kontekście właśnie utworzonej osoby i automatycznie otwiera kolejny krok: dane finansowe/stawka.
3. Sekcja jasno informuje, że aktywna stawka jest wymagana przed publikacją Matrixa.
4. Użytkownik może zapisać stawkę albo świadomie wybrać „Pomiń na razie”.
5. Po pominięciu pracownik pozostaje zapisany, ale otrzymuje wyraźny status „Stawka do uzupełnienia” i bezpośrednią akcję powrotu do tego kroku.

### Zasady

- Jest to świadomy wyjątek od globalnej zasady „SAVE zostaje w miejscu”: dotyczy wyłącznie zakończenia tworzenia nowego pracownika i przejścia do następnego kroku tego samego procesu.
- Zapis podczas późniejszej edycji istniejącego pracownika nadal pozostawia użytkownika w aktualnej sekcji i pozycji.
- „Pomiń na razie” nie może ukrywać problemu ani sugerować zakończenia konfiguracji. Należy zapisać w audit trail, kto i kiedy świadomie pominął stawkę.
- Brak stawki może blokować publikację Matrixa, ale komunikat ma pojawiać się już przy pominięciu, a nie dopiero na końcu całej konfiguracji.
- Kliknięcie pracownika na liście blokad publikacji ma otwierać bezpośrednio jego brakującą sekcję finansową, a nie początek profilu.
- Jeżeli użytkownik nie ma uprawnień do finansów, aplikacja nie może prowadzić go do niedostępnego formularza; powinna oznaczyć zadanie do wykonania przez właściwą rolę.
- Import zbiorczy jest osobnym przepływem: poprawnie zaimportowane stawki nie wymagają ponownego wpisania, a osoby bez stawek trafiają do jednej czytelnej listy uzupełnień zamiast 76 kolejnych ekranów.

### Kryteria testowe przed UAT

- dodanie pracownika i zapis stawki,
- dodanie pracownika i świadome pominięcie,
- powrót do pominiętego kroku,
- kliknięcie blokady publikacji i otwarcie właściwej osoby oraz sekcji,
- zachowanie uprawnień finansowych,
- brak ponownego wymagania danych poprawnie dostarczonych przez import.

## P3 — KRYTYCZNE: dane nowego pracownika nie przechodzą spójnie między profilem, HR i finansami

### Przykład kontrolny — Anna Maziaja, GP-154

- W formularzu pracownika wpisano między innymi:
  - forma współpracy: umowa zlecenie,
  - rola podstawowa: BARBACK,
  - lokale: Krucza i Pawilony,
  - zatrudniona od 2026-01-01,
  - planowana liczba godzin: 168,
  - uzgodniony pułap: 300.
- Odczyt bazy potwierdza, że te wartości zostały zapisane w roboczym Matrixie v7:
  - `contract_type = ZLECENIE` w profilu HR,
  - nominał 10 080 minut = 168 godzin,
  - pułap miesięczny 18 000 minut = 300 godzin,
  - rola BARBACK, dwa lokale i data zatrudnienia.
- Mimo to sekcja finansowa otwiera puste pole „Rodzaj umowy”, ponieważ korzysta z osobnego pola umowy zapisanego przy okresie stawki, zamiast wykorzystać dane wpisane już w profilu pracownika.
- Podsumowanie pracownika nie pokazuje ani formy współpracy, ani uzgodnionego pułapu 300 godzin.
- Podsumowanie pokazuje „Limit tygodniowy: 168 godz.”. Ta wartość nie została świadomie wpisana przez użytkowniczkę; formularz zapisuje ją w ukrytym polu jako techniczny placeholder dla elastycznej umowy, a następnie UI prezentuje ją jak rzeczywisty limit pracownika.
- W bazie istnieje już późniejszy okres stawki Anny: 33 PLN/h od 2026-09-01 z ponownie wpisanym typem `ZLECENIE`, co potwierdza niezależny i dublujący się przepływ finansowy.

### Wymagania krytyczne

- Dane pracownika muszą tworzyć jeden spójny profil biznesowy, nawet jeśli technicznie znajdują się w kilku tabelach.
- Forma współpracy ma być wpisywana raz i automatycznie dostępna w HR, Matrixie, finansach oraz silniku. Interfejs nie może żądać ponownego wpisania tej samej informacji.
- Jeżeli historia zmian umowy wymaga osobnego modelu czasowego, należy zaprojektować jedno jawne źródło prawdy i historię okresów; nie utrzymywać dwóch niezależnych pól wyglądających jak ta sama informacja.
- Po przejściu do kroku finansowego formularz ma być wstępnie uzupełniony wszystkimi danymi już znanymi aplikacji, w tym formą współpracy.
- Podsumowanie pracownika ma pokazywać w zrozumiały sposób co najmniej: formę współpracy, plan godzin, uzgodniony pułap, aktywne limity, daty zatrudnienia, rolę, lokale i status stawki.
- Dla ZLECENIA/B2B techniczne wartości zastępcze nie mogą być prezentowane jako rzeczywiste limity. Jeśli limit nie obowiązuje, ekran ma pokazywać „Nie dotyczy” albo „Brak indywidualnego limitu”.
- Ukryte pola formularza nie mogą tworzyć danych biznesowych, których użytkownik nie podał i nie zatwierdził.
- Po zapisie należy ponownie wczytać agregat pracownika i sprawdzić zgodność wszystkich pól pomiędzy formularzem, bazą, podsumowaniem, finansami oraz wejściem silnika.

### Rozszerzenie bramki testowej

- Test nowego pracownika musi obejmować każdą formę współpracy i wszystkie pola formularza.
- Dla każdego pola test zapisuje wartość, odświeża aplikację, otwiera ponownie profil i sekcję finansową oraz porównuje rezultat z bazą i snapshotem silnika.
- Ponowne wymaganie danych już zapisanych albo wyświetlenie niezatwierdzonego limitu blokuje wydanie do UAT.

## F2 — „Edytuj” stawkę nie uruchamia rozpoznawalnego trybu edycji

### Objaw z UAT

- W „Chronionej historii stawki” kliknięcie przycisku „Edytuj” wygląda tak, jakby nie wykonywało żadnej akcji.
- Kod po kliknięciu wyłącznie ustawia wewnętrzny stan `rateEdit` i po cichu wypełnia wspólny formularz znajdujący się pod historią.
- Nie otwiera edytora przy wybranym rekordzie, nie przewija ani nie ustawia fokusu na formularzu i nie pokazuje komunikatu, że użytkownik edytuje konkretny okres.
- Formularz zachowuje ten sam nagłówek i przycisk „Zapisz stawkę”, nie ma „Zapisz zmiany” ani „Anuluj edycję”. Użytkownik nie jest w stanie odróżnić edycji istniejącego okresu od dodawania nowego.
- Samo kliknięcie „Edytuj” zgodnie z obecną implementacją nie wysyła żądania do bazy. W logach są udane zapisy nowych stawek, ale to nie potwierdza działającego i zrozumiałego przepływu edycji.

### Wymagany przebieg

- Kliknięcie „Edytuj” ma otworzyć jednoznaczny edytor dokładnie wybranego rekordu — najlepiej bezpośrednio w jego wierszu albo w osobnym panelu.
- Nagłówek ma podawać: „Edytujesz stawkę obowiązującą od [data]”, a akcja główna: „Zapisz zmiany”.
- Wymagane są: widoczny stan edycji, fokus/przewinięcie, wyróżnienie edytowanego wpisu, „Anuluj edycję” i oddzielna akcja „Dodaj nowy okres stawki”.
- Po zapisie aplikacja ma pokazać potwierdzenie, odświeżyć historię w miejscu i zachować pozycję strony.

### Bramka testowa

- kliknij „Edytuj” przy konkretnym okresie i sprawdź wypełnienie wszystkich pól,
- zmień stawkę, zapisz, odśwież stronę i potwierdź zmianę tego samego rekordu zamiast utworzenia duplikatu,
- anuluj edycję i potwierdź brak zmian,
- sprawdź edycję przy co najmniej dwóch okresach oraz czytelny komunikat konfliktu nakładających się dat.

## F3 — KRYTYCZNE: blokada publikacji sprawdza stawki względem niewłaściwej daty i prowadzi do złego formularza

### Potwierdzona przyczyna

- Anna Maziaja (GP-154), Katarzyna Parzymięso (GP-155) i Matylda Obsrajmajtek (GP-156) mają w bazie aktywne stawki od `2026-09-01`, bez daty końcowej, w PLN i z umową `ZLECENIE`.
- Stawki prawidłowo obejmują testowany grafik na wrzesień 2026.
- Preflight publikacji domyślnie podpowiada bieżącą datę `2026-08-04` jako datę wejścia Matrixa w życie i używa tej samej daty do sprawdzenia stawek.
- Dlatego wszystkie trzy poprawnie zapisane stawki wrześniowe są uznawane za brakujące: nie obejmują 4 sierpnia, mimo że obejmują miesiąc grafiku.
- Jest to niespójne z opisem sekcji finansowej i działaniem solvera, który używa stawki obowiązującej w miesiącu grafiku.

### Błędna nawigacja

- Kliknięcie blokady „Brak aktywnej stawki” przełącza zakładkę na „Pracownicy i umowy” i otwiera ogólny formularz edycji profilu pracownika.
- W otwartym formularzu nie ma pola stawki, więc komunikat prowadzi do miejsca, w którym użytkownik nie może naprawić wskazanego problemu.
- Tekst „Kliknij pracownika, aby przejść do jego danych” jest zbyt ogólny; akcja naprawcza musi otwierać dokładnie sekcję brakującej stawki wybranej osoby.

### Wymagane zachowanie

- Rozdzielić datę obowiązywania wersji Matrixa od okresu, dla którego sprawdzana jest kompletność stawek.
- Dla grafiku wrześniowego preflight musi sprawdzać pokrycie września 2026 albo jasno pokazać użytkownikowi osobne pole „Sprawdź stawki dla miesiąca: wrzesień 2026”.
- Komunikat ma podawać konkretny wymagany okres i znalezione okresy, np. „Stawka istnieje od 01.09.2026; nie obejmuje daty wejścia Matrixa 04.08.2026”.
- Jeżeli biznesowo rzeczywiście wymagana jest stawka na dzień wejścia Matrixa w życie, system musi to wyjaśnić przed zapisem i nie może nazywać stawki wrześniowej „brakującą” bez podania konfliktu dat.
- Kliknięcie blokady ma otworzyć wybranego pracownika bezpośrednio w edytorze historii stawek, z widocznym wymaganym okresem i zachowaną pozycją po zapisie.
- Po zapisaniu poprawnej stawki preflight ma zostać automatycznie przeliczony; zniknięcie blokady należy potwierdzić po ponownym odczycie z bazy.

### Bramka testowa

- stawka zaczynająca się pierwszego dnia miesiąca grafiku,
- stawka obowiązująca wcześniej i przez cały miesiąc grafiku,
- zmiana stawki w trakcie miesiąca,
- rzeczywista luka w okresie oraz czytelny komunikat z datami,
- kliknięcie blokady → właściwa osoba → właściwy rekord stawki → zapis → automatyczne usunięcie blokady,
- ponowne załadowanie strony i zgodny wynik preflightu.

## F4 — KRYTYCZNE: brak walidacji dat okresu stawki względem zatrudnienia

### Objaw z UAT

- Aplikacja pozwala zapisać okres stawki z datami oderwanymi od rzeczywistego okresu współpracy.
- Przykład: pracownik ma datę zatrudnienia w 2025 roku, a formularz przyjmuje stawkę obowiązującą od 2024 roku.
- Formularz pozwala również wybierać dowolnie odległe daty przyszłe bez wyjaśnienia, czy jest to zaplanowana zmiana stawki, czy omyłka.

### Potwierdzona przyczyna techniczna

- Obecny formularz sprawdza jedynie, czy podano datę początkową oraz czy data końcowa nie jest wcześniejsza od początkowej.
- Funkcja bazodanowa `employee_pay_rate_save_v2` powtarza tylko podstawową kontrolę kolejności dat, kwoty, waluty i nakładania się aktywnych okresów.
- Ani frontend, ani baza nie porównują okresu stawki z `employment_start` i `employment_end` pracownika.
- Ten sam brak walidacji może więc dotyczyć ręcznego formularza, importu i każdego innego wywołania funkcji zapisu.

### Twarde reguły integralności

- Początek stawki nie może przypadać przed datą rozpoczęcia zatrudnienia/współpracy pracownika.
- Jeżeli podano datę zakończenia współpracy, okres stawki nie może wychodzić poza tę datę.
- Data końcowa stawki nie może być wcześniejsza od daty początkowej.
- Aktywne okresy stawek jednego pracownika nie mogą się nakładać.
- Zmiana dat zatrudnienia istniejącego pracownika musi ponownie zweryfikować zapisane okresy stawek i nie może po cichu pozostawić danych sprzecznych.
- Te same reguły muszą obowiązywać w interfejsie, imporcie oraz w bazie. Kontrola wyłącznie w przeglądarce jest niewystarczająca.

### Daty przyszłe — wymagane rozróżnienie

- Nie można całkowicie zabronić dat przyszłych, ponieważ prawidłowym przypadkiem jest zaplanowanie stawki od przyszłego miesiąca, np. od `2026-09-01` dla grafiku wrześniowego.
- Przyszły okres musi jednak mieścić się w okresie zatrudnienia i być jawnie prezentowany jako „Zaplanowana stawka od…”, a nie wyglądać jak bieżąca stawka.
- Dowolnie odległa data przyszła powinna wymagać potwierdzenia albo zostać ograniczona do uzgodnionego horyzontu planowania. Długość tego horyzontu jest decyzją biznesową do zatwierdzenia przed implementacją.
- Komunikat błędu ma podawać konkretną zależność, np. „Stawka nie może obowiązywać od 01.01.2024, ponieważ współpraca rozpoczyna się 01.01.2025”.

### Wymagania interfejsu

- Pole „Od” powinno korzystać z daty rozpoczęcia współpracy jako minimalnej dopuszczalnej daty.
- Pole „Do” powinno uwzględniać datę zakończenia współpracy, jeśli została podana.
- Obok formularza należy pokazać okres zatrudnienia pracownika, żeby użytkownik rozumiał ograniczenie bez szukania go w innym miejscu.
- Zapis nie może się udać, jeśli dane pracownika i stawki są sprzeczne; błąd ma pozostać w tej samej sekcji i wskazać pole wymagające poprawy.

### Bramka testowa

- stawka przed rozpoczęciem zatrudnienia — odrzucona w UI i bazie,
- stawka rozpoczynająca się dokładnie pierwszego dnia zatrudnienia — przyjęta,
- stawka po zakończeniu zatrudnienia — odrzucona,
- prawidłowa stawka zaplanowana na kolejny miesiąc — przyjęta i oznaczona jako przyszła,
- nakładające się okresy — odrzucone z czytelnym komunikatem,
- zmiana dat zatrudnienia powodująca konflikt z istniejącą stawką — zablokowana z listą konfliktów,
- import z błędnymi datami — zatrzymany w podglądzie przed zapisem z numerem wiersza i przyczyną.

## G2 — KRYTYCZNE: grafik roli BARBACK odrzuca wszystkich trzech prawidłowo przypisanych pracowników

### Objaw z UAT

- Dodano rolę BARBACK oraz trzy osoby z tą rolą, ale każdy z trzech wariantów grafiku roli pozostawia wszystkie miejsca nieobsadzone.
- Diagnostyka pokazuje 155 sprawdzonych osób, 0 bez blokady i 155 z blokadą.
- Jednocześnie pozycja „Brak wymaganej roli — 152 os.” potwierdza, że system rozpoznaje dokładnie trzy osoby posiadające rolę BARBACK.
- Interfejs nie pokazuje jednak, dlaczego właśnie te trzy właściwe osoby zostały odrzucone; zbiorcze, nakładające się liczniki dla wszystkich 155 pracowników ukrywają faktyczną przyczynę.

### Potwierdzona przyczyna — aktywny Matrix v7 i najnowszy przebieg BARBACK

- Anna Maziaja (GP-154), Katarzyna Parzymięso (GP-155) i Matylda Obsrajmajtek (GP-156):
  - mają aktywną rolę BARBACK w wersji Matrixa użytej przez przebieg,
  - mają dozwolony zwykły lokal Krucza,
  - są aktywne i pozostają w okresie zatrudnienia dla 1.09.2026,
  - mają formę współpracy `ZLECENIE`,
  - nie mają zapisanego `AVAILABLE_WINDOW` na 1.09.2026.
- Backend bezwarunkowo klasyfikuje brak `AVAILABLE_WINDOW` dla `ZLECENIE` i `B2B` jako twardą blokadę `MISSING_AVAILABILITY`, nawet gdy ustawienie „brak wpisu oznacza dostępność” jest aktywne.
- W rezultacie wszystkie trzy warianty BARBACK mają po 0 przydziałów i po 10 nieobsadzonych miejsc.
- To nie jest problem przypisania roli ani lokalu. Przyczyną jest błędny model domyślnej dostępności.

### Sprzeczność z zaakceptowaną specyfikacją Portalu pracownika

- Ustalony model brzmi: cały miesiąc jest domyślnie dostępny, a pracownik odznacza lub zmienia tylko dni, w które nie może albo woli nie pracować.
- Brak osobnego wpisu dla zielonego dnia nie może więc stanowić twardej blokady.
- Godziny dostępności są opcjonalne. Jeżeli pracownik nie zaznaczy ograniczenia godzinowego, dostępność obejmuje cały dzień i wszystkie pasujące zmiany.
- „Niedostępność — preferencja” wpływa miękko na ocenę wariantu, natomiast urlop/L4/twarda niedostępność wykluczają przydział.

### Wymagana poprawa backendu

- Ustanowić jednoznaczny model bazowy miesiąca: domyślnie dostępny cały dzień, a w bazie przechowywać przede wszystkim wyjątki i opcjonalne ograniczenia godzinowe.
- Solver, diagnostyka wariantu, ręczne dopisywanie i podgląd kalendarza muszą korzystać z tej samej funkcji rozstrzygającej efektywną dostępność.
- Dla `ZLECENIE`/`B2B` brak wyjątku nie może automatycznie tworzyć `MISSING_AVAILABILITY`, jeżeli obowiązuje zatwierdzony model domyślnej dostępności.
- Jeżeli biznesowo będzie potrzebne miesięczne potwierdzenie dostępności przez pracownika, musi ono być osobnym, widocznym statusem procesu, a nie ukrytą blokadą udającą brak danych. Taki mechanizm wymaga osobnej akceptacji.

### Wymagana poprawa diagnostyki

- Dla grafiku roli najpierw pokazywać kandydatów posiadających wymaganą rolę: w tym przypadku „3 kandydatów BARBACK”.
- Następnie dla każdej osoby pokazać imię, numer pracownika, lokal oraz dokładny zestaw pozostałych blokad.
- Podstawowe podsumowanie dla tego przypadku powinno brzmieć np. „3 osoby z rolą • 3 z właściwym lokalem • 0 dostępnych według obecnej reguły”.
- Liczniki dla wszystkich 155 osób mogą być dostępne wyłącznie jako diagnostyka rozszerzona; nie mogą zastępować odpowiedzi, dlaczego nie przydzielono właściwych pracowników.
- Powody nakładające się muszą być oznaczone jako takie; ich sumy nie mogą sugerować rozłącznych grup.

### Bramka testowa

- nowy pracownik `ZLECENIE` z rolą BARBACK, lokalem Krucza i bez wyjątków dostępności — kwalifikuje się do zmiany,
- dzień oznaczony jako zielony bez godzin — kwalifikuje się do każdej pasującej zmiany tego dnia,
- opcjonalne godziny dostępności — kwalifikują wyłącznie zmiany mieszczące się w oknie,
- miękka niedostępność — pracownik pozostaje możliwy do przypisania, ale otrzymuje karę preferencji,
- twarda niedostępność/urlop/L4 — pracownik jest odrzucony z właściwym powodem,
- diagnostyka grafiku roli pokazuje trzy osoby BARBACK i indywidualne decyzje,
- pełna ścieżka: zapis/zmiana dostępności → nowy snapshot → generowanie trzech wariantów → faktyczne przydziały → odświeżenie → zgodny wynik.

## N1 — NOWA FUNKCJA: tablica grafiku i kontrolowane zamiany

### N1.1 Zamiana skierowana do konkretnej osoby

- Pracownik może zaproponować przejęcie swojej opublikowanej zmiany innej osobie.
- Zaproszona osoba przyjmuje albo odrzuca propozycję.
- Przyjęcie przez pracownika nie zmienia jeszcze grafiku. System przesyła wniosek do właściwego lidera roli.
- Dopiero akceptacja lidera aktualizuje opublikowany grafik.
- Zmieniona pozycja jest wyraźnie oznaczona jako **ZAMIANA**.
- Audit trail ma zachować co najmniej: zmianę źródłową, osobę oddającą, osobę przejmującą, daty propozycji/przyjęcia/akceptacji, lidera zatwierdzającego oraz stan przed i po zmianie.
- Odrzucenie przez pracownika albo lidera również pozostaje w historii, ale nie zmienia grafiku.

### N1.2 Ogłoszenie otwarte na tablicy grafiku

- Pracownik może opublikować ogłoszenie o chęci oddania lub zamiany zmiany.
- Ogłoszenie jest widoczne w panelach tych pracowników, którzy spełniają warunki przejęcia, w szczególności należą do właściwej roli.
- Panel ma jasno pokazywać zachętę i akcję odpowiedzi na ogłoszenie, bez konieczności szukania go na długiej liście.
- Odpowiedź pracownika uruchamia ten sam kontrolowany proces: deklaracja chęci → decyzja osoby oddającej, jeżeli potrzebna → akceptacja lidera → aktualizacja grafiku → audit trail.
- Do ustalenia przed implementacją: czy autor może jednocześnie zaprosić konkretną osobę i opublikować ogłoszenie otwarte oraz kto wybiera zwycięską odpowiedź przy wielu chętnych.

### N1.3 Walidacja możliwości przejęcia

- Sam fakt posiadania tej samej roli nie wystarcza.
- Przed pokazaniem akcji i ponownie przed akceptacją system sprawdza co najmniej:
  - aktywność i okres współpracy,
  - rolę i lokal,
  - twardą dostępność/urlop/L4,
  - konflikt z opublikowanymi zmianami i innymi zatwierdzonymi zobowiązaniami,
  - odpoczynek, limity i inne twarde reguły właściwe dla formy współpracy,
  - wymagane obowiązki i funkcje dodatkowe.
- Jeżeli oddawana pozycja realizuje obowiązek dodatkowy, np. zamknięcie zmiany, zamiana jest dopuszczalna tylko wtedy, gdy po zamianie wymóg nadal jest pokryty:
  1. osoba przejmująca posiada tę funkcję, albo
  2. inna osoba pozostająca na tej samej zmianie posiada ją i może przejąć ten obowiązek bez naruszenia pozostałych wymogów obsady.
- Walidacja musi dotyczyć stanu aktualnego w chwili zatwierdzania. Wcześniejsza pozytywna kwalifikacja nie może pozwolić na zatwierdzenie po zmianie dostępności lub grafiku.
- Komunikat odmowy ma wyjaśniać przyczynę językiem biznesowym.

## N2 — Wspólne oznaczenia kalendarzy: ogłoszenia, eventy i HOT DAY

- Dzień z aktywnym ogłoszeniem na tablicy grafiku musi być oznaczony w kalendarzu miesiąca.
- Wszystkie istniejące podglądy kalendarza mają korzystać z jednego systemu oznaczeń i legendy.
- Co najmniej następujące stany muszą być wizualnie rozróżnialne:
  - aktywne ogłoszenie o zamianie,
  - event ze zwiększonym zapotrzebowaniem,
  - HOT DAY,
  - zwykła zmiana pracownika,
  - stand-by Tier 1,
  - stand-by Tier 2.
- Jeżeli dzień ma kilka stanów, interfejs nie może ukrywać części informacji ani opierać rozróżnienia wyłącznie na jednym kolorze.
- Kliknięcie oznaczenia ma prowadzić do właściwego kontekstu: ogłoszenia, eventu, alertu dostępności albo grafiku stand-by.
- Finalna legenda, kolory i sposób łączenia oznaczeń wymagają akceptacji makiety.

## N3 — Alerty i bieżący monitoring przyszłej dostępności

- Lider roli ma widzieć na bieżąco przyszłe ryzyko dostępności jeszcze przed wygenerowaniem grafiku.
- Widok ma prezentować agregację per dzień i per rola, np. ilu kelnerów jest dostępnych, ilu zgłosiło miękką preferencję, ilu twardą niedostępność i jaki jest postęp zbierania deklaracji.
- Lider musi móc otworzyć dzień i zobaczyć listę osób, rodzaj zgłoszenia oraz czas jego zapisania/zmiany.
- Przykład wymagany do testu: we wrześniu 20 kelnerów zapisuje niedostępność na 1–10 października; lider widzi zmianę agregacji każdego z tych dni bez czekania na generator.
- Alert może być natychmiastowy i/lub objęty podsumowaniem dziennym. Kanały, częstotliwość oraz progi wymagają akceptacji przed implementacją.
- Licznik „postęp” wymaga jednoznacznej definicji: kto ma obowiązek potwierdzić miesiąc i kiedy brak deklaracji jest informacją, a kiedy brakiem działania. Nie zgadywać tej definicji.

## N4 — HOT DAY i kontrolowana niedostępność w okresach krytycznych

- Lider może oznaczyć dzień jako **HOT DAY** i zapisać minimalne zapotrzebowanie, np. 16 barmanów 10 października.
- Pracownik nadal może zgłosić twardą niedostępność w takim dniu.
- Dzień ma być pokazany pracownikowi inaczej niż zwykły dzień i przed zapisem ma wyjaśniać, że zgłoszenie wywoła alert do lidera.
- Po zapisie alert trafia automatycznie do lidera, a zgłoszenie otrzymuje widoczny status „oczekuje na weryfikację”.
- Lider widzi wpływ zgłoszenia na prognozowaną obsadę i listę osób.
- Przed implementacją wymagane są decyzje biznesowe, których system nie może wymyślić:
  - czy lider **zatwierdza**, czy tylko **potwierdza przyjęcie do wiadomości** twardej niedostępności,
  - co dokładnie oznacza odrzucenie zgłoszenia,
  - czy w stanie oczekującym solver traktuje osobę jako twardo niedostępną,
  - czy zasady różnią się dla UoP, ZLECENIA i B2B.
- HOT DAY nie może po cichu zmienić twardej niedostępności w miękką preferencję.

## N5 — Eventy liderów jako dynamiczne zapotrzebowanie solvera

- Lider roli może tworzyć event w kalendarzu i określać dodatkowe wymagania obsady.
- Minimalny zakres eventu: nazwa, data lub zakres godzin, lokal, rola, liczba dodatkowych osób oraz opcjonalne wymagane obowiązki/funkcje.
- Przykład kontrolny: 10 października wymaganych jest 5 dodatkowych kelnerów przez cały dzień.
- Opublikowany event musi automatycznie wejść do snapshotu i reguł wymaganej obsady używanych przez generator właściwego miesiąca.
- Zmiana albo anulowanie eventu po wygenerowaniu grafiku ma oznaczyć istniejący wynik jako wymagający ponownej weryfikacji; nie może po cichu pozostawić nieaktualnego grafiku jako poprawnego.
- Event jest widoczny we wszystkich kalendarzach zgodnie z zasadą `N2`.
- Audit trail zapisuje autora, zmianę zapotrzebowania, publikację, edycję i anulowanie.

## N6 — Grafik do odczytu dla pracowników

- Pracownik musi mieć dostęp do czytelnego grafiku zespołu potrzebnego do zaplanowania zamiany, a nie wyłącznie do własnych zmian.
- Widok ma pokazywać, kto i kiedy pracuje w zakresie dopuszczonym przez rolę i politykę dostępu.
- Należy zachować jedno źródło opublikowanego grafiku; widok pracownika nie może tworzyć osobnej kopii danych.
- Zakres widoczności wymaga akceptacji: cały lokal, własna rola, zespoły współdzielące zmianę czy cała firma.
- Dane finansowe, prywatne notatki, przyczyny nieobecności i inne dane wrażliwe nie mogą być ujawnione w grafiku do odczytu.

## N7 — KRYTYCZNE WYMAGANIE SILNIKA: stand-by/back-up Tier 1 i Tier 2

### N7.1 Model biznesowy

- Dla każdej roli i każdego dnia generator grafiku roli wyznacza dwie różne osoby awaryjne:
  - **stand-by Tier 1** — pierwszy priorytet wezwania,
  - **stand-by Tier 2** — drugi priorytet wezwania.
- Stand-by generuje się razem z grafikiem roli, ale jest przypisaniem dziennym, a nie zwykłą zmianą.
- Przykład:
  - Jan Nowak ma zaplanowaną zmianę,
  - Jan Kowalski jest stand-by Tier 1,
  - Jan Tomczyk jest stand-by Tier 2.
- Jeżeli nie przychodzi tylko Jan Nowak, wzywany jest Kowalski, a Tomczyk pozostaje wolny.
- Jeżeli Nowak nie przychodzi, a Kowalski nie może go zastąpić, wzywany jest Tomczyk.
- Jeżeli w tym samym dniu wystąpią dwie awaryjne nieobecności, Tier 1 i Tier 2 mogą zostać uruchomieni równolegle.
- Tier 1 ma pierwszeństwo przed Tier 2; kolejność nie może być przypadkowa.

### N7.2 Twarda kwalifikacja stand-by

- Stand-by nie może nachodzić na zwykłą zmianę, inne przypisanie stand-by ani wymaganie innej roli, którego pracownik ma obowiązek dotrzymać.
- Kandydat musi posiadać właściwą rolę, lokal oraz funkcje/obowiązki konieczne do realnego zastępstwa.
- Twarda niedostępność, urlop i L4 wykluczają stand-by.
- Stand-by musi być realnie wykonalny z uwzględnieniem odpoczynku, czasu pracy, zmian nocnych, innych opublikowanych zmian oraz zasad umowy.
- Sam fakt, że stand-by jest tylko potencjalnym wezwaniem, nie pozwala przypisać osoby, która w razie wezwania naruszyłaby twardą regułę.
- Dopuszczalne jest wyznaczenie na stand-by osoby, która ma tego dnia wolne i pracowała poprzedniego dnia, o ile potencjalne zastępstwo nadal spełnia wszystkie właściwe reguły.
- Walidacja musi zostać powtórzona podczas faktycznego uruchomienia stand-by, ponieważ sytuacja pracownika mogła zmienić się od publikacji grafiku.

### N7.3 Widoki i podsumowania

- Stand-by Tier 1 i Tier 2 są widoczne w panelu pracownika, grafiku roli oraz wszystkich kalendarzach.
- Korzystają z osobnych oznaczeń i kolorów zgodnie z `N2`.
- W panelu pracownika nie wliczają się do zaplanowanych godzin ani liczby zwykłych zmian.
- Panel pokazuje osobno liczbę dyżurów stand-by w miesiącu, daty, rolę, lokal i poziom Tier.
- Po faktycznym uruchomieniu stand-by wykonana zmiana staje się zwykłym czasem pracy i musi wejść do godzin, kosztów oraz audit trail.

### N7.4 Aktywacja i historia

- Aktywacja stand-by ma wskazać nieobecnego pracownika, zastępowaną zmianę, uruchomiony Tier, osobę wzywającą oraz czas odpowiedzi.
- System ma obsłużyć kolejno: wezwanie Tier 1, brak możliwości/odrzucenie, wezwanie Tier 2 oraz równoległe użycie obu Tierów przy dwóch brakach.
- Po potwierdzeniu zastępstwa grafik jest aktualizowany i oznaczony jako zastępstwo awaryjne.
- Wszystkie próby, odpowiedzi i decyzje lidera pozostają w audit trail.

### N7.5 Decyzje wymagane przed projektowaniem solvera

- Ponieważ stand-by jest dzienny, a nie przypisany do konkretnej zmiany, trzeba zatwierdzić, czy kandydat musi być zdolny przejąć **każdą** potencjalną zmianę swojej roli danego dnia, czy system ma pokazywać zakres zmian, które może pokryć. Nie wybierać tego samodzielnie.
- Ustalić sposób rozliczania samego pozostawania w gotowości oraz uruchomionej zmiany.
- Ustalić termin i kanał wezwania, czas na odpowiedź oraz znaczenie braku odpowiedzi.
- Ustalić regułę sprawiedliwego rozdziału stand-by między pracowników i ewentualne preferencje pracownika.
- Ustalić, czy jedna osoba może pełnić stand-by dla więcej niż jednej roli/lokalu tego samego dnia. Domyślnie nie wdrażać takiego nakładania bez akceptacji.

### N7.6 Obowiązkowe testy

- wygenerowanie dwóch różnych osób stand-by dla każdej roli i każdego dnia,
- brak nakładania z grafikami, innym stand-by i twardymi regułami,
- wezwanie Tier 1 przy jednej nieobecności,
- przejście do Tier 2, gdy Tier 1 jest niedostępny,
- uruchomienie obu Tierów przy dwóch nieobecnościach,
- ponowna walidacja przed aktywacją,
- osobna prezentacja i podsumowanie w panelu pracownika,
- przeliczenie godzin i kosztów dopiero po faktycznym uruchomieniu,
- zgodny audit trail i powiadomienia.

## M5 — Architektura zakładek Matrix/Pracownicy/HR/Finanse

- Matrix pozostaje jedynym źródłem edycji danych pracownika, umowy, ról, lokali, obowiązków i stawek.
- Nie utrzymywać konkurencyjnych formularzy ani kopii danych w osobnych zakładkach.
- Osobne zakładki mają sens wyłącznie wtedy, gdy realizują odmienny proces i zakres dostępu:
  - **Pracownicy i role** — szybki katalog do odczytu i wejście do właściwego profilu Matrixa,
  - **Kadry i HR** — procesy HR, statusy, dokumenty i raporty, których Matrix nie obsługuje,
  - **Finanse** — chronione raporty, historia stawek, koszty i analizy dla uprawnionych osób.
- Jeżeli dana zakładka jest tylko drugim miejscem edycji tych samych pól, należy ją usunąć z głównej nawigacji albo zmienić w skrót do odpowiedniej sekcji Matrixa.
- Ostateczna decyzja o pozostawieniu każdej zakładki nastąpi po spisaniu jej unikalnych zadań i uprawnień; nie zachowywać zakładki wyłącznie dlatego, że już istnieje.

## M6 — Wyszukiwanie i filtrowanie Matrixa

- Wyszukiwanie pracownika ma działać po dowolnym fragmencie: imieniu, nazwisku, pełnym imieniu i nazwisku, numerze pracownika, e-mailu, roli, lokalu albo obowiązku.
- Wyszukiwanie ma ignorować wielkość liter i bezpiecznie obsługiwać polskie znaki.
- Wymagane filtry możliwe do łączenia: status aktywny/archiwalny, rola, lokal, forma współpracy, obowiązek/funkcja oraz kompletność danych.
- Wyniki mają aktualizować się bez opuszczania bieżącej sekcji Matrixa.
- Brak wyniku ma pokazywać aktywne filtry i umożliwiać ich wyczyszczenie jednym przyciskiem.

## B1 — BŁĄD: „28 zmian ma błędnie zapisaną porę” nie wykonuje korekty

- Matrix pokazuje komunikat „28 zmian ma błędnie zapisaną porę”.
- Kliknięcie „Popraw klasyfikację” nie aktualizuje zmian albo nie pokazuje wyniku operacji.
- Akcja ma przed zapisem pokazać listę jednoznacznych korekt i pozycje wymagające decyzji człowieka.
- Automatycznie wolno zmieniać wyłącznie klasyfikacje wynikające jednoznacznie z kodu/nazwy/godzin według zatwierdzonej reguły.
- Po zapisie interfejs pozostaje w tej samej sekcji, ponownie odczytuje dane i pokazuje: liczbę poprawionych, pominiętych i błędnych rekordów.
- Operacja jest atomowa albo jasno wskazuje częściowe niepowodzenie per rekord; nie może wyglądać na sukces bez zmiany danych.
- Każda korekta jest widoczna w audit trail.

## INT1 — Możliwa integracja z Discordem

- Integracja jest technicznie możliwa.
- Potencjalny pierwszy zakres: powiadomienia o nowych ogłoszeniach zamiany, odpowiedziach, prośbach o akceptację lidera, HOT DAY, eventach, aktywacji stand-by i krytycznych brakach dostępności.
- Discord może otrzymywać wiadomości przez webhook lub bota; wybór zależy od tego, czy komunikacja ma być wyłącznie wychodząca, czy także interaktywna.
- GRAFIK PRO pozostaje źródłem prawdy. Discord nie może samodzielnie zmieniać grafiku na podstawie zwykłej reakcji bez bezpiecznej identyfikacji użytkownika i ponownej walidacji w aplikacji.
- Najbezpieczniejszy wariant początkowy to powiadomienie z bezpośrednim linkiem do właściwej akcji w GRAFIK PRO.
- Przed implementacją ustalić serwer/kanały, mapowanie kont, zakres danych widocznych w wiadomości oraz czy bot ma obsługiwać akceptacje.

## UAT1 — KRYTYCZNE: pełny reset danych na izolowanym UAT

- Na środowisku UAT użytkowniczka musi móc przeprowadzić pełny workflow od pustego stanu: usunąć rekordy testowe, dodać nowe i ponownie wykonać proces.
- Funkcja nie może być dostępna na produkcji ani działać przypadkowo na projekcie produkcyjnym.
- Wymagane zabezpieczenia: trwałe oznaczenie środowiska UAT, rola MASTER/OWNER UAT, wpisanie jawnego potwierdzenia, podgląd zakresu oraz audit operacji.
- Do wyboru przed implementacją:
  - reset do całkowicie pustej firmy,
  - reset do minimalnych słowników technicznych bez pracowników i grafików,
  - reset do zatwierdzonego zestawu danych demonstracyjnych.
- Reset musi obejmować wszystkie zależne rekordy testowe w kontrolowanej kolejności albo odtworzyć izolowaną bazę z zatwierdzonego punktu. Nie pozostawiać osieroconych grafików, stawek, auditów, publikacji ani powiadomień.
- Przed wykonaniem system pokazuje, co zostanie usunięte i co pozostanie; po wykonaniu pokazuje raport i umożliwia rozpoczęcie pełnego workflow.

## UAT2 — MASTER i testowanie różnych ról/uprawnień

- Końcowy UAT wymaga technicznej roli **MASTER UAT**, która pozwala świadomie przełączać testowaną personę bez tworzenia niekontrolowanych uprawnień produkcyjnych.
- Wymagane persony co najmniej:
  - pracownik,
  - lider roli,
  - HR,
  - finanse,
  - właściciel,
  - MASTER UAT.
- MASTER UAT może wybrać pracownika/personę, zobaczyć dokładnie jej zakres widoku i wykonać dozwolone dla niej operacje.
- Tryb musi mieć stale widoczny baner „Testujesz jako…”, szybki powrót do MASTER oraz pełny audit przełączeń i operacji.
- MASTER UAT musi móc:
  - wprowadzać niedostępność różnych osób,
  - otwierać ich Portal pracownika,
  - sprawdzać widoczność zmian, stand-by, ogłoszeń i powiadomień,
  - przejść pełny proces pracownik → lider → właściciel/HR/finanse.
- Równolegle należy przetestować prawdziwe logowanie na konta z różnymi rolami i potwierdzić, że backend/RLS blokuje operacje spoza zakresu. Samo ukrycie elementu w interfejsie nie jest testem uprawnień.
- MASTER jest funkcją wyłącznie izolowanego UAT. Nie przenosić jej do produkcji bez osobnego projektu bezpieczeństwa i akceptacji.

## PUB1 — KRYTYCZNE: konflikt publikacji grafiku roli i grafiku firmowego

### Pytanie zgłoszone w UAT

- Co się stanie, jeżeli lider zespołu wygeneruje i opublikuje grafik swojej roli, a równolegle albo później właściciel wygeneruje i opublikuje grafik całej firmy?
- Czy któryś grafik zostanie nadpisany, czy oba pozostaną dostępne?
- Które źródło jest ważniejsze, kto rozstrzyga konflikt i jak użytkownik ma rozpoznać obowiązującą wersję?

### Potwierdzony stan obecnego backendu UAT

- Grafik firmowy i samodzielny grafik roli są zapisywane w dwóch różnych tabelach publikacji.
- Dwa osobne indeksy pozwalają jednocześnie zachować:
  - jeden aktywny grafik firmowy/composite dla miesiąca,
  - po jednym aktywnym grafiku dla każdej roli w tym samym miesiącu.
- Publikacja nowego grafiku firmowego archiwizuje poprzedni grafik firmowy/composite, ale **nie archiwizuje ani nie unieważnia** samodzielnych publikacji ról.
- Publikacja nowego grafiku roli archiwizuje wyłącznie poprzedni grafik tej samej roli. Nie zmienia aktywnego grafiku firmowego.
- Równoległe wywołania są serializowane blokadą miesiąca, więc nie powinny uszkodzić transakcji, ale blokada nie rozstrzyga konfliktu biznesowego. Po wykonaniu obu operacji oba źródła nadal pozostają aktywne.
- Kolejność publikacji nie ustala wspólnego zwycięzcy.

### Obecny, niespójny priorytet odczytu

- Portal pracownika najpierw szuka aktywnej publikacji roli zawierającej przydział tego pracownika.
- Jeżeli ją znajdzie, pokazuje grafik roli i pomija aktywny grafik firmowy — niezależnie od tego, który został opublikowany później.
- Jeżeli pracownik nie ma żadnego przydziału w opublikowanym wariancie roli, Portal może zamiast tego spaść do grafiku firmowego. W efekcie dwie osoby z tego samego zespołu mogą czytać grafik z różnych źródeł.
- Widok właściciela „aktywny grafik” odczytuje wyłącznie aktywną publikację firmową/composite i nie uwzględnia osobnych publikacji ról.
- Lider może więc widzieć i komunikować grafik roli, pracownik może otrzymać grafik roli, a właściciel nadal analizować inny grafik firmowy.
- To nie jest jeden grafik z wersjami. To są dwie konkurencyjne prawdy operacyjne.

### Rzeczywisty przykład istniejący w izolowanym UAT

- Dla września 2026 jednocześnie aktywne są:
  - grafik firmowy `UAT E2E wrzesień 2026`, opublikowany wcześniej,
  - grafik roli `UAT E2E Pizzabar powiadomienia`, opublikowany później.
- Samodzielny grafik Pizzabar obejmuje 10 pracowników i 211 przypisań.
- Grafik firmowy zawiera dla tych samych 10 osób 205 przypisań.
- Porównanie źródeł wykazało 274 różniące się pary pracownik–zmiana.
- Oba rekordy pozostają oznaczone jako `PUBLISHED`.
- Nie wykonywano dodatkowej publikacji w trakcie tej diagnozy; wykorzystano istniejące dane UAT.

### Wymagany model docelowy do akceptacji

- W danym miesiącu ma istnieć **jeden skuteczny grafik operacyjny**, odczytywany identycznie przez właściciela, liderów, pracowników, kalendarze, Portal i raporty.
- Grafik może być składany z komponentów per rola, ale komponenty nie mogą tworzyć osobnych, konkurencyjnych wersji rzeczywistości.
- Rekomendowana zasada zgodna z ustalonym procesem biznesowym:
  1. Lider odpowiada za publikację swojej roli.
  2. Opublikowany komponent roli staje się zablokowaną częścią wspólnego grafiku miesiąca.
  3. Generator firmowy wykorzystuje już opublikowane role jako twarde, widoczne wejście i generuje/uzupełnia wyłącznie role jeszcze nieopublikowane albo tworzy jawny projekt rewizji.
  4. Publikacja firmowa nie może po cichu nadpisać wcześniej opublikowanej roli.
  5. Późniejsza publikacja roli nie może po cichu nadpisać zatwierdzonego grafiku firmowego; ma tworzyć kontrolowaną rewizję tego samego wspólnego grafiku.
- Właściciel ma finalne uprawnienie do rozstrzygnięcia konfliktu, ale nadpisanie komponentu lidera wymaga:
  - pokazania różnic,
  - jawnego wyboru roli/komponentu obowiązującego,
  - podania powodu,
  - powiadomienia lidera i pracowników objętych zmianą,
  - nowej rewizji i kompletnego audit trail.
- Lider nie może nadpisać komponentu innej roli ani decyzji właściciela poza własnym zakresem.
- Sam timestamp „ostatni zapis wygrywa” jest niewystarczający i nie może być docelową regułą.

### Statusy i widoczność

- Każda rola w miesiącu ma czytelny status, np. `ROBOCZY`, `WYGENEROWANY`, `WYBRANY`, `OPUBLIKOWANY PRZEZ LIDERA`, `ZABLOKOWANY W GRAFIKU FIRMOWYM`, `WYMAGA REWIZJI`.
- Właściciel widzi kompletność grafiku firmowego: które role są opublikowane, które czekają i które pozostają w konflikcie.
- Pracownicy widzą wyłącznie skuteczny, rozstrzygnięty grafik oraz informację o późniejszej rewizji; nie wybierają pomiędzy wersją roli i firmy.
- Analizy kosztów i obsady zawsze liczą dokładnie ten sam skuteczny zestaw przypisań, który widzą pracownicy.

### Obowiązkowa obsługa współbieżności

- Jeżeli publikacja roli i firmy rozpoczynają się w tym samym czasie, jedna transakcja może poczekać na drugą, ale po uzyskaniu blokady musi ponownie odczytać aktualną rewizję.
- Druga publikacja nie może kontynuować na nieaktualnym snapshotcie. Ma zostać:
  - ponownie zweryfikowana i świadomie scalona, albo
  - zatrzymana komunikatem o nowej publikacji wymagającej odświeżenia i decyzji.
- Konflikt i sposób jego rozstrzygnięcia są częścią audit trail.

### Bramka testowa przed kolejnym UAT

- rola opublikowana przed wygenerowaniem firmy,
- rola opublikowana po wygenerowaniu, ale przed publikacją firmy,
- rola i firma publikowane równocześnie,
- grafik firmowy opublikowany jako pierwszy, a następnie próba publikacji roli,
- ponowna publikacja tej samej roli,
- właściciel świadomie zastępujący komponent roli,
- konflikt scenariusza lub wersji Matrixa,
- pracownik bez przydziału w opublikowanym komponencie roli,
- zgodność Portalu, widoku lidera, widoku właściciela, kosztów, powiadomień i audit trail,
- potwierdzenie, że w każdej sytuacji istnieje dokładnie jeden skuteczny zestaw przypisań dla miesiąca.

### Decyzje do zatwierdzenia przed implementacją

- Czy właściciel może jednostronnie zastąpić opublikowany komponent roli, czy wymagana jest ponowna akceptacja lidera?
- Czy grafik firmowy może zostać opublikowany przed ukończeniem wszystkich ról, jako wersja częściowa, czy dopiero po osiągnięciu kompletności?
- Czy zmiana scenariusza firmowego wymusza ponowne wygenerowanie już opublikowanych ról, czy właściciel może zachować wybrane komponenty?
- Jak długo przed rozpoczęciem miesiąca lider może publikować rewizje bez dodatkowej zgody?
- Nie implementować odpowiedzi na te pytania bez akceptacji użytkowniczki.

## ENV1 — KRYTYCZNE: niejawna zmiana środowiska i pochodzenia danych 155/76

### Potwierdzona diagnoza

- Widok wcześniejszego UAT pokazywał 155–156 aktywnych pracowników po imporcie.
- Aktualny, odizolowany projekt Supabase UAT `nhthrtpkfpmufmrmdyjg` nigdy nie zawierał 155 pracowników. Każda z wersji Matrixa v1–v4 zawiera dokładnie 76 profili.
- Nie wykonano w tym projekcie operacji usunięcia ani archiwizacji zaimportowanych pracowników. Historia audytu nie zawiera takiej operacji.
- Liczba 76 wynika z utworzenia nowego izolowanego UAT z bazą początkową 76 osób, a nie z usunięcia drugiej połowy rekordów.
- Zmiana środowiska i zestawu danych nie została użytkowniczce wyjaśniona dostatecznie jasno. Uniemożliwia to wiarygodne porównanie kolejnych wyników UAT.

### Wymagania

- Każdy ekran UAT ma stale pokazywać nazwę środowiska, identyfikator projektu, aktywną/roboczą wersję Matrixa i liczbę rekordów źródłowych.
- Przełączenie projektu, reset danych albo inicjalizacja nowego zestawu wymaga jawnego komunikatu przed testem i raportu po operacji.
- W Matrixie ma być dostępna historia: utworzenie wersji, źródło danych, import, tryb importu, liczba dodanych/zaktualizowanych/zarchiwizowanych rekordów oraz wykonujący użytkownik.
- Materiał przekazywany do UAT musi zawierać jednoznaczny opis zestawu startowego. Nie wolno przedstawiać nowego środowiska z innymi danymi jako kontynuacji poprzedniego bez informacji o różnicy.

## I3 — KRYTYCZNE: zapis importu wywołuje brakującą funkcję i ukrywa prawdziwy błąd

### Potwierdzona przyczyna

- Podgląd pliku utworzył automatycznie wersję roboczą Matrixa v4 z kopią 76 profili.
- Zapis importu nie zmodyfikował pracowników i nie utworzył wpisu audytu importu.
- Log PostgreSQL zawiera dokładny błąd: `function public.matrix_v2_import_preview_uat_v2(jsonb) does not exist`.
- Wdrożona funkcja `matrix_v2_import_apply_uat_v3` zależy od funkcji v2, ale migracja tworząca v2 nie została zastosowana w izolowanym projekcie UAT.
- Frontend zamienił nierozpoznany komunikat bazy na ogólne „Nie udało się zapisać zmiany. Sprawdź formularz i spróbuj ponownie”, przez co użytkownik nie otrzymał przyczyny ani wskazania sposobu naprawy.

### Wymagania naprawy

- Migracja importu musi być samowystarczalna albo przed utworzeniem funkcji publicznej jawnie sprawdzać wszystkie zależności i przerwać wdrożenie, jeśli ich brakuje.
- Podgląd i zapis muszą używać tego samego, wersjonowanego kontraktu. Nie wolno wdrożyć nowszej funkcji publicznej bez jej zależności.
- Błąd zapisu zachowuje kod techniczny, ale UI pokazuje również etap, arkusz, wiersz, pole i zrozumiałą przyczynę. Nieznany błąd otrzymuje identyfikator korelacyjny zamiast fałszywej sugestii poprawienia formularza.
- Nieudany import nie może pozostawiać mylącej, anonimowej wersji roboczej. Wersja ma zostać utworzona dopiero przy zapisie albo oznaczona jako projekt importu z czytelnym statusem i możliwością bezpiecznego anulowania.
- Import ma być atomowy i idempotentny: błąd cofa wszystkie zmiany, ponowienie tego samego pliku nie tworzy duplikatów ani nie rozcina identycznych okresów stawek.
- Przed kolejnym UAT obowiązkowo wykonać realny test: pobranie bieżącej bazy → zmiana reprezentatywnych pól → podgląd różnic → zapis → przeładowanie → porównanie wszystkich pól UI i bazy → ponowny import tego samego pliku.
- Bramka wdrożeniowa ma automatycznie sprawdzać obecność i sygnatury wszystkich RPC wywoływanych przez frontend.

## Wynik przygotowania UAT — runda 2 (2026-08-04)

Poniższy status zastępuje wcześniejsze opisy stanu zastanego. Dotyczy wyłącznie
izolowanego projektu UAT `nhthrtpkfpmufmrmdyjg`; produkcja nie została zmieniona.

### Dane Matrixa i import

- Zaimportowano w trybie `REPLACE` dokładnie 76 pracowników z przekazanego pliku.
- Wszystkie 76 profili mają umowę `ZLECENIE`; wszystkie mają aktywną stawkę
  obejmującą miesiąc grafiku.
- Import tego samego pliku wykonano ponownie: nie utworzył duplikatów i nie
  naruszył ograniczeń lokalizacji.
- Weronika Dąbrowska jest zapisana jako GP-111 ze stawką 25,00 zł i umową
  `ZLECENIE`, zgodnie z arkuszem.
- 28 błędnie sklasyfikowanych pór zmian zostało poprawionych, a walidacja
  publikacji Matrixa nie zgłasza już blokady klasyfikacji.
- Matrix v5 jest aktywny od 2026-08-04; Matrix v6 jest roboczą kopią do dalszych
  prób użytkowniczki.

### Kontrakt silnika

- Końcowy builder snapshotu ponownie dodaje `workTimePolicy`, obowiązującą
  stawkę okresową i kontrakt.
- Dla `ZLECENIE`/`B2B` z polityką domyślną wartości `0` oznaczają brak twardego
  limitu miesięcznego/tygodniowego oraz brak narzuconego odpoczynku kodeksowego.
- Walidator bazy stosuje tę samą semantykę co worker. Zakaz nakładania zmian,
  twarda niedostępność, rola, lokal i kompetencje nadal pozostają twarde.
- Test definicji końcowego kontraktu snapshotu i walidatora przeszedł w UAT.

### Rzeczywiste przebiegi OR-Tools na Matrixie v5

- PREP: `READY`, pierwsza próba, 93 s, 3 warianty, 150 przydziałów na wariant,
  0 braków i 0 naruszeń twardych.
- Firma: `READY`, pierwsza próba, 195 s, 3 warianty, 1362 przydziały na wariant,
  0 braków i 0 naruszeń twardych.
- Każdy z trzech wariantów w obu przebiegach ma inny `solutionHash`.
- W firmie „Minimalny koszt” kosztuje 332 786,00 zł, „Zbalansowany”
  334 914,00 zł, a „Preferencje i równy podział” 335 364,00 zł.
- Różnice obciążenia są również realne: odpowiednio 10 980, 3 600 i 2 940 minut.

### Publikacja i stand-by

- Transakcyjnie potwierdzono, że opublikowana rola blokuje późniejszą publikację
  firmową kodem `COMPANY_PUBLICATION_CONFLICTS_WITH_PUBLISHED_ROLES`.
- Transakcyjnie potwierdzono odwrotną kolejność: opublikowana firma blokuje rolę
  kodem `ROLE_PUBLICATION_CONFLICTS_WITH_COMPANY_SCHEDULE`.
- Żaden test konfliktu nie pozostawił zmian; wcześniejsza publikacja Pizzabar
  nadal jest jedyną aktywną publikacją roli, a publikacji firmowej brak.
- Próbna publikacja PREP przeszła pełną rewalidację i utworzyła 60 pozycji
  stand-by: 30 Tier 1 i 30 Tier 2, po dwie osoby na każdy z 30 dni. Całość
  została wycofana po asercjach.

### Bramka techniczna

- Lint, testy importu, 79 testów solvera wraz z 26 podtestami oraz produkcyjny
  build przechodzą lokalnie.
- Automatyczne desktopowe UI E2E pozostaje zablokowane przez ochronę SSO
  podglądu Vercel. Nie wolno oznaczyć kontroli UI jako wykonanej automatycznie;
  ta część jest jawnie przekazana użytkowniczce jako manualny UAT.
