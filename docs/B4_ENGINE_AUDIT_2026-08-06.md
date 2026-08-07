# GRAFIK PRO — audyt silnika i decyzja B4

Data audytu: 2026-08-06  
Zakres: gałąź `agent/uat-matrix-role-portal-overhaul`, wyłącznie Supabase UAT `nhthrtpkfpmufmrmdyjg`  
Werdykt bieżący: **B4 NIEZALICZONY — poprawki wymagają ponownego wdrożenia i pełnego E2E w Chrome**

## Najważniejszy wniosek

Model CP-SAT stawia minimalizację nieobsadzonych miejsc przed celami kosztowymi i preferencjami, ale reguła rezerwy stand-by naruszała tę zasadę. Przy czterech kwalifikujących się osobach, trzech wymaganych miejscach i dwóch oczekiwanych osobach rezerwowych silnik pozostawiał wakat. Nawet warunek liczony osobno dla roli mógł zabrać osobę potrzebną tego dnia innej roli. Dlatego stand-by został całkowicie usunięty z twardych ograniczeń CP-SAT i jest dobierany dopiero po wyborze globalnie najlepszego grafiku. Dodatkowo publikacja nie wymaga już sztywno pełnej liczby poziomów rezerwy.

## Audyt reguł twardych

| Obszar | Model CP-SAT | Walidacja wyniku | Operacyjna aktywacja rezerwy | Status po poprawce |
|---|---|---|---|---|
| Wymagana obsada | cel globalny `UNFILLED`, rozstrzygany i zamrażany przed strategiami | zgodność liczby przydziałów i wakatów | nie dotyczy | zgodne; rezerwa nie może tworzyć wakatu |
| Konfigurowalny limit zmian jednego pracownika na dobę | ograniczenie `<= maximumShiftsPerDay` pobrane z opublikowanej konfiguracji firmy | test wartości 1 i 2 | CP-SAT, tryb awaryjny, walidator wariantu i diagnostyka ręcznych przydziałów czytają tę samą wartość; nakładanie i odpoczynek pozostają niezależnymi regułami twardymi | poprawiono po findingu UAT: usunięto stałe `1` |
| Nakładanie zmian i odpoczynek | uwzględnia zmiany z przebiegu i zewnętrzne/opublikowane | ponowna kontrola sekwencji | ponowna kontrola aktualnego grafiku i aktywnych zastępstw | zgodne w kodzie; wymaga E2E |
| Rola, lokal i kompetencje | kandydat jest tworzony tylko dla dozwolonego przydziału | ponowna kontrola | ponowna kontrola roli, lokalu i obowiązków docelowego przydziału | zgodne w kodzie; wymaga E2E |
| Niedostępność, urlop i L4 | blokady zakresów godzinowych | ponowna kontrola | ponowna kontrola w chwili aktywacji | zgodne w kodzie; wymaga E2E |
| Jawne okna dostępności | wymagane, gdy konfiguracja nie dopuszcza braku deklaracji | ponowna kontrola | ponowna kontrola pełnego zakresu zmiany | zgodne w kodzie; wymaga E2E |
| Okres zatrudnienia i weekendy | blokady dat oraz indywidualnego zakazu weekendów | ponowna kontrola | ponowna kontrola | zgodne w kodzie; wymaga E2E |
| Starsze ograniczenia godzinowe | wewnętrzne progi godzin początku/końca są respektowane bez pokazywania użytkownikowi kategorii pory dnia | ponowna kontrola | ponowna kontrola starszych flag przy dokładnej zmianie | zgodne w kodzie; migracja danych do dokładnych godzin pozostaje otwarta |
| Limity tygodniowe i miesięczne | limity indywidualne; umowy elastyczne bez własnej polityki nie otrzymują automatycznie limitów pracowniczych | ponowna kontrola | ponowna kontrola z aktywnymi zastępstwami | zgodne w kodzie; wymaga E2E |
| Kolejne dni pracy | indywidualny limit, także na granicy okresu | ponowna kontrola | ponowna kontrola serii przed i po dniu zastępstwa | zgodne w kodzie; wymaga E2E |
| Koszt, dodatki i twardy budżet | wycena każdego przydziału i ograniczenie budżetu | ponowne wyliczenie wybranego wariantu | nie zmienia historycznego wariantu; zastępstwo jest audytowane | zgodne; pełny test zależy od uzupełnienia stawek |

## Audyt optymalizacji i porównania wariantów

