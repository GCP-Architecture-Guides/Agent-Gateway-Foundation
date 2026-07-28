output "dashboard_id" {
  description = "Cloud Monitoring dashboard resource id for Agent Observability."
  value       = google_monitoring_dashboard.agent_observability.id
}

output "llm_log_metric_names" {
  description = "User-defined log-based metrics for per-agent LLM usage."
  value = {
    total_tokens  = google_logging_metric.llm_total_tokens.name
    prompt_tokens = google_logging_metric.llm_prompt_tokens.name
    output_tokens = google_logging_metric.llm_output_tokens.name
    call_count    = google_logging_metric.llm_call_count.name
    error_count   = google_logging_metric.llm_error_count.name
  }
}

output "alert_policy_ids" {
  description = "Token alert policy IDs (null when disabled or channels not configured)."
  value = {
    al1_baseline_spike    = try(google_monitoring_alert_policy.llm_per_agent_baseline_spike[0].id, null)
    al2_runaway_loop      = try(google_monitoring_alert_policy.llm_runaway_loop[0].id, null)
    al3_project_surge     = try(google_monitoring_alert_policy.project_token_surge[0].id, null)
    al4_absolute_ceiling  = try(google_monitoring_alert_policy.llm_per_agent_absolute_ceiling[0].id, null)
    al5_error_correlation = try(google_monitoring_alert_policy.llm_error_token_correlation[0].id, null)
    al6_zero_traffic      = try(google_monitoring_alert_policy.llm_zero_traffic[0].id, null)
  }
}

output "notification_channel_ids" {
  description = "All notification channels wired to token alerts (Slack, Google Chat, email, plus extras)."
  value       = local.all_notification_channel_ids
}

output "managed_notification_channels" {
  description = "Terraform-managed notification channel IDs by type."
  value = {
    slack       = try(google_monitoring_notification_channel.slack[0].id, null)
    google_chat = try(google_monitoring_notification_channel.google_chat[0].id, null)
    email       = try(google_monitoring_notification_channel.email[0].id, null)
  }
}
