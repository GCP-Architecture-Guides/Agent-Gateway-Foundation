resource "google_logging_project_bucket_config" "default_analytics" {
  project          = var.project_id
  location         = "global"
  bucket_id        = "_Default"
  enable_analytics = true
}

locals {
  # Use templatefile() so project_id flows in as a proper Terraform variable —
  # the same project_id already defined in terraform.tfvars. No placeholder
  # strings, no replace() hacks, no intermediate variables needed.
  dashboard_json = templatefile(
    "${path.module}/agent-gateway-observability.json.tpl",
    { project_id = var.project_id }
  )
}

resource "google_monitoring_dashboard" "agent_gateway_observability" {
  project        = var.project_id
  dashboard_json = local.dashboard_json

  depends_on = [google_logging_project_bucket_config.default_analytics]
}
