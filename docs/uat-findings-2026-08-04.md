# GRAFIK PRO — znaleziska UAT z 4 sierpnia 2026

## Status dokumentu

- Rejestr znalezisk, wymagań i stanu realizacji zbiorczej poprawki.
- Po poleceniu „DO DZIEŁA” rozpoczęto implementację lokalną. Wcześniejsze zapisy o makietach zachowano niżej jako historię wymagań i kryteria oceny podczas kolejnego UAT.
- Bez wdrożenia, commita, pushu, uruchomienia migracji i zmian danych w Supabase.
- Nie podejmować decyzji produktowych bez akceptacji użytkowniczki.
- Obowiązują wcześniejsze wymagania: całe UI po polsku, techniczne kody niewidoczne, Matrix nie może być długą listą, baza nie może wymyślać danych pracowników.

## Stan realizacji lokalnej

| Obszar | Stan | Zakres poprawki |
| --- | --- | --- |
| Import Matrixa | zaimplementowany, bramka lokalna zaliczona | Eksport aktualnej bazy, tryby „aktualizuj” i „synchronizuj”, podgląd skutków, dopasowanie po stabilnej tożsamości, role, lokale standard/nadgodziny, obowiązki wraz z ich wycofaniem po odznaczeniu, umowa, stawka, daty i ograniczenia pracownika. |
| Integralność pracownika i stawek | zaimplementowana, czeka na pełną bramkę testową | Spójne pola profilu, kontrolowany krok finansowy po dodaniu pracownika, walidacja okresu stawki względem zatrudnienia, kontrola pokrycia całego miesiąca grafiku i poprawna nawigacja z blokady publikacji. |
| Grafik roli | zaimplementowany, czeka na pełną bramkę testową | Poprawiona interpretacja dostępności ZLECENIA/B2B, bezpieczna finalizacja, widoczny wynik odświeżenia, diagnostyka kandydatów i powodów odrzucenia. |
| Portal pracownika | zaimplementowany, bramka lokalna zaliczona | Jeden kalendarz miesiąca, domyślnie zielona dostępność, zaznaczanie zakresów, wyjątki pomarańczowe i czerwone, chronione wpisy pracodawcy/urlopu/L4 tylko do odczytu, opcjonalne godziny/lokal/notatka, zapis bez opuszczania widoku. |
| Role, obowiązki, lokale i zmiany | zaimplementowany roboczo, do oceny w UAT | Pierwszy etap Matrixa, połączone zależności roli i obowiązków, zmiany pogrupowane per lokal zamiast jednej długiej listy. |
| Wymagana obsada | zaimplementowana roboczo, do oceny w UAT | Kompaktowy widok, wybór wielu zmian, język biznesowy operacji, edycja zbiorcza i usunięcie mylącego obowiązku „Dowolny”. |
| Strategie i warianty | zaimplementowane roboczo, do oceny w UAT | Porównanie rzeczywistych priorytetów strategii oraz wyjaśnienie, dlaczego różne strategie mogą zwrócić ten sam skład. |
| Historia Matrixa i audit trail | zaimplementowane roboczo, czeka na pełną bramkę testową | Lista wersji, podgląd, porównanie i historia zmian bez nadpisywania wcześniejszych wersji. |
| Klasyfikacja pór zmian | naprawa kontrolowana, czeka na uruchomienie migracji | Automatyczna normalizacja tylko jednoznacznych nazw/kodów oraz blokada publikacji przy nierozstrzygniętej niezgodności. |

Po przejściu testów lokalnych paczka może zostać przedstawiona do wdrożenia na osobne środowisko UAT. Samo wdrożenie pozostaje poza zakresem tej sesji i wymaga osobnego polecenia.

## Bramka jakości wykonana lokalnie

- produkcyjny build Next.js: zaliczony,
- kontrola typów TypeScript: zaliczona,
- silnik OR-Tools i worker: 75/75 testów zaliczonych,
- kontrakt gatewaya: 10/10 testów zaliczonych,
- parser importu Matrixa: 5/5 testów zaliczonych,
- rzeczywisty plik `matrix-alpha16-szablon (1).xlsx`: odczytano 76 pracowników i 62 kompetencje; rekord Weroniki Dąbrowskiej zachował e-mail, rolę BARMAN, lokale Krucza i Pawilony, datę rozpoczęcia, ZLECENIE i stawkę 25 zł,
- migracja: poprawna składniowo dla PostgreSQL, 46 instrukcji,
- kontrola białych znaków i konfliktów patcha: zaliczona.

Migracja nie została uruchomiona na Supabase, a kod nie został wypchnięty ani wdrożony. Dlatego nadal wymagany jest test integracyjny wszystkich RPC i pełny smoke test na osobnym wdrożeniu UAT po udzieleniu osobnego polecenia na publikację.

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
