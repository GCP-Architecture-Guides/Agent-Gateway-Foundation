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
  model_armor_alerts_enabled = var.enable_model_armor_security_alerts && local.security_notification_channels_configured
}

resource "google_monitoring_alert_policy" "prompt_injection_surge" {
  count = local.model_armor_alerts_enabled ? 1 : 0

  project      = var.project_id
  display_name = "Model Armor: prompt injection surge"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Model Armor detected **${var.prompt_injection_alert_threshold}+ prompt injection / jailbreak matches** within a ${var.prompt_injection_alert_window_seconds}-second window.

      Filter: `pi_and_jailbreak` match state `MATCH_FOUND` on `modelarmor.googleapis.com/SanitizeOperation` logs.

      **Runbook**
      - [Agent Gateway Observability dashboard](https://console.cloud.google.com/monitoring/dashboards?project=${var.project_id})
      - [Logs — prompt injection matches](https://console.cloud.google.com/logs/query;query=resource.type%3D%22modelarmor.googleapis.com%2FSanitizeOperation%22%0AjsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState%3D%22MATCH_FOUND%22;duration=PT1H?project=${var.project_id})
      - [Alert policies](https://console.cloud.google.com/monitoring/alerting/policies?project=${var.project_id})
      - Investigate source IP/session, repeated attack patterns, and whether Model Armor templates need tightening.
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Prompt injection matches / minute above threshold"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/lens_model_armor_prompt_injection\" resource.type=\"modelarmor.googleapis.com/SanitizeOperation\""
      duration        = "${var.prompt_injection_alert_duration_seconds}s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.prompt_injection_alert_threshold - 1

      aggregations {
        alignment_period     = "${var.prompt_injection_alert_window_seconds}s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = []
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_security_notification_channel_ids
}
