locals {
  solver_job_resource_name = "projects/${var.project_id}/locations/${var.region}/jobs/${var.solver_job_name}"

  required_apis = toset([
    "artifactregistry.googleapis.com",
    "cloudscheduler.googleapis.com",
    "iam.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
  ])
}

resource "google_project_service" "required" {
  for_each = local.required_apis

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

resource "google_artifact_registry_repository" "solver" {
  project       = var.project_id
  location      = var.region
  repository_id = var.artifact_repository
  description   = "Digest-pinned Grafik Pro solver and dispatcher images"
  format        = "DOCKER"

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "solver_gateway_token" {
  project   = var.project_id
  secret_id = var.solver_gateway_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_secret_manager_secret" "dispatcher_gateway_token" {
  project   = var.project_id
  secret_id = var.dispatcher_gateway_secret_id

  replication {
    auto {}
  }

  depends_on = [google_project_service.required]
}

resource "google_cloud_run_v2_job" "solver" {
  project  = var.project_id
  name     = var.solver_job_name
  location = var.region

  deletion_protection = true

  template {
    parallelism = 1
    task_count  = 1

    template {
      service_account = google_service_account.solver.email
      timeout         = "${var.solver_timeout_seconds}s"
      max_retries     = 0

      containers {
        name  = var.solver_container_name
        image = var.solver_image

        env {
          name  = "SOLVER_GATEWAY_URL"
          value = var.supabase_gateway_url
        }

        env {
          name  = "SOLVER_VERSION"
          value = var.solver_version
        }

        env {
          name = "SOLVER_GATEWAY_TOKEN"
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.solver_gateway_token.secret_id
              version = "latest"
            }
          }
        }

        resources {
          limits = {
            cpu    = "2"
            memory = "2Gi"
          }
        }
      }
    }
  }

  depends_on = [
    google_project_service.required,
    google_secret_manager_secret_iam_member.solver_secret_accessor,
  ]
}

resource "google_cloud_run_v2_service" "dispatcher" {
  project  = var.project_id
  name     = var.dispatcher_service_name
  location = var.region

  deletion_protection = true
  ingress             = "INGRESS_TRAFFIC_ALL"

  template {
    service_account = google_service_account.dispatcher.email
    timeout         = "60s"

    scaling {
      min_instance_count = 0
      max_instance_count = 1
    }

    containers {
      name  = "dispatcher"
      image = var.dispatcher_image

      ports {
        container_port = 8080
      }

      env {
        name  = "DISPATCHER_GATEWAY_URL"
        value = var.supabase_gateway_url
      }

      env {
        name  = "CLOUD_RUN_JOB"
        value = local.solver_job_resource_name
      }

      env {
        name  = "SOLVER_CONTAINER_NAME"
        value = var.solver_container_name
      }

      env {
        name = "DISPATCHER_GATEWAY_TOKEN"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.dispatcher_gateway_token.secret_id
            version = "latest"
          }
        }
      }

      resources {
        limits = {
          cpu    = "1"
          memory = "512Mi"
        }
        cpu_idle          = true
        startup_cpu_boost = true
      }

      startup_probe {
        initial_delay_seconds = 0
        timeout_seconds       = 1
        period_seconds        = 2
        failure_threshold     = 15

        tcp_socket {
          port = 8080
        }
      }
    }
  }

  depends_on = [
    google_cloud_run_v2_job.solver,
    google_secret_manager_secret_iam_member.dispatcher_secret_accessor,
  ]
}

resource "google_cloud_scheduler_job" "dispatcher" {
  project   = var.project_id
  region    = var.region
  name      = var.scheduler_job_name
  schedule  = var.scheduler_schedule
  time_zone = "Etc/UTC"

  attempt_deadline = "30s"

  retry_config {
    retry_count          = 3
    min_backoff_duration = "5s"
    max_backoff_duration = "30s"
    max_doublings        = 2
  }

  http_target {
    uri         = google_cloud_run_v2_service.dispatcher.uri
    http_method = "POST"
    headers = {
      "Content-Type" = "application/json"
    }
    body = base64encode("{}")

    oidc_token {
      service_account_email = google_service_account.scheduler.email
      audience              = google_cloud_run_v2_service.dispatcher.uri
    }
  }

  depends_on = [
    google_cloud_run_v2_service_iam_member.scheduler_invoker,
    google_project_service.required,
  ]
}
