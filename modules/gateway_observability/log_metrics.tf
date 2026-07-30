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
