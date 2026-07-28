output "dashboard_id" {
  description = "Cloud Monitoring dashboard resource id."
  value       = google_monitoring_dashboard.agent_gateway_observability.id
}

output "log_bucket_id" {
  description = "Log bucket config with analytics enabled."
  value       = google_logging_project_bucket_config.default_analytics.id
}

output "gateway_log_metric_ids" {
  description = "User-defined log-based metric names for Agent Gateway egress."
  value = {
    gateway_egress_blocked = google_logging_metric.gateway_egress_blocked.name
    gateway_egress_allowed = google_logging_metric.gateway_egress_allowed.name
  }
}
