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
