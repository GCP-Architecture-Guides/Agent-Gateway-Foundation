# Copyright 2025 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# This code is for PoC environment only.
# This demo code is not built for production workload.

# ------------------------------------------------------------------------------
# 4. OBSERVABILITY DASHBOARDS & ALERTS
# ------------------------------------------------------------------------------
module "lens_model_armor" {
  source = "./modules/lens_model_armor"

  project_id                              = var.project_id
  cloud_run_service_name                  = var.cloud_run_service_name
  security_google_chat_space              = var.security_google_chat_space
  security_google_chat_display_name       = var.security_google_chat_display_name
  security_notification_channel_ids       = var.security_notification_channel_ids
  enable_model_armor_security_alerts      = var.enable_model_armor_security_alerts
  prompt_injection_alert_threshold        = var.prompt_injection_alert_threshold
  prompt_injection_alert_window_seconds   = var.prompt_injection_alert_window_seconds
  prompt_injection_alert_duration_seconds = var.prompt_injection_alert_duration_seconds
}

module "gateway_observability" {
  source = "./modules/gateway_observability"

  project_id             = var.project_id
  cloud_run_service_name = var.cloud_run_service_name

  depends_on = [module.lens_model_armor]
}

module "org_observability" {
  count  = var.enable_org_observability ? 1 : 0
  source = "./modules/org_observability"

  metrics_scope_project_id           = coalesce(var.org_metrics_scope_project_id, var.project_id)
  monitored_project_ids              = var.org_monitored_project_ids
  scope_project_agent_dashboard_id   = module.agent_observability.dashboard_id
  scope_project_gateway_dashboard_id = module.gateway_observability.dashboard_id

  depends_on = [
    module.agent_observability,
    module.gateway_observability,
  ]
}

module "agent_observability" {
  source = "./modules/agent_observability"

  project_id                                  = var.project_id
  notification_channel_ids                    = var.notification_channel_ids
  slack_channel_name                          = var.slack_channel_name
  slack_auth_token                            = var.slack_auth_token
  slack_display_name                          = var.slack_display_name
  google_chat_space                           = var.google_chat_space
  google_chat_display_name                    = var.google_chat_display_name
  alert_email_address                         = var.alert_email_address
  alert_email_display_name                    = var.alert_email_display_name
  enable_token_alerts                         = var.enable_token_alerts
  enable_alert_baseline_spike                 = var.enable_alert_baseline_spike
  enable_alert_runaway_loop                   = var.enable_alert_runaway_loop
  enable_alert_project_surge                  = var.enable_alert_project_surge
  enable_alert_absolute_ceiling               = var.enable_alert_absolute_ceiling
  enable_alert_error_correlation              = var.enable_alert_error_correlation
  enable_alert_zero_traffic                   = var.enable_alert_zero_traffic
  project_token_surge_threshold               = var.project_token_surge_threshold
  project_surge_duration_seconds              = var.project_surge_duration_seconds
  per_agent_baseline_spike_percent            = var.per_agent_baseline_spike_percent
  per_agent_baseline_spike_duration_seconds   = var.per_agent_baseline_spike_duration_seconds
  per_agent_absolute_ceiling_threshold        = var.per_agent_absolute_ceiling_threshold
  per_agent_absolute_ceiling_duration_seconds = var.per_agent_absolute_ceiling_duration_seconds
  runaway_loop_call_threshold                 = var.runaway_loop_call_threshold
  runaway_loop_min_tokens                     = var.runaway_loop_min_tokens
  runaway_loop_duration_seconds               = var.runaway_loop_duration_seconds
  error_correlation_token_threshold           = var.error_correlation_token_threshold
  error_correlation_error_threshold           = var.error_correlation_error_threshold
  error_correlation_duration_seconds          = var.error_correlation_duration_seconds
  zero_traffic_duration_seconds               = var.zero_traffic_duration_seconds
  per_agent_token_spike_threshold             = var.per_agent_token_spike_threshold
  per_agent_spike_duration_seconds            = var.per_agent_spike_duration_seconds
}

# ------------------------------------------------------------------------------
# AUDIT LOG SINK → BigQuery
# ------------------------------------------------------------------------------
# Captures ALL aiplatform.googleapis.com data access audit logs into BigQuery
# for long-term retention, querying, and dashboard use.
#
# Filter captures the full breadth of agent activity:
#   - StreamQueryReasoningEngine  (inference calls through the gateway)
#   - SessionService.*            (session create/list/get/delete)
#   - ReasoningEngineExecutionService.* (direct RE execution)
#   - SemanticGovernancePolicyEngineService.* (SGP decisions)
#   - Any other aiplatform DATA_READ / DATA_WRITE events
#
# WHY broad filter: the original sink only matched Predict/GenerateContent/
# StreamGenerateContent and missed all RE, session, and SGP audit events.
# ------------------------------------------------------------------------------
resource "google_bigquery_dataset" "llm_audit_logs" {
  dataset_id                 = "llm_audit_logs"
  project                    = var.project_id
  location                   = var.location
  description                = "AI agent audit logs — all aiplatform.googleapis.com DATA_READ and DATA_WRITE events."
  delete_contents_on_destroy = false

  depends_on = [google_project_service.storage]
}

resource "google_logging_project_sink" "llm_invocation_sink" {
  name        = "llm-invocation-sink"
  project     = var.project_id
  destination = "bigquery.googleapis.com/projects/${var.project_id}/datasets/${google_bigquery_dataset.llm_audit_logs.dataset_id}"

  # Captures ALL aiplatform data access events — RE queries, sessions, SGP decisions, etc.
  filter = <<-EOT
    logName="projects/${var.project_id}/logs/cloudaudit.googleapis.com%2Fdata_access"
    AND protoPayload.serviceName="aiplatform.googleapis.com"
  EOT

  unique_writer_identity = true

  depends_on = [google_bigquery_dataset.llm_audit_logs]
}

# Grant the sink's writer SA permission to write to the BigQuery dataset
resource "google_bigquery_dataset_iam_member" "llm_sink_writer" {
  dataset_id = google_bigquery_dataset.llm_audit_logs.dataset_id
  project    = var.project_id
  role       = "roles/bigquery.dataEditor"
  member     = google_logging_project_sink.llm_invocation_sink.writer_identity
}
