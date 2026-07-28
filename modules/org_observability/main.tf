locals {
  monitored_project_ids = distinct([
    for p in var.monitored_project_ids : p if p != var.metrics_scope_project_id
  ])

  all_project_ids = distinct(concat([var.metrics_scope_project_id], local.monitored_project_ids))

  drilldown_lines = concat(
    [
      format(
        "- **%s** (metrics scope hub): [Agent Observability](https://console.cloud.google.com/monitoring/dashboards/builder/%s?project=%s) · [Gateway Observability](https://console.cloud.google.com/monitoring/dashboards/builder/%s?project=%s) · [Metrics Explorer](https://console.cloud.google.com/monitoring/metrics-explorer?project=%s)",
        var.metrics_scope_project_id,
        var.scope_project_agent_dashboard_id,
        var.metrics_scope_project_id,
        var.scope_project_gateway_dashboard_id,
        var.metrics_scope_project_id,
        var.metrics_scope_project_id,
      )
    ],
    [
      for p in local.monitored_project_ids :
      format(
        "- **%s**: [Cloud Monitoring](https://console.cloud.google.com/monitoring?project=%s) · [Vertex AI](https://console.cloud.google.com/vertex-ai/dashboard?project=%s)",
        p,
        p,
        p,
      )
    ],
  )

  project_list_md = join("\\n", local.drilldown_lines)

  all_projects_summary = join(", ", local.all_project_ids)

  monitored_projects_summary = length(local.monitored_project_ids) > 0 ? "${local.all_projects_summary} (hub: ${var.metrics_scope_project_id})" : local.all_projects_summary

  dashboard_json = replace(
    replace(
      replace(
        file("${path.module}/org-agentic-observability.json"),
        "__SCOPE_PROJECT_ID__",
        var.metrics_scope_project_id,
      ),
      "__MONITORED_PROJECTS_SUMMARY__",
      local.monitored_projects_summary,
    ),
    "__PROJECT_DRILLDOWN_LINKS__",
    local.project_list_md,
  )
}

resource "google_monitoring_monitored_project" "member" {
  for_each = toset(local.monitored_project_ids)

  metrics_scope = "locations/global/metricsScopes/${var.metrics_scope_project_id}"
  name          = "locations/global/metricsScopes/${var.metrics_scope_project_id}/projects/${each.value}"
}

resource "google_monitoring_dashboard" "org_agentic_observability" {
  project        = var.metrics_scope_project_id
  dashboard_json = local.dashboard_json
}
