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

output "metric_ids" {
  value = {
    model_armor_blocked_api            = google_logging_metric.model_armor_blocked_api.id
    model_armor_allowed_api            = google_logging_metric.model_armor_allowed_api.id
    model_armor_skipped_api            = google_logging_metric.model_armor_skipped_api.id
    model_armor_blocked_supervisor     = google_logging_metric.model_armor_blocked_supervisor.id
    model_armor_allowed_supervisor     = google_logging_metric.model_armor_allowed_supervisor.id
    query_terminal                     = google_logging_metric.query_terminal.id
    query_terminal_blocked_model_armor = google_logging_metric.query_terminal_blocked_armor.id
    model_armor_blocked                = google_logging_metric.model_armor_blocked.id
    model_armor_allowed                = google_logging_metric.model_armor_allowed.id
    model_armor_prompt_injection       = google_logging_metric.model_armor_prompt_injection.id
  }
}

output "metric_type_prefix" {
  description = "Use logging.googleapis.com/user/<metric_name> in dashboard charts."
  value       = "logging.googleapis.com/user"
}

output "security_alert_policy_ids" {
  description = "Model Armor security alert policy IDs (null when disabled or channels not configured)."
  value = {
    prompt_injection_surge = try(google_monitoring_alert_policy.prompt_injection_surge[0].id, null)
  }
}

output "security_notification_channel_ids" {
  description = "Notification channels wired to Model Armor security alerts."
  value       = local.all_security_notification_channel_ids
}

output "managed_security_notification_channels" {
  description = "Terraform-managed security notification channel IDs by type."
  value = {
    google_chat = try(google_monitoring_notification_channel.security_google_chat[0].id, null)
  }
}
