export type WorkbookFieldStatus = "WYMAGANE" | "OPCJONALNE" | "WARUNKOWE" | "SYSTEM";

export type WorkbookFieldDefinition = {
  status: WorkbookFieldStatus;
  purpose: string;
  input: string;
  allowed: string;
  example: string;
  effect: string;
  blank: string;
  application: string;
};

export type WorkbookSheetDefinition = {
  purpose: string;
  when: string;
  headers: readonly string[];
  fields: Record<string, WorkbookFieldDefinition>;
};

const required=(input:string,allowed:string,example:string,effect:string,application:string):WorkbookFieldDefinition=>({
  status:"WYMAGANE",purpose:effect,input,allowed,example,effect,blank:"Wiersz nie przejdzie podglądu importu.",application,
});
const optional=(purpose:string,input:string,allowedOrExample:string,exampleOrEffect:string,effectOrBlank:string,blankOrApplication:string,applicationMaybe?:string):WorkbookFieldDefinition=>({
  status:"OPCJONALNE",purpose,input,allowed:applicationMaybe?allowedOrExample:input,example:applicationMaybe?exampleOrEffect:allowedOrExample,
  effect:applicationMaybe?effectOrBlank:exampleOrEffect,blank:applicationMaybe?blankOrApplication:effectOrBlank,application:applicationMaybe??blankOrApplication,
});
const conditional=(purpose:string,input:string,allowedOrExample:string,exampleOrEffect:string,effectOrBlank:string,blankOrApplication:string,applicationMaybe?:string):WorkbookFieldDefinition=>({
  status:"WARUNKOWE",purpose,input,allowed:applicationMaybe?allowedOrExample:input,example:applicationMaybe?exampleOrEffect:allowedOrExample,
  effect:applicationMaybe?effectOrBlank:exampleOrEffect,blank:applicationMaybe?blankOrApplication:effectOrBlank,application:applicationMaybe??blankOrApplication,
});
const system=(purpose:string,example:string,application:string):WorkbookFieldDefinition=>({
  status:"SYSTEM",purpose,input:"Nie wpisuj dla nowego rekordu. Przy aktualizacji zachowaj wartość pobraną z aplikacji.",allowed:"Wartość nadawana przez SZAFUNEK.",example,effect:"Pozwala bezpiecznie zaktualizować ten sam rekord zamiast tworzyć duplikat.",blank:"Dla nowego rekordu system utworzy identyfikator automatycznie.",application,
});

