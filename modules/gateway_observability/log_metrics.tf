locals {
  gateway_egress_filter = <<-EOT
    resource.type="networkservices.googleapis.com/Gateway"
    httpRequest.requestMethod!="CONNECT"
  EOT

  gateway_egress_blocked_filter = <<-EOT
    ${local.gateway_egress_filter}
    jsonPayload.authzPolicyInfo.result="DENIED"
  EOT

  gateway_egress_allowed_filter = <<-EOT
    ${local.gateway_egress_filter}
    jsonPayload.authzPolicyInfo.result="ALLOWED"
  EOT
}

resource "google_logging_metric" "gateway_egress_blocked" {
  project = var.project_id
  name    = "lens_gateway_egress_blocked"
  filter  = local.gateway_egress_blocked_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}

resource "google_logging_metric" "gateway_egress_allowed" {
  project = var.project_id
  name    = "lens_gateway_egress_allowed"
  filter  = local.gateway_egress_allowed_filter

  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    unit        = "1"
  }
}
