# Audyt profilu pracownika i ekranu „Dziś” — 2026-08-20

## Wniosek

Portal pracownika ma działające elementy operacyjne, ale nie jest jeszcze docelowym, pięciosekcyjnym produktem opisanym przez właścicielkę. Najmocniejsze gotowe części to: opublikowany grafik własny, dostępność i preferencje, dyżury rezerwowe, scoped podgląd zespołu oraz audytowany proces zamian. Największe braki to: właściwa architektura `DZIŚ | GRAFIK | TABLICA | ZGŁOSZENIA | JA`, kompletny profil „JA”, rozróżnienie przyszłej niedostępności od nieobecności na już opublikowanej zmianie, konfigurowalne poziomy widoczności współpracowników oraz backend ewidencji czasu pracy.

## Stan po obecnej zmianie lokalnej

- Dodano prawdziwy ekran startowy `Dziś`, który jest domyślnym wejściem pracownika.
- Ekran pokazuje najbliższą lub trwającą opublikowaną zmianę, godziny, lokal, rolę, dodatkowy obowiązek, sprawy zamian wymagające reakcji, podsumowanie tygodnia oraz podstawowe podsumowanie miesiąca.
- Dodano widoczny placeholder `Ewidencja czasu pracy` z przyciskami `Rozpocznij pracę` i `Zakończ pracę`.
- Oba przyciski są celowo nieaktywne i nie wywołują żadnego RPC. Interfejs jawnie mówi, że QR, lokalizacja albo proste potwierdzenie są decyzją następnego etapu.
- Usunięto z nawigacji pracownika osobną, wycofaną kartę `Czas pracy`, aby nie prowadziła do pustego modułu i nie sugerowała działającego backendu.

## Co już mamy

| Obszar | Stan | Dowód w aplikacji |
|---|---|---|
| Własny opublikowany grafik | Działa | Zmiany, godziny, lokal, rola, rezerwa, wydarzenia i eksport Excel. |
| Szczegóły dnia i zmiany | Działa częściowo | Godziny, lokal, rola, współpracownicy, rozpoczęcie propozycji zamiany. Brakuje pełnej notatki lidera i listy obowiązków dla każdej zmiany. |
| Dostępność pracownika | Działa | Okna dostępności, „wolę nie pracować”, twarda niedostępność, lokal preferowany, historia źródła i blokada wpisów nieedytowalnych. |
| Preferencje pory zmiany | Działa | Rano / środek / wieczór z poziomem preferencji. |
| Zamiany | Działa | Ogłoszenie do osoby albo całej tablicy, sprawdzenie roli/lokalu/kompetencji/dostępności/odpoczynku, zgoda drugiej osoby i decyzja lidera. |
| Widok zespołu | Działa w jednym zakresie | Aktualnie ograniczony do kategorii wynikających z ról pracownika; nie pokazuje kosztów ani powodów nieobecności innych osób. |
| Wiadomości | Działa jako osobny moduł | Osobna karta nawigacji; nie jest jeszcze zintegrowana z docelowym układem pięciu sekcji. |
| Podstawowa tożsamość | Działa częściowo | Imię, nazwisko, GP-###, rola podstawowa i lokale są dostępne, ale nie ma kompletnej sekcji `JA`. |

## Czego nie mamy lub co wymaga przebudowy

### 1. Docelowa nawigacja pięciu sekcji

Aktualna nawigacja ma po dodaniu `Dziś` sześć pozycji: `Dziś`, `Mój grafik`, `Grafik firmy`, `Dostępność`, `Zamiany`, `Wiadomości`. Docelowo trzeba przebudować ją do dokładnie pięciu pozycji:

`DZIŚ | GRAFIK | TABLICA | ZGŁOSZENIA | JA`

Nie należy tylko zmienić nazw. Trzeba połączyć istniejące przepływy bez utraty uprawnień, filtrów i historii.

### 2. `GRAFIK`

