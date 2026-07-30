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
