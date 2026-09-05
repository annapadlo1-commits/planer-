# B4F-170 — fairness target fallback, raport UAT 2026-08-24

Status: **TECHNICALLY READY FOR OWNER UAT — NOT PASS / NOT CLOSED**
Zakres: wyłącznie UAT, Supabase `nhthrtpkfpmufmrmdyjg`, gałąź `codex/uat-consolidated-fixes`. `main` i produkcja niezmienione.

## ROOT CAUSE

Progi Matrix v21 nie były twardymi constraints CP-SAT. Błąd znajdował się w orkiestracji prób fairness:

1. `_solve_with_quality_gate` uruchamiał do trzech prób i zapamiętywał tylko krotki wyników liczbowych.
2. Pełne, legalne warianty z `hard violations = 0` były odrzucane, gdy `minimum < 70%` albo `spread > 30 p.p.`.
3. Po trzecim nietrafieniu kod zgłaszał `FairnessQualityGateFailed`.
4. `_execute_claim` przekazywał wyjątek do `solver_fail_attempt`, więc run otrzymywał `FAILED` bez zapisania wariantów.

Audyt całego pipeline'u wykluczył inne podejrzane miejsca: gateway nie odrzucał wyniku za fairness, finalizer DB wymagał `READY` i `hard_violations=0`, widok DB zachowywał metryki, a frontend jedynie prezentował końcowy techniczny failure. Jedna strategia mogła zabić cały run, ponieważ próby operowały na atomowym zestawie wszystkich wariantów i nie miały fallbacku zachowującego ostatni poprawny zestaw.

## WHY V21 RETURNED NO SCHEDULE

V21 traktowała `70% / 30 p.p.` jak bramkę publikowalności na poziomie orkiestratora. Nietrafienie celu jakościowego zgłaszało wyjątek, który był semantycznie równoważny awarii runu. Legalny incumbent nie był przechowywany jako obiekt do zwrotu, dlatego nie istniał już na etapie zapisu wariantów.

## OLD FLOW

`HARD PASS → best coverage → fairness attempts ×3 → target miss → exception → run FAILED → 0 variants`

## NEW FLOW

`HARD PASS → best coverage → keep verified atomic incumbent → fairness attempts ×3 → classify target → return READY variants`

Jeżeli target jest nietrafiony lub etap kończy czas, solver zwraca najlepszy zweryfikowany incumbent. `INFEASIBLE` jest zarezerwowane wyłącznie dla braku rozwiązania twardego modelu.

## FILES CHANGED

- Solver i orkiestracja: `solver/src/grafik_solver/cp_sat_engine.py`, `lifecycle.py`, `models.py`.
- Kontrakt aplikacji i UI: `lib/solver-strategy-contract.ts`, `lib/solver-v2.ts`, `components/SolverV2Panel.tsx`.
- Gateway/DB: migracja `20260824160525_b4f170_fairness_target_best_valid_fallback.sql`, kontrakty i zapytania dowodowe w `supabase/tests/`.
- Regresje: nowe/zmienione testy solvera, strategii, gatewayu, Matrix i importu workbooka.
- Dokumentacja źródeł prawdy: `DECISIONS.md`, `PROJECT_STATUS.md`, ten raport oraz rekordy B4F-170/UAT-064 w głównym rejestrze Excel.

## STATUS SEMANTICS

| Warunek | Status wariantu | Klasyfikacja fairness |
|---|---|---|
| Hard PASS, min ≥ 70%, spread ≤ 30 p.p. | `READY` | `TARGET_MET` |
| Hard PASS, target nietrafiony i udowodniony nieosiągalny | `READY` | `TARGET_NOT_MET_PROVEN` |
| Hard PASS, target nietrafiony z powodu limitu czasu | `READY` | `TARGET_NOT_MET_TIME_LIMIT` |
| Hard PASS, target nietrafiony bez formalnego dowodu | `READY` | `TARGET_NOT_MET_BEST_FOUND` |
| Brak legalnego rozwiązania hard modelu | brak legalnego wariantu | `INFEASIBLE` / istniejący kod błędu hard modelu |

Pola kontraktu obejmują: target min/spread, wartości rzeczywiste, `fairnessTargetMet`, powody, liczbę prób, wybrany seed, `fallbackUsed`, timeout, bound/proof i status etapu.

## FALLBACK BEHAVIOR

- Przechowywany jest cały zestaw wariantów z jednej legalnej próby, nie mieszanka strategii z różnych prób.
- Kandydat musi przejść ponowną walidację względem niemutowalnego wejścia: brak naruszeń hard, zachowane pokrycie, limity nadgodzin i pozostałe bounds.
- Ranking fallbacku maksymalizuje najniższą realizację celu, następnie minimalizuje spread.
- Timeout nie usuwa zweryfikowanego incumbenta.
- Nietrafienie `PREFERENCES` nie usuwa `BALANCED` ani `MIN_COST`.

## TESTS

Pokryto wymagane przypadki:

1. target osiągalny;
2. min 70% niemożliwe, legalny grafik istnieje;
3. spread > 30 p.p.;
4. wszystkie trzy próby nietrafione;
5. `PREFERENCES` nietrafiony, pozostałe strategie zwrócone;
6. prawdziwy hard infeasible;
7. timeout z verified incumbent;
8. regresja B4F-159 oraz brak pogorszenia historycznych przypadków fairness.

## TEST RESULTS

