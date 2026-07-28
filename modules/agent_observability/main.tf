locals {
  dashboard_json_raw = replace(
    replace(
      file("${path.module}/agent-observability.json"),
      var.demo_project_placeholder,
      var.project_id,
    ),
    "__ALERT_POLICY_NAMES__",
    jsonencode(local.alert_policy_names),
  )
}

resource "google_monitoring_dashboard" "agent_observability" {
  project        = var.project_id
  dashboard_json = local.dashboard_json_raw
}