export const QUICK_WORKBOOK_SHEETS:Record<string,WorkbookSheetDefinition>={
  "Firma":{
    purpose:"Ustawienia wspólne dla firmy, które bezpośrednio ograniczają generowanie grafików.",
    when:"Uzupełnij raz przy pierwszej konfiguracji; później zmieniaj tylko świadomie.",
    headers:["Waluta","Strefa czasowa","Minimalny odpoczynek (godz.)","Maks. zmian jednego pracownika na dobę","Brak wpisanej dostępności oznacza dostępność"],
    fields:{
      "Waluta":required("Trzyliterowy kod waluty.","PLN, EUR, USD lub inny poprawny kod ISO 4217.","PLN","Ustala walutę kosztów i stawek w całej firmie.","Ustawienia firmy, koszty grafiku i finanse."),
      "Strefa czasowa":required("Nazwa strefy czasowej IANA.","Np. Europe/Warsaw.","Europe/Warsaw","Ustala poprawne daty, godziny, zmianę doby i odpoczynek.","Cała aplikacja i generator."),
      "Minimalny odpoczynek (godz.)":required("Liczba godzin odpoczynku między zmianami.","Liczba od 0 do 168; standardowo 11.","11","Blokuje przydziały naruszające minimalny odpoczynek.","Generator i kontrola gotowości."),
      "Maks. zmian jednego pracownika na dobę":required("Maksymalna liczba niepokrywających się zmian jednej osoby w dobie.","Liczba całkowita od 1 do 24; standardowo 1.","1","Ogranicza liczbę przydziałów jednej osoby tego samego dnia.","Generator i kontrola gotowości."),
      "Brak wpisanej dostępności oznacza dostępność":required("Wybór zasady dla osoby bez wpisanego kalendarza dostępności.","☑ Tak albo ☐ Nie.","☑ Tak","Tak pozwala planować osobę bez deklaracji; Nie wymaga jawnego okna dostępności.","Generator i portal pracownika."),
    },
  },
  "Kategorie grafików":{
    purpose:"Łączą role, które generator ma planować i oceniać razem, np. BAR albo SALA.",
    when:"Uzupełnij przed rolami. Każda aktywna rola musi należeć do jednej kategorii.",
    headers:["Kod","Nazwa","Opis","Kolor","Aktywna"],
    fields:{
      "Kod":system("Stały identyfikator kategorii używany przy aktualizacji i integracjach.","BAR","Konfiguracja kategorii."),
      "Nazwa":required("Czytelna nazwa kategorii.","Tekst do 160 znaków.","Bar","Tworzy kategorię generowaną jako jeden zespół.","Ustawienia i generator grafiku."),
      "Opis":optional("Wyjaśnia, jakie role są planowane razem.","Krótki tekst.","Obsada baru i zaplecza barowego","Pomaga administratorom prawidłowo przypisywać role.","Brak nie zmienia działania generatora.","Ustawienia firmy."),
      "Kolor":optional("Stały kolor kategorii w interfejsie.","Wybierz z listy.","Fioletowy — #7257D8","Ułatwia rozpoznawanie kategorii.","System użyje koloru domyślnego.","Grafik i ustawienia."),
      "Aktywna":required("Czy kategoria bierze udział w bieżącej konfiguracji.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywna kategoria jest dostępna w generatorze.","Ustawienia i generator."),
    },
  },
  "Role":{
    purpose:"Definiują stanowiska wymagane w obsadzie, np. Barman, Kelner albo Host.",
    when:"Uzupełnij po kategoriach i przed pracownikami oraz obsadą.",
    headers:["Kod","Nazwa","Kategoria grafiku","Kolor","Aktywna"],
    fields:{
      "Kod":system("Stały identyfikator roli używany przy aktualizacji i integracjach.","BARMAN","Konfiguracja ról."),
      "Nazwa":required("Nazwa stanowiska widoczna użytkownikom.","Tekst do 160 znaków.","Barman","Tworzy rolę, do której można przypisać pracowników i zapotrzebowanie.","Zespół, grafik i generator."),
      "Kategoria grafiku":required("Kategoria, w której rola jest generowana razem z innymi rolami.","Wybierz z listy nazwę kategorii.","Bar [BAR]","Ustala wspólny zakres generowania i oceny grafiku.","Generator kategorii."),
      "Kolor":optional("Stały kolor roli.","Wybierz z listy.","Turkusowy — #0F8F7A","Ułatwia rozpoznawanie roli w grafiku.","System użyje koloru domyślnego.","Grafik, zespół i ustawienia."),
      "Aktywna":required("Czy rola może być używana w bieżącej konfiguracji.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywna rola może otrzymać obsadę i pracowników.","Generator i ustawienia."),
    },
  },
  "Lokale":{
    purpose:"Definiują miejsca pracy, dla których powstają zmiany i grafiki.",
    when:"Uzupełnij przed zmianami i przypisaniem pracowników.",
    headers:["Kod","Nazwa","Strefa czasowa","Aktywna"],
    fields:{
      "Kod":system("Stały identyfikator lokalu używany przy aktualizacji i integracjach.","KRUCZA","Konfiguracja lokali."),
      "Nazwa":required("Nazwa lokalu widoczna użytkownikom.","Tekst do 160 znaków.","Krucza","Tworzy miejsce pracy dla zmian, obsady i pracowników.","Grafik, zespół i ustawienia."),
      "Strefa czasowa":required("Strefa czasowa lokalu.","Nazwa IANA, np. Europe/Warsaw.","Europe/Warsaw","Zapewnia poprawne daty, godziny i odpoczynek w tym lokalu.","Generator i kalendarze."),
      "Aktywna":required("Czy lokal bierze udział w bieżącej konfiguracji.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywny lokal może mieć zmiany, obsadę i pracowników.","Generator i ustawienia."),
    },
  },
  "Obowiązki":{
    purpose:"Opcjonalne umiejętności lub zadania wewnątrz roli, gdy sama rola nie wystarcza do opisania wymogu.",
    when:"Wypełnij tylko, jeśli w ramach jednej roli nie każda osoba potrafi wykonać dane zadanie. W przeciwnym razie pozostaw arkusz pusty.",
    headers:["Kod","Nazwa","Opis","Kolor","Aktywna"],
    fields:{
      "Kod":system("Stały identyfikator obowiązku używany przy aktualizacji i integracjach.","KASA","Konfiguracja obowiązków."),
      "Nazwa":required("Nazwa konkretnej umiejętności lub zadania.","Tekst do 160 znaków.","Obsługa kasy","Pozwala wymagać tej kompetencji w obsadzie i przypisać ją wybranym osobom.","Obsada, zespół i generator."),
      "Opis":optional("Wyjaśnia, kiedy kompetencja jest potrzebna.","Krótki tekst.","Samodzielna obsługa kasy i zamknięcie dnia","Pomaga odróżnić podobne obowiązki.","Brak nie zmienia działania generatora.","Ustawienia firmy."),
      "Kolor":optional("Subtelny kolor obowiązku.","Wybierz z listy.","Złoty — #C9A51D","Ułatwia rozpoznawanie obowiązku.","System użyje koloru domyślnego.","Grafik i ustawienia."),
      "Aktywna":required("Czy obowiązek może być używany.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywny obowiązek można przypisać do osoby i obsady.","Generator i ustawienia."),
    },
  },
  "Pracownicy":{
    purpose:"Jedno źródło danych planistycznych pracownika: tożsamość, role, lokale, kompetencje, umowa, cel godzinowy i ograniczenia.",
    when:"Każdy aktywny pracownik zajmuje jeden wiersz. Stawki uzupełnia się później w osobnym pliku finansowym.",
    headers:["Numer pracownika","Aktywny","Imię","Nazwisko","E-mail","Rola podstawowa","Rola dodatkowa 1","Rola dodatkowa 2","Rola dodatkowa 3","Lokal pracy 1","Lokal pracy 2","Lokal pracy 3","Kompetencja dodatkowa 1","Kompetencja dodatkowa 2","Kompetencja dodatkowa 3","Etap zatrudnienia","Koniec okresu próbnego","Zatrudniony od","Zatrudniony do","Miesięczny cel godzin","Twardy limit miesięczny godzin","Limit tygodniowy godzin","Maks. kolejnych dni","Minimalny odpoczynek godzin","Bez weekendów","Rodzaj umowy","Zgoda na nadgodziny"],
    fields:{
      "Numer pracownika":system("Niepowtarzalny numer osoby.","GP-067","Zespół i historia zatrudnienia."),
      "Aktywny":required("Czy osoba może być planowana.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywna osoba jest brana pod uwagę przez generator.","Zespół i generator."),
      "Imię":required("Imię osoby bez nazwiska.","Tekst.","Anna","Buduje czytelną tożsamość pracownika.","Zespół, grafik i portal pracownika."),
      "Nazwisko":required("Nazwisko osoby bez imienia.","Tekst.","Nowak","Buduje czytelną tożsamość pracownika.","Zespół, grafik i portal pracownika."),
      "E-mail":optional("Adres używany do bezpiecznego rozpoznania istniejącej osoby i ewentualnego konta.","Poprawny adres e-mail.","anna.nowak@firma.pl","Łączy import z istniejącą historią osoby.","Nowa osoba może zostać utworzona bez konta; późniejsze podpięcie wymaga numeru lub e-maila.","Zespół i dostęp do aplikacji."),
      "Rola podstawowa":required("Stanowisko, w którym pracownik powinien otrzymywać zmiany w pierwszej kolejności.","Wybierz jedną rolę z listy.","Kelner [KELNER]","Generator najpierw wykorzystuje pracownika w tej roli.","Zespół i generator."),
      "Etap zatrudnienia":required("Bieżący etap współpracy.","Stała współpraca, Okres próbny albo Okres wypowiedzenia.","Okres próbny","Zachowuje prawidłowy etap zatrudnienia bez cichej zamiany na stałą współpracę.","Zespół i kontrola publikacji."),
      "Koniec okresu próbnego":conditional("Data końca okresu próbnego.","Data RRRR-MM-DD.","2026-09-30","Określa koniec etapu próbnego.","Może pozostać puste tylko poza etapem Okres próbny; przy okresie próbnym brak jest błędem.","Zespół."),
      "Zatrudniony od":required("Pierwszy dzień współpracy.","Data RRRR-MM-DD.","2026-08-01","Blokuje planowanie przed rozpoczęciem zatrudnienia.","Generator i zespół."),
      "Zatrudniony do":optional("Ostatni dzień współpracy, jeśli jest znany.","Data RRRR-MM-DD późniejsza lub równa dacie początku.","2026-12-31","Blokuje planowanie po zakończeniu zatrudnienia.","Współpraca jest bezterminowa.","Generator i zespół."),
      "Miesięczny cel godzin":required("Indywidualny cel godzin służący do proporcjonalnie równego podziału pracy.","Liczba godzin od 0 wzwyż.","180","Generator porównuje procent realizacji celu między pracownikami.","Generator i analiza obciążenia."),
      "Twardy limit miesięczny godzin":required("Maksymalna liczba godzin, której generator nie może przekroczyć bez dozwolonych nadgodzin.","Liczba godzin nie mniejsza od celu.","220","Chroni miesięczny limit pracy.","Generator i kontrola gotowości."),
      "Limit tygodniowy godzin":required("Maksymalna liczba godzin w tygodniu.","Liczba godzin większa od 0.","48","Chroni tygodniowy limit pracy.","Generator i kontrola gotowości."),
      "Maks. kolejnych dni":required("Maksymalna liczba kolejnych dni z pracą.","Liczba całkowita większa od 0.","6","Blokuje zbyt długie serie dni roboczych.","Generator."),
      "Minimalny odpoczynek godzin":optional("Indywidualnie dłuższy odpoczynek niż ustawienie firmy.","Liczba godzin; pozostaw puste, aby użyć ustawienia firmy.","12","Zaostrza minimalny odpoczynek tej osoby.","Używane jest ustawienie firmy.","Generator."),
      "Bez weekendów":optional("Stała blokada pracy w soboty i niedziele.","☑ Tak albo ☐ Nie.","☐ Nie","Tak wyklucza weekendowe przydziały.","Puste oznacza Nie.","Generator i zespół."),
      "Rodzaj umowy":required("Forma współpracy używana przez reguły czasu pracy i płac.","Wybierz z listy.","Umowa o pracę","Dobiera właściwe reguły zatrudnienia; stawka nadal jest uzupełniana osobno.","Zespół, finanse i generator."),
      "Zgoda na nadgodziny":required("Najwyższy dozwolony poziom użycia nadgodzin.","NIE, TYLKO PO ZATWIERDZENIU albo TAK.","TYLKO PO ZATWIERDZENIU","Generator najpierw unika nadgodzin; jeśli są konieczne, stosuje zgodę lub tworzy decyzję lidera.","Generator, lider i analiza kosztów."),
    },
  },
  "Zmiany":{
    purpose:"Definiują powtarzalne godziny pracy w konkretnym lokalu.",
    when:"Uzupełnij po lokalach, przed obsadą.",
    headers:["Kod","Nazwa","Lokal","Od","Do","Kończy się następnego dnia","Dni tygodnia","Aktywna"],
    fields:{
      "Kod":system("Stały identyfikator zmiany używany przy aktualizacji.","KRUCZA_WIECZOR","Konfiguracja zmian."),
      "Nazwa":required("Czytelna nazwa zmiany.","Tekst do 160 znaków.","Wieczór","Tworzy zmianę dostępną w obsadzie.","Grafik i ustawienia."),
      "Lokal":required("Miejsce wykonywania zmiany.","Wybierz jeden lokal z listy.","Krucza [KRUCZA]","Przypisuje zmianę do lokalu.","Grafik, obsada i generator."),
      "Od":required("Godzina rozpoczęcia.","HH:MM w formacie 24-godzinnym.","18:00","Ustala początek przydziału.","Grafik i generator."),
      "Do":required("Godzina zakończenia.","HH:MM w formacie 24-godzinnym.","03:00","Ustala koniec przydziału.","Grafik i generator."),
      "Kończy się następnego dnia":required("Czy godzina zakończenia przypada następnego dnia kalendarzowego.","☑ Tak albo ☐ Nie.","☑ Tak","Zapewnia poprawny czas nocnej zmiany.","Grafik, koszty i odpoczynek."),
      "Dni tygodnia":required("Dni, w które zmiana powtarza się co tydzień.","Numery 1–7 rozdzielone przecinkami: 1=poniedziałek, 7=niedziela.","1,2,3,4,5","Tworzy wystąpienia zmiany we wskazane dni.","Generator i ustawienia."),
      "Aktywna":required("Czy zmiana jest używana.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywna zmiana może otrzymać obsadę.","Generator i ustawienia."),
    },
  },
  "Obsada":{
    purpose:"Określa, ile osób w danej roli potrzeba na konkretnej zmianie. Pole obowiązku zawęża wymóg do kompetencji.",
    when:"Uzupełnij po rolach i zmianach. Każdy wiersz oznacza jeden wymóg obsady.",
    headers:["Zmiana","Rola","Obowiązek (opcjonalnie)","Liczba osób","Aktywna"],
    fields:{
      "Zmiana":required("Zmiana, której dotyczy wymóg.","Wybierz z listy.","Wieczór [KRUCZA_WIECZOR]","Łączy wymóg z konkretnymi godzinami i lokalem.","Obsada i generator."),
      "Rola":required("Rola wymagana na zmianie.","Wybierz z listy.","Barman [BARMAN]","Generator szuka osób z tą rolą podstawową, a dopiero potem z rolą dodatkową.","Obsada i generator."),
      "Obowiązek (opcjonalnie)":optional("Dodatkowa kompetencja wymagana w ramach roli.","Wybierz z listy obowiązków.","Obsługa kasy [KASA]","Zawęża kandydatów do osób z tą kompetencją.","Wystarcza sama rola.","Obsada i generator."),
      "Liczba osób":required("Docelowa liczba osób dla tej zmiany i roli.","Liczba całkowita co najmniej 1.","2","Tworzy dokładnie tyle miejsc do obsadzenia.","Obsada, generator i analiza braków."),
      "Aktywna":required("Czy wymóg jest używany.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywny wiersz tworzy zapotrzebowanie.","Generator i ustawienia."),
    },
  },
  "Grupy rezerwy":{
    purpose:"Definiują wspólną pulę gotowości dla wybranych ról w jednej kategorii. Role pominięte nie trafiają do rezerwy.",
    when:"Wypełnij tylko, jeśli firma używa rezerwy. Najpierw zapewniana jest wymagana obsada; rezerwa nie może zabierać osoby potrzebnej do pokrycia braku.",
    headers:["Kod","Nazwa","Kategoria grafiku","Role obsługiwane wspólnie","Poziomy rezerwy"],
    fields:{
      "Kod":system("Stały identyfikator grupy rezerwy.","BAR_CORE","Konfiguracja rezerwy."),
      "Nazwa":required("Czytelna nazwa grupy.","Tekst do 160 znaków.","Główna rezerwa baru","Tworzy oddzielną zasadę gotowości.","Rezerwa i ustawienia."),
      "Kategoria grafiku":required("Kategoria, do której należą wszystkie role grupy.","Wybierz z listy.","Bar [BAR]","Ogranicza grupę do jednej kategorii.","Rezerwa i generator."),
      "Role obsługiwane wspólnie":required("Role, które jedna pula rezerwy może zabezpieczać wspólnie.","Wpisz wybrane role z arkusza Role, rozdzielone przecinkami.","Barman [BARMAN], Bar Kierownik [BAR_KIEROWNIK]","Tylko wskazane role biorą udział w tej rezerwie.","Rezerwa i generator."),
      "Poziomy rezerwy":required("Liczba kolejnych osób gotowości na dzień.","1 albo 2.","2","Tworzy Rezerwę 1 albo Rezerwę 1 i 2.","Rezerwa przed publikacją."),
    },
  },
  "Pula ad-hoc":{
    purpose:"Lista osób awaryjnych proponowanych dopiero do naprawy braków; nie są automatycznie planowane w zwykłym grafiku.",
    when:"Wypełnij tylko, jeśli chcesz korzystać z awaryjnego uzupełniania obsady.",
    headers:["Imię","Nazwisko","E-mail","Telefon","Rola","Rodzaj współpracy","Stawka godzinowa","Waluta","Dostępny od","Dostępny do","Notatki","Aktywna"],
    fields:{
      "Imię":required("Imię osoby awaryjnej.","Tekst.","Jan","Tworzy czytelną tożsamość osoby ad-hoc.","Pula ad-hoc i naprawa braków."),
      "Nazwisko":required("Nazwisko osoby awaryjnej.","Tekst.","Kowalski","Tworzy czytelną tożsamość osoby ad-hoc.","Pula ad-hoc i naprawa braków."),
      "E-mail":optional("Adres kontaktowy.","Poprawny adres e-mail.","jan@example.com","Ułatwia kontakt i rozpoznanie osoby.","Telefon pozostaje podstawowym wymaganym kontaktem.","Pula ad-hoc."),
      "Telefon":required("Numer kontaktowy osoby awaryjnej.","Numer z kodem kraju lub krajowy numer telefonu.","+48 500 600 700","Pozwala liderowi skontaktować się przy naprawie braku.","Pula ad-hoc i operacje."),
      "Rola":required("Rola, w której osoba może awaryjnie pracować.","Wybierz z listy.","Barman [BARMAN]","Osoba jest proponowana tylko dla braków tej roli.","Naprawa braków."),
      "Rodzaj współpracy":required("Forma współpracy osoby ad-hoc.","Wybierz z listy.","Umowa zlecenie","Dobiera właściwe zasady kosztowe.","Finanse i naprawa braków."),
      "Stawka godzinowa":conditional("Podstawowa stawka godzinowa osoby ad-hoc.","Kwota większa lub równa 0.","45,00","Pozwala policzyć koszt proponowanego przydziału.","Bez stawki system nie może wiarygodnie porównać kosztu.","Koszty i naprawa braków."),
      "Waluta":conditional("Waluta stawki.","Trzyliterowy kod zgodny z walutą firmy.","PLN","Zapewnia poprawne obliczenie kosztu.","Używana jest waluta firmy, jeśli kontrakt importu na to pozwala.","Koszty."),
      "Dostępny od":optional("Pierwszy dzień dostępności osoby.","Data RRRR-MM-DD.","2026-08-01","Ogranicza propozycje do właściwego okresu.","Brak początku okresu.","Naprawa braków."),
      "Dostępny do":optional("Ostatni dzień dostępności osoby.","Data RRRR-MM-DD.","2026-08-31","Ogranicza propozycje do właściwego okresu.","Brak końca okresu.","Naprawa braków."),
      "Notatki":optional("Informacja pomocnicza dla lidera.","Krótki tekst.","Dostępny po 17:00","Ułatwia podjęcie decyzji.","Brak nie zmienia logiki generatora.","Pula ad-hoc."),
      "Aktywna":required("Czy osoba może być proponowana.","☑ Tak albo ☐ Nie.","☑ Tak","Aktywna osoba pojawia się w propozycjach naprawy braków.","Naprawa braków."),
    },
  },
};