- pełny Node: `343/343 PASS`;
- pełny pytest solvera: `136/136 PASS` oraz `55` podtestów;
- gateway i kontrakty ukierunkowane: `67/67 PASS`;
- TypeScript `npx tsc --noEmit`: `PASS`;
- Next production build: `PASS`;
- SQL B4F-169 i B4F-170 na Supabase UAT: `PASS`;
- Supabase Advisors, poziom `ERROR`: brak wyników;
- Supabase `db lint`: niewykonany — lokalna rola CLI nie przeszła uwierzytelnienia; nie użyto alternatywnego projektu ani obejścia bezpieczeństwa.

Deterministyczny realny test OR-Tools: `8` zmian, `3` osoby, podział `3/3/2`, minimum `66,6%`, spread `33,4 p.p.`, `8` przydziałów, `0` braków, walidator `valid`, wynik zwrócony z targetem nietrafionym.

## UAT RUN 1 — TARGET MET

- run id: `d102e934-fa14-4fff-9e53-c1466af6ed51`;
- warianty: `3`;
- min utilization: `100,0%`;
- spread: `0,0 p.p.`;
- wynik kontrolny: target spełniony, warianty zwrócone.

To istniejący dokładny przypadek kontrolny UAT. Zachowanie po poprawce jest dodatkowo chronione deterministycznym testem `fairnessTargetMet=true`.

## UAT RUN 2 — TARGET NOT MET

- run id: `7a3fc1c5-3018-4593-a77c-2247564d4db4`;
- świeże generowanie po aktywacji Matrix v22;
- warianty zwrócone: `BALANCED`, `MIN_COST`, `PREFERENCES`;
- każdy wariant: `312` przydziałów, `0` braków, `0` hard violations;
- `PREFERENCES`: minimum `41,1%`, spread `37,7 p.p.`, `3` próby;
- warning: „Nie udało się osiągnąć docelowego poziomu wyrównania”; UI pokazuje najlepszy legalny układ oraz dokładne porównanie `41,1% / 70%` i `37,7 / 30 p.p.`;
- fallback used: `true`;
- klasyfikacja: `TARGET_NOT_MET_PROVEN`;
- run status: `READY`.

## UAT RUN 3 — TRUE INFEASIBLE

- historyczny dokładny przypadek UAT: `881052b4-f78c-4d29-8b62-a70e8fb67676`;
- status: `FAILED`;
- reason: `OPTIMIZATION_ERROR — UNFILLED is infeasible`;
- brak legalnego wariantu wynikał z twardego modelu, nie z fairness.

Dodatkowy deterministyczny test po poprawce wymusza `OptimizationError("hard model is infeasible")` już przy pierwszej próbie i potwierdza propagację prawdziwego infeasible bez tworzenia fałszywego grafiku.

## REGRESSION B4F-159

Testy kontraktu strategii potwierdzają nadal kolejność: coverage i hard/overtime przed fairness; fairness przed preferencjami w `PREFERENCES`; pozostałe strategie zachowują własne semantyki. Dotychczasowa jakość przypadków B4F-159 nie została obniżona.

## CHROME E2E

Kanoniczny `https://uat.szafunek.pl`, zalogowana sesja właściciela, aktywna konfiguracja v22. Wygenerowano kategorię SALA i otwarto każdy z trzech wariantów. `BALANCED` i `MIN_COST` mają koszt `105 528 zł`; `PREFERENCES` `106 815 zł`. UI pokazuje `Gotowe do porównania`, `100%` pokrycia i nieblokujące ostrzeżenie wyłącznie dla targetu fairness.

## CONSOLE ERRORS

- błędy: `0`;
- ostrzeżenia: `0`.

## COMMITS

- `a852a0ad46a2d1bfcb2dd2fca715efb9297868f0` — `fix(solver):fairness-target-fallback`;
- `9251185137d6927287212b6ede98da2eb678f363` — `docs-uat-record-fairness-fallback-evidence`; zawiera raport, postflight oraz zapytania dowodowe. Ewentualna korekta samego raportu nie jest samoreferencyjnie hashowana w jego treści; dokładny HEAD pozostaje w historii gałęzi i końcowym przekazaniu zadania.

## DEPLOYMENT STAMP

- branch: `codex/uat-consolidated-fixes`;
- build funkcjonalny użyty przez run UAT: `a852a0ad46a2d1bfcb2dd2fca715efb9297868f0`;
- Vercel po publikacji dowodów: deployment `6qitmNuR6tTVbQNB8Qjfn4Lwo1jW`, `Ready / Latest`, preview `https://planer-gfhlduonj-planner10.vercel.app`, alias `https://uat.szafunek.pl`, źródło `9251185`;
- Northflank po publikacji dowodów: deployment `solver-gateway-64764f7db7`, pod `solver-gateway-64764f7db7-6x49z`, `Running 1/1`, `0` restartów, źródło `9251185`;
- Supabase: `nhthrtpkfpmufmrmdyjg`;
- schema stamp: `20260824160525_b4f170_fairness_target_best_valid_fallback`;
- Matrix: version `22`, semantics `B4F170_V1`, id `57ff107c-6c36-4e43-b657-3fe67369b273`, content hash `2d4e5d9e5717c46b6665c67465bc93d4f1b60e43a7de08ffbe890fa43cbbc12a`;
- gateway contract: v13.

Znane ryzyko audytowe: pole `solver.commit` zapisane w version stampie wariantu nadal ma wcześniejszą wartość `86522fe...`, mimo że panel Northflank potwierdził najpierw kod funkcjonalny `a852a0a`, a następnie bieżącą gałąź `9251185`. Zachowanie nowego fallbacku jest fizycznie aktywne i udowodnione runem, ale metadane obrazu/jobu wymagają osobnego uporządkowania; nie są przedstawiane jako spójne.
