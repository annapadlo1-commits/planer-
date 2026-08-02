# Prywatne wykonanie solvera OR-Tools w GCP

Ten moduł tworzy docelową ścieżkę wykonawczą bez udostępniania danych
uprzywilejowanych przeglądarce:

1. prywatny Cloud Scheduler wywołuje uwierzytelniony Cloud Run dispatcher;
2. dispatcher rezerwuje dokładnie jeden run przez wąski `solver-gateway`;
3. dispatcher uruchamia istniejący Cloud Run Job z jednorazowymi wartościami
   `RUN_ID`, `DISPATCH_TOKEN` i `DISPATCH_ATTEMPT`;
4. job pobiera niezmienny snapshot, utrzymuje lease, zapisuje warianty i kończy
   run przez ten sam gateway.

Usługa dispatchera nie ma publicznego członka IAM. Ingress pozostaje osiągalny
pod adresem Cloud Run, ale wywołanie wymaga tokenu OIDC konta schedulera.
Dispatcher może wyłącznie uruchomić konkretny job z kontrolowanymi nadpisaniami
zmiennych wejściowych (`roles/run.jobsExecutorWithOverrides` przypisane na
poziomie tego jobu), a oba procesy odczytują tylko własny sekret. Tokeny
gatewaya nie są wartościami zmiennych Terraform ani elementem stanu.

## Przygotowanie obrazów i sekretów

Obrazy muszą być zbudowane z katalogów `solver/` i `dispatcher/`, przesłane do
Artifact Registry oraz wskazane w `terraform.tfvars` przez niezmienny digest
`@sha256:…`. Tag obrazu nie spełnia kontraktu wdrożeniowego.

Terraform tworzy kontenery Secret Manager, lecz celowo nie tworzy wersji
sekretów. Przed pierwszym uruchomieniem należy dodać osobne, losowe wartości:

- `grafik-solver-gateway-token` — zgodny z `SOLVER_GATEWAY_TOKEN` funkcji Edge;
- `grafik-dispatcher-gateway-token` — zgodny z
  `DISPATCHER_GATEWAY_TOKEN` funkcji Edge.

Nie używać w tym miejscu klucza Supabase `service_role`, klucza publishable ani
sekretu użytkownika.

## Plan i wdrożenie środowiska testowego

```bash
cd infra/gcp
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt -check
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

Najpierw wdrażamy osobny projekt lub osobne zasoby UAT. Produkcyjny job nie może
zostać podłączony, dopóki shadow UAT nie przejdzie testów zgodności snapshotu,
retry, anulowania, odzyskiwania i publikacji dokładnej wersji solvera.

## Właściwości bezpieczeństwa i odporności

- worker nie ma poświadczeń GCP poza tożsamością jobu i odczytem jednego sekretu;
- dispatcher nie zna tokenu workera i nie może czytać jego sekretu;
- Cloud Scheduler może wywołać wyłącznie usługę dispatchera;
- obrazy są przypięte do digestów, a `SOLVER_VERSION` jest sprawdzana przy claimie;
- Cloud Run nie ponawia procesu samodzielnie (`max_retries = 0`); retry i lease są
  rozstrzygane atomowo w Supabase, co zapobiega równoległym duplikatom;
- usunięcie jobu i usługi jest chronione przez `deletion_protection`.

Wartości `latest` dotyczą wyłącznie wersji sekretów. Po rotacji gateway akceptuje
nowy token, następnie dodawana jest wersja sekretu i wykonywany kontrolowany
restart. Historię runu wiążą `snapshot_hash`, `solver_version`, token dyspozycji
oraz identyfikator próby.