1. Pokrycie obsady jest globalnym priorytetem przed wszystkimi strategiami biznesowymi.
2. Priorytety strategii są rozwiązywane leksykograficznie: poziom 1 jest zamrażany przed poziomem 2, a poziom 2 przed poziomem 3. W ramach jednego poziomu działa ważona suma z normalizacją zakresów.
3. Dotychczasowa „rozpiętość obciążenia” porównywała surowe minuty osób o potencjalnie różnych wymiarach. To faworyzowało błędny rodzaj równości. Nowy model porównuje procent wykorzystania indywidualnego miesięcznego wymiaru, a w drugiej kolejności indywidualnego limitu.
4. Osoby bez wymiaru ani limitu nie są traktowane jak pracownicy z celem równym zero. Interfejs pokazuje „Brak danych”, zamiast sugerować idealny wynik 0.
5. W opublikowanej konfiguracji UAT v5 żadna z 76 aktywnych osób nie ma miesięcznego wymiaru ani maksymalnego limitu. To aktywna luka danych, którą należy uzupełnić przed miarodajnym UAT równego podziału i nadgodzin.
6. `requireOptimal=false` dopuszcza wynik `FEASIBLE`: poprawny i najlepszy znaleziony w limicie, ale bez dowodu globalnego optimum. Interfejs nie nazywa go już bezwarunkowo „rekomendowanym”; pokazuje „Najlepszy znaleziony” i wyjaśnia brak dowodu. Gwarantowane optimum wymaga opublikowania konfiguracji z opcją „Czekaj na matematycznie najlepszy wynik”.
7. Kryterium `HOME_LOCATION_VIOLATIONS` było stałą równą zero po wycofaniu pojęcia lokalu macierzystego. Jest ukryte w prezentacji i nie może być interpretowane jako realny wskaźnik jakości. Usunięcie historycznych wierszy celu z konfiguracji pozostaje osobnym porządkiem danych.

## Ustalenia produktowe B4

- Generator czyta wyłącznie opublikowaną konfigurację. Zmiana „Runner Help” była w wersji roboczej v6, a przebieg korzystał z opublikowanej v5. Interfejs pokazuje teraz jawne ostrzeżenie z numerami obu wersji przed generowaniem.
- Profil zapotrzebowania działa na cały miesiąc. Jednodniowy event należy dodać w kalendarzu operacyjnym dla dokładnej daty, lokalu, zmiany i roli.
- Grafików ról z różnych profili miesiąca nadal nie można bezpiecznie scalić. Projekt wyjątków kalendarzowych jest właściwą drogą; dowolne mieszanie całomiesięcznych profili nie zostało uznane za poprawny model.
- Szczegóły braków są wyżej niż kalendarz, każdy brak ma diagnostykę kandydatów, a w opublikowanym grafiku kwalifikującą się osobę można ponownie sprawdzić i dopisać ręcznie.
- Publikacja i podgląd stand-by korzystają z jawnego znacznika silnika `ORTOOLS_V2`; brak tego pola był przyczyną fałszywego komunikatu o niepotwierdzonym aktywnym obszarze roboczym.

## Dowody techniczne wykonane lokalnie

- testy Node dotyczące ścieżki użytkownika, konfiguracji, profilu pracownika, importu finansów i prezentacji metryk: zaliczone;
- kompilacja składni całego pakietu Python silnika i testów: zaliczona;
- pełny `pytest`, typowanie Next.js i testy przeglądarkowe: oczekują na zależności w CI oraz wdrożenie UAT;
- migracja SQL, aplikacja i worker: nie są w tym dokumencie oznaczone jako wdrożone, dopóki wdrożenie UAT i E2E nie zakończą się dowodem.

## Warunki ponownego zaliczenia B4

1. CI gałęzi przechodzi testy aplikacji, typowanie i pełny `pytest` z OR-Tools.
2. Migracja jest zastosowana tylko w `nhthrtpkfpmufmrmdyjg`.
3. Nowy obraz workera UAT obsługuje poprawkę rezerwy i procentowy wskaźnik obciążenia.
4. W Chrome: podgląd wariantu działa, brak „Pomoc” ma wyjaśnienie, publikacja nie zgłasza fałszywego błędu obszaru roboczego, rezerwa jest widoczna po publikacji i modal nie znika po przełączeniu okna.
5. Import finansów całego zespołu przechodzi podgląd i zapis transakcyjny na UAT.
6. Nowy grafik zawierający „Runner Help” jest generowany dopiero po publikacji wersji konfiguracji, która rzeczywiście zawiera tę zmianę.
7. Excel pozostaje z 101 aktywnymi ID, a B4 ma status „NIEZALICZONY — DO POPRAWY I PONOWNEGO WDROŻENIA” do czasu zakończenia wszystkich powyższych kroków.