for(const index of [1,2,3]){
  QUICK_WORKBOOK_SHEETS.Pracownicy.fields[`Rola dodatkowa ${index}`]=optional(
    "Dodatkowa rola używana wyłącznie awaryjnie, po wyczerpaniu dostępnych osób z tą rolą podstawową.",
    "Wybierz inną rolę z listy; kolejność kolumn 1–3 oznacza kolejność awaryjnego użycia.",
    "Jedna rola z arkusza Role.",
    index===1?"Host [HOST]":index===2?"Runner [RUNNER]":"Barback [BARBACK]",
    "Generator może użyć tej roli dopiero jako zastępstwa; nigdy nie traktuje jej jak roli podstawowej.",
    "Pracownik nie jest kandydatem awaryjnym do tej dodatkowej roli.",
    "Zespół, generator i wyjaśnienia przydziałów.",
  );
  QUICK_WORKBOOK_SHEETS.Pracownicy.fields[`Lokal pracy ${index}`]=index===1
    ? required("Lokal, w którym osoba może pracować.","Wybierz lokal z listy; kolejne kolumny służą dodatkowym lokalom.","Krucza [KRUCZA]","Pozwala planować osobę w tym lokalu.","Zespół i generator.")
    : optional("Dodatkowy lokal, w którym osoba może pracować.","Wybierz lokal z listy.","Jeden lokal z arkusza Lokale.","Mokotów [MOKOTOW]","Rozszerza miejsca, w których osoba może być planowana.","Osoba pozostaje dostępna tylko w wcześniej wskazanych lokalach.","Zespół i generator.");
  QUICK_WORKBOOK_SHEETS.Pracownicy.fields[`Kompetencja dodatkowa ${index}`]=optional(
    "Opcjonalna umiejętność potrzebna tylko przy obsadzie zawężonej obowiązkiem.",
    "Wybierz obowiązek z listy.",
    "Jeden obowiązek z arkusza Obowiązki.",
    index===1?"Obsługa kasy [KASA]":index===2?"Zamknięcie lokalu [ZAMKNIECIE]":"Prawo jazdy [PRAWO_JAZDY]",
    "Pozwala obsadzić osobę w miejscu wymagającym tej kompetencji.",
    "Pracownik nadal może wykonywać zwykłe zmiany swojej roli.",
    "Zespół, obsada i generator.",
  );
}

