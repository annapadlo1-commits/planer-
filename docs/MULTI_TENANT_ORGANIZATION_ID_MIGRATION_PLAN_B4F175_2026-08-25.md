# B4F-175 — plan migracji `organization_id` dla izolacji wielu firm

Status: **OPEN / PLAN ONLY**. Ten dokument nie autoryzuje migracji produkcji ani zmiany modelu biznesowego. Bieżąca naprawa XLSX B4F-172–B4F-174 działa w istniejącej, globalnej przestrzeni wersji konfiguracji i nie jest dowodem izolacji tenantów.

## Stan obecny i ryzyko

`matrix_versions` oraz zależne tabele konfiguracji używają globalnego cyklu `DRAFT` / `ACTIVE`. Import chronią uprawnienia OWNER/ADMIN, blokada transakcyjna i kontrola bieżącego identyfikatora wersji, ale w modelu nie ma nadrzędnego klucza firmy. Bez niego nie można formalnie wykazać, że zapytania, unikalności, RLS, solver i eksport są ograniczone do jednej organizacji.

Do czasu wdrożenia B4F-175 obowiązuje ograniczenie: jedna przestrzeń konfiguracji na środowisko. Nie wolno używać ukrytego identyfikatora z XLSX jako identyfikatora firmy ani ufać zakresowi przesłanemu przez klienta.

## Docelowy model

1. Utworzyć tabelę `organizations` i jawne członkostwa użytkownik–organizacja z rolą oraz zakresem.
2. Dodać niepusty `organization_id` do `matrix_versions`, tożsamości pracowników i wszystkich danych zależnych, które mogą być odczytane niezależnie od wersji konfiguracji.
3. Zmienić klucze unikalne z globalnych na złożone, np. `(organization_id, status)` dla kontrolowanego cyklu wersji i `(organization_id, code)` dla stabilnych kodów biznesowych.
4. Wszystkie klucze obce obejmujące dane firmy rozszerzyć tak, aby relacja nie mogła połączyć rekordów z różnych organizacji. Tam, gdzie PostgreSQL wymaga tego dla złożonego FK, dodać odpowiadające ograniczenia `UNIQUE`.
5. Każde RPC przyjmujące lub wyznaczające wersję ma najpierw ustalić organizację z uwierzytelnionego członkostwa po stronie serwera. `organization_id` przesłany przez klienta lub XLSX nie może rozstrzygać zakresu.
6. RLS zdefiniować dla każdej tabeli firmowej osobno dla `SELECT`, `INSERT`, `UPDATE` i `DELETE`. Funkcje `SECURITY DEFINER` zachowują pusty `search_path`, minimalne granty i jawne sprawdzenie członkostwa.
7. Solver, worker/gateway, magazyn artefaktów, logi audytowe, publikacje i cache muszą otrzymywać oraz weryfikować serwerowo wyznaczony `organization_id`.

## Bezpieczna sekwencja migracji

1. Inwentaryzacja wszystkich tabel, widoków, triggerów, RPC, RLS, zadań i integracji odwołujących się do `matrix_versions`, pracowników, grafików i finansów.
2. Migracja rozszerzająca: utworzenie organizacji UAT, dodanie nullable `organization_id`, indeksów i mechanizmu kontrolowanego backfillu bez zmiany zachowania aplikacji.
3. Backfill w jednej transakcji na UAT i raport: liczba rekordów każdej tabeli przed/po, brak nulli, brak relacji osieroconych i brak relacji między organizacjami.
4. Dodanie złożonych unikalności i FK jako `NOT VALID`, walidacja ograniczeń, a dopiero potem `NOT NULL`.
5. Wersjonowane RPC v2 ograniczone organizacją; równoległe testy porównawcze ze starym kontraktem na jednej firmie.
6. Włączenie RLS i cofnięcie zbędnych grantów. Testy negatywne z co najmniej dwiema organizacjami i użytkownikami o różnych rolach.
7. Przełączenie eksportu/importu i solvera na nowy kontrakt. Metadane XLSX mogą zawierać nieautorytatywny identyfikator źródłowej wersji, ale zakres firmy zawsze wynika z sesji serwerowej.
8. Usunięcie starego globalnego kontraktu dopiero po pełnym UAT, obserwacji logów i jawnej akceptacji właścicielki produktu.

## Minimalne testy akceptacyjne

- Użytkownik organizacji A nie odczyta, nie zmieni, nie wyeksportuje i nie uruchomi solvera dla danych organizacji B, także przez bezpośrednie RPC i zmodyfikowany XLSX.
- Identyczne kody, numery `GP-###`, nazwy i status `DRAFT` mogą istnieć równolegle w A i B bez kolizji.
- Stary lub zmodyfikowany identyfikator wersji z organizacji A jest odrzucany w sesji organizacji B przed jakąkolwiek mutacją.
- Import preview i apply używają tego samego serwerowo ustalonego zakresu oraz ponownie sprawdzają wersję pod blokadą transakcyjną.
- Eksport → edycja nazwy → import aktualizuje ten sam rekord wyłącznie w swojej organizacji.
- Testy RLS obejmują `anon`, `authenticated` bez członkostwa, pracownika, lidera, administratora i właściciela.

## Warunek GO

GO dla wielu firm wymaga: kompletnego grafu `organization_id`, zwalidowanych złożonych FK, pełnej macierzy RLS/RPC, izolacji solvera i artefaktów, dwóch rzeczywistych tenantów testowych na UAT oraz E2E bez przecieku danych. Do tego czasu werdykt dla deklaracji „bezpieczny multi-tenant” pozostaje **STOP**.
