locals {
  cloud_run_filter = <<-EOT
    resource.type="cloud_run_revision"
    resource.labels.service_name="${var.cloud_run_service_name}"
  EOT

  reasoning_engine_filter = <<-EOT
    resource.type="aiplatform.googleapis.com/ReasoningEngine"
  EOT

  lens_log_sources = <<-EOT
    (resource.type="cloud_run_revision" AND resource.labels.service_name="${var.cloud_run_service_name}")
    OR resource.type="aiplatform.googleapis.com/ReasoningEngine"
  EOT

  # Model Armor API audit logs (sanitize_operations); matches Logs Explorer verdict filters.
  model_armor_sanitize_filter = <<-EOT
    resource.type="modelarmor.googleapis.com/SanitizeOperation"
  EOT

  armor_blocked_signal = <<-EOT
    ${local.model_armor_sanitize_filter}
    jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK"
  EOT

  armor_allowed_signal = <<-EOT
    ${local.model_armor_sanitize_filter}
    jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_ALLOW"
  EOT

  prompt_injection_signal = <<-EOT
    ${local.model_armor_sanitize_filter}
    jsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState="MATCH_FOUND"
  EOT
}

resource "google_logging_metric" "model_armor_blocked_api" {
  project = var.project_id
  name    = "lens_model_armor_blocked_api"
  filter  = "${local.cloud_run_filter}\njsonPayload.event=\"model_armor_blocked\"\njsonPayload.armor_layer=\"api\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_allowed_api" {
  project = var.project_id
  name    = "lens_model_armor_allowed_api"
  filter  = "${local.cloud_run_filter}\njsonPayload.event=\"model_armor_allowed\"\njsonPayload.armor_layer=\"api\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_skipped_api" {
  project = var.project_id
  name    = "lens_model_armor_skipped_api"
  filter  = "${local.cloud_run_filter}\njsonPayload.event=\"model_armor_skipped\"\njsonPayload.armor_layer=\"api\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_blocked_supervisor" {
  project = var.project_id
  name    = "lens_model_armor_blocked_supervisor"
  filter  = "${local.reasoning_engine_filter}\njsonPayload.event=\"model_armor_blocked\"\njsonPayload.armor_layer=\"supervisor\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_allowed_supervisor" {
  project = var.project_id
  name    = "lens_model_armor_allowed_supervisor"
  filter  = "${local.reasoning_engine_filter}\njsonPayload.event=\"model_armor_allowed\"\njsonPayload.armor_layer=\"supervisor\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "query_terminal" {
  project = var.project_id
  name    = "lens_query_terminal"
  filter  = "${local.cloud_run_filter}\njsonPayload.event=\"query_terminal\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "query_terminal_blocked_armor" {
  project = var.project_id
  name    = "lens_query_terminal_blocked_model_armor"
  filter  = "${local.cloud_run_filter}\njsonPayload.event=\"query_terminal\"\njsonPayload.block_layer=\"model_armor\""

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_blocked" {
  project = var.project_id
  name    = "lens_model_armor_blocked"
  filter  = local.armor_blocked_signal

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_allowed" {
  project = var.project_id
  name    = "lens_model_armor_allowed"
  filter  = local.armor_allowed_signal

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "model_armor_prompt_injection" {
  project = var.project_id
  name    = "lens_model_armor_prompt_injection"
  filter  = local.prompt_injection_signal

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}