export const QUICK_WORKBOOK_SHEET_ORDER=[
  "Instrukcja","Firma","Kategorie grafików","Role","Lokale","Obowiązki","Pracownicy","Zmiany","Obsada","Grupy rezerwy","Pula ad-hoc","Opis pól","_LISTY",
] as const;

export function referenceLabel(name:string|undefined|null,code:string|undefined|null){
  const safeName=String(name??"").trim(),safeCode=String(code??"").trim();
  return safeName&&safeCode?`${safeName} [${safeCode}]`:safeCode||safeName;
}

export function quickWorkbookContractErrors(sheetHeaders:Record<string,string[]>){
  const errors:string[]=[];
  for(const [sheet,definition] of Object.entries(QUICK_WORKBOOK_SHEETS)){
    const actual=sheetHeaders[sheet];
    if(!actual){errors.push(`Brak zakładki ${sheet}`);continue;}
    if(actual.join("|")!==definition.headers.join("|"))errors.push(`${sheet}: niezgodne kolumny`);
    for(const field of definition.headers)if(!definition.fields[field])errors.push(`${sheet}.${field}: brak opisu pola`);
  }
  for(const sheet of Object.keys(sheetHeaders))if(!QUICK_WORKBOOK_SHEETS[sheet]&&!['Instrukcja','Opis pól','_LISTY'].includes(sheet))errors.push(`${sheet}: nadmiarowa zakładka w prostym pliku`);
  return errors;
}
