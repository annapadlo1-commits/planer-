output "solver_job_name" {
  value = local.solver_job_resource_name
}

output "dispatcher_url" {
  value = google_cloud_run_v2_service.dispatcher.uri
}

output "scheduler_job_name" {
  value = google_cloud_scheduler_job.dispatcher.name
}

output "solver_gateway_secret" {
  value = google_secret_manager_secret.solver_gateway_token.id
}

output "dispatcher_gateway_secret" {
  value = google_secret_manager_secret.dispatcher_gateway_token.id
}