Ma połączyć własny grafik i dozwolony podgląd współpracowników. Brakuje konfiguracji widoczności na czterech poziomach: tylko własny grafik, osoby na tej samej zmianie, grafik całej roli, cały lokal. Dzisiaj zakres jest stały i wynika z kategorii, więc wdrożenie wymaga modelu konfiguracji, RPC i RLS, nie tylko przełącznika w UI.

### 3. `TABLICA`

Obecna tablica obsługuje oddanie i zamianę opublikowanej zmiany. Nie ma jeszcze jednego kompletnego rynku obejmującego również rzeczywiste nieobsadzone, otwarte zmiany. Trzeba zdefiniować źródło takich zmian, reguły kwalifikacji, kolejność akceptacji i publikacji.

### 4. `ZGŁOSZENIA`

Obecna dostępność dobrze opisuje przyszłe planowanie, a zamiany obsługują oddanie zmiany. Brakuje jednego prowadzonego formularza, który jasno rozróżnia:

- „nie planuj mnie w przyszłości”;
- „mam już opublikowaną zmianę i nie mogę przyjść”.

Drugi przypadek musi tworzyć audytowane zgłoszenie nieobecności lub proces oddania/zamiany, a nie tylko zapisać przyszłą niedostępność.

### 5. `JA`

Brakuje dedykowanego profilu pokazującego role podstawowe i dodatkowe, lokale, miesięczny nominał i wykorzystanie, weekendy, zamknięcia, stopień uwzględnienia dostępności i preferencji, ustawienia powiadomień, dokumenty/kontakt/regulaminy oraz historię zgłoszeń i zmian. Obecne dane wystarczają tylko do części podstawowej karty.

### 6. Ewidencja czasu pracy

W bazie istnieje historyczny model `attendance_events`, ale publiczny writer `attendance_clock` należy do wycofanego runtime i jego wykonanie zostało odebrane użytkownikom. Nie wolno go reaktywować przez przypadek. Przed backendem trzeba osobno zdecydować:

- metodę potwierdzenia: QR, lokalizacja, prosty przycisk albo wariant mieszany;
- powiązanie z konkretną opublikowaną zmianą i lokalem;
- reguły wcześniejszego/późniejszego wejścia, przerw i korekt;
- działanie bez zgody na lokalizację i bez aparatu;
- RLS, audyt, retencję danych lokalizacyjnych i uprawnienia do korekt;
- zachowanie offline/PWA i komunikaty przy braku sieci.

Do czasu tej decyzji poprawnym zachowaniem jest wyłącznie nieaktywny, jednoznacznie opisany placeholder.

## Granice bezpieczeństwa pracownika

Obecny odczyt grafiku zespołu nie zwraca kosztów, stawek ani powodów nieobecności innych osób. Docelowa przebudowa musi utrzymać te granice również w `Dziś`, `Grafiku`, `Tablicy`, `Zgłoszeniach`, eksporcie i mobilnym PWA. Pracownik nie może otrzymać draftu ani nieopublikowanego grafiku.

## Kolejność rekomendowanej przebudowy

1. Wdrożyć i sprawdzić `Dziś` oraz placeholder ewidencji na UAT.
2. Zbudować `JA` na jednym self-only RPC z podstawami profilu i podsumowaniem miesiąca.
3. Połączyć własny i zespołowy grafik w `GRAFIK` po zatwierdzeniu modelu widoczności.
4. Połączyć dostępność, nieobecność i oddanie zmiany w `ZGŁOSZENIA` z jasnym rozgałęzieniem przed zapisem.
5. Rozszerzyć zamiany do `TABLICY` obejmującej również prawdziwe otwarte zmiany.
6. Osobno zaprojektować i wdrożyć backend ewidencji czasu pracy z testami RLS, audytu, urządzeń mobilnych i PWA.

Żaden z punktów 2–6 nie powinien zostać oznaczony jako `PASS` przed wdrożeniem na UAT, zalogowanym E2E pracownika i akceptacją właścicielki produktu.
