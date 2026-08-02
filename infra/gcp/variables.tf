variable "project_id" {
  type        = string
  description = "GCP project that owns the private solver runtime."
}

variable "region" {
  type    = string
  default = "europe-west1"
}

variable "artifact_repository" {
  type    = string
  default = "grafik-pro"
}

variable "solver_image" {
  type        = string
  description = "Immutable digest-pinned OR-Tools worker image."
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.solver_image))
    error_message = "solver_image must be pinned by sha256 digest."
  }
}

variable "dispatcher_image" {
  type        = string
  description = "Immutable digest-pinned dispatcher image."
  validation {
    condition     = can(regex("@sha256:[0-9a-f]{64}$", var.dispatcher_image))
    error_message = "dispatcher_image must be pinned by sha256 digest."
  }
}

variable "solver_version" {
  type        = string
  description = "Version embedded in the worker image and persisted on every run."
  validation {
    condition     = length(var.solver_version) >= 1 && length(var.solver_version) <= 200
    error_message = "solver_version must contain 1-200 characters."
  }
}

variable "solver_job_name" {
  type    = string
  default = "grafik-solver-v2"
}

variable "solver_container_name" {
  type    = string
  default = "solver"
}

variable "dispatcher_service_name" {
  type    = string
  default = "grafik-solver-dispatcher"
}

variable "scheduler_job_name" {
  type    = string
  default = "grafik-solver-dispatch"
}

variable "scheduler_schedule" {
  type    = string
  default = "* * * * *"
}

variable "supabase_gateway_url" {
  type        = string
  description = "Exact HTTPS /functions/v1/solver-gateway endpoint."
  validation {
    condition = can(regex(
      "^https://[^/?#]+/functions/v1/solver-gateway$",
      var.supabase_gateway_url,
    ))
    error_message = "supabase_gateway_url must be the exact HTTPS gateway URL."
  }
}

variable "solver_gateway_secret_id" {
  type    = string
  default = "grafik-solver-gateway-token"
}

variable "dispatcher_gateway_secret_id" {
  type    = string
  default = "grafik-dispatcher-gateway-token"
}

variable "solver_service_account_id" {
  type    = string
  default = "grafik-solver-worker"
}

variable "dispatcher_service_account_id" {
  type    = string
  default = "grafik-solver-dispatcher"
}

variable "scheduler_service_account_id" {
  type    = string
  default = "grafik-solver-scheduler"
}

variable "solver_timeout_seconds" {
  type    = number
  default = 900
  validation {
    condition     = var.solver_timeout_seconds >= 60 && var.solver_timeout_seconds <= 3600
    error_message = "solver_timeout_seconds must be between 60 and 3600."
  }
}
