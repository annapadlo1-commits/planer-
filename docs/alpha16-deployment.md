# Alpha 16 — kontrolowane wdrożenie

> **Historyczna procedura Alpha 16.** Nie jest instrukcją wdrożenia aktualnej gałęzi UAT. Bieżący stan: `codex/uat-consolidated-fixes`, PR #7; źródła prawdy znajdują się w katalogu nadrzędnym.

Ten release rozdziela generator wariantów od grafiku operacyjnego, ustanawia Matrix v2 jako jedyne źródło administracyjne i wycofuje zapisy Alpha 15. Migracje są addytywne; aktywacja OR-Tools jest osobną bramką po wdrożeniu kodu i bazy.

## Bramka 0 — stan wejściowy

- przypnij SHA release'u i nie wdrażaj ruchomego `main`;
- zapisz liczbę oraz identyfikatory niedokończonych runów Alpha 15;
- potwierdź `DEFAULT_ENGINE=ALPHA15`;
- potwierdź działający rollback kodu oraz dostęp właściciela do bazy;
- nie usuwaj zdalnej funkcji `schedule-optimizer`, dopóki stare runy nie zostaną formalnie zakończone albo anulowane.

## Bramka 1 — rekonsyliacja historii

Przed resetem/rebase branchu uruchom ręcznie `supabase/manual/alpha16_reconcile_20260801113137.sql`. Skrypt:

- blokuje dokładnie wersję `20260801113137`;
- weryfikuje nazwę i oryginalną treść bajtowo po normalizacji białych znaków;
- zastępuje wyłącznie zapisane pole `statements` wariantem warunkowym;
- nie zmienia schematu ani danych biznesowych.

Następnie utwórz albo zresetuj czysty branch Supabase. Wszystkie migracje muszą odtworzyć się bez ręcznego dogrywania `0001`–`0015`.

## Bramka 2 — walidacja branchu

Wymagane wyniki:

- wszystkie kontrakty `supabase/tests/*.sql` przechodzą w transakcjach z `ROLLBACK`;
- `supabase/tests/alpha16_contract.sql` potwierdza automatyczne numery, wiele lokali, 10+ bloków zmian, import, obowiązki zmianowe, preferencje i wycofane RPC;
- doradca bezpieczeństwa nie zgłasza `ERROR`; tabela operacyjnych nadpisań nie ma grantów bezpośrednich;
- TypeScript, gateway `8/8` i `next build` są zielone;
- oba joby `Alpha 16 release gates` są zielone; job solvera instaluje dokładnie `solver/requirements.txt` i uruchamia pełny `unittest`.

## Bramka 3 — wdrożenie dark launch

1. Zastosuj trzy migracje Alpha 16 w kolejności znaczników czasu.
2. Wykonaj kontrakty produkcyjne wyłącznie w transakcjach z `ROLLBACK`.
3. Wdróż frontend przypięty do tego samego SHA.
4. Potwierdź, że klienci nie mogą wywołać bezpośrednio `optimizer_publish_company_variant_v2`; publikacja przechodzi przez audytowany endpoint Alpha 16 i wymaga powodu przy brakach obsady.
5. Wdróż `solver-gateway` z dedykowanym `SOLVER_GATEWAY_TOKEN` i sprawdź odpowiedzi `401` bez tokenu oraz poprawny claim z tokenem.
6. Uruchom trwałego pull-workera z tą samą wersją solvera; potwierdź heartbeat, lease recovery i brak podwójnego claimu.
7. Pozostaw `DEFAULT_ENGINE=ALPHA15`, dopóki odczyt portalu, Matrix i katalog wariantów nie przejdą smoke testu.

## Bramka 4 — aktywacja

1. Przełącz najpierw `SHADOW` i wygeneruj kontrolny miesiąc bez możliwości publikacji.
2. Porównaj pokrycie, twarde naruszenia, koszt, nadgodziny, preferencje i diagnostykę braków.
3. Dopiero po akceptacji przełącz `ORTOOLS_V2`.
4. Utwórz kilka wariantów, wybierz jeden, opublikuj grafik operacyjny i wykonaj kontrolowane awaryjne przypisanie z wpisem audytowym.
5. Sprawdź portal pracownika po odświeżeniu: dwa okna jednego dnia i preferencja z nadrzędną blokadą pracodawcy.

## Wycofanie

- przed publikacją wariantu wystarczy przywrócić `DEFAULT_ENGINE=ALPHA15` i cofnąć frontend;
- po publikacji nie usuwaj danych OR-Tools: oznacz release jako wycofany, zachowaj historię i przełącz flagę;
- migracji addytywnych nie cofaj przez usuwanie tabel; ewentualny rollback zapisów Alpha 15 wymaga jawnej, osobno zatwierdzonej ponownej autoryzacji starych RPC;
- zdalną funkcję `schedule-optimizer` usuń dopiero po zakończeniu wszystkich starych runów i upływie uzgodnionego okna rollbacku.
