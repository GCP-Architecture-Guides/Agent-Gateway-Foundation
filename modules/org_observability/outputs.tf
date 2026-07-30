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

output "dashboard_id" {
  description = "Cloud Monitoring dashboard id for Org Agentic Observability."
  value       = google_monitoring_dashboard.org_agentic_observability.id
}

output "metrics_scope_project_id" {
  description = "Hub project id for the metrics scope."
  value       = var.metrics_scope_project_id
}

output "monitored_project_ids" {
  description = "Additional projects registered in the hub metrics scope."
  value       = local.monitored_project_ids
}

output "all_project_ids" {
  description = "Hub plus monitored projects included in the org view."
  value       = local.all_project_ids
}

output "dashboard_console_url" {
  description = "Console URL for the org dashboard (open while scoped to the hub project)."
  value       = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.org_agentic_observability.id), length(split("/", google_monitoring_dashboard.org_agentic_observability.id)) - 1)}?project=${var.metrics_scope_project_id}"
}
