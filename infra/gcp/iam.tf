resource "google_service_account" "solver" {
  project      = var.project_id
  account_id   = var.solver_service_account_id
  display_name = "Grafik Pro OR-Tools solver"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "dispatcher" {
  project      = var.project_id
  account_id   = var.dispatcher_service_account_id
  display_name = "Grafik Pro solver dispatcher"

  depends_on = [google_project_service.required]
}

resource "google_service_account" "scheduler" {
  project      = var.project_id
  account_id   = var.scheduler_service_account_id
  display_name = "Grafik Pro solver scheduler"

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret_iam_member" "solver_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.solver_gateway_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.solver.email}"
}

resource "google_secret_manager_secret_iam_member" "dispatcher_secret_accessor" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.dispatcher_gateway_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.dispatcher.email}"
}

resource "google_cloud_run_v2_job_iam_member" "dispatcher_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_job.solver.name
  role     = "roles/run.jobsExecutorWithOverrides"
  member   = "serviceAccount:${google_service_account.dispatcher.email}"
}

resource "google_cloud_run_v2_service_iam_member" "scheduler_invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.dispatcher.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.scheduler.email}"
}
