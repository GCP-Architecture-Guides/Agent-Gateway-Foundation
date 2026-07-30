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
  alerts_enabled = var.enable_token_alerts && local.notification_channels_configured

  alert_runbook_footer = <<-EOT
    **Runbook (AL9)**
    - [Agent Observability dashboard](https://console.cloud.google.com/monitoring/dashboards?project=${var.project_id})
    - [Logs — llm_usage events](https://console.cloud.google.com/logs/query;query=resource.type%3D%22aiplatform.googleapis.com%2FReasoningEngine%22%0AjsonPayload.event%3D%22llm_usage%22;duration=PT1H?project=${var.project_id})
    - [Metrics Explorer — lens_llm_total_tokens](https://console.cloud.google.com/monitoring/metrics-explorer?project=${var.project_id})
    - [Alert policies](https://console.cloud.google.com/monitoring/alerting/policies?project=${var.project_id})
    - Check Trace for `lens_request_id`, supervisor routing retries, and tool errors.
  EOT

  alert_policy_name_refs = compact([
    try(google_monitoring_alert_policy.llm_per_agent_baseline_spike[0].name, ""),
    try(google_monitoring_alert_policy.llm_runaway_loop[0].name, ""),
    try(google_monitoring_alert_policy.project_token_surge[0].name, ""),
    try(google_monitoring_alert_policy.llm_per_agent_absolute_ceiling[0].name, ""),
    try(google_monitoring_alert_policy.llm_error_token_correlation[0].name, ""),
    try(google_monitoring_alert_policy.llm_zero_traffic[0].name, ""),
  ])

  alert_policy_names = [
    for name in local.alert_policy_name_refs : replace(name, "projects/${var.project_id}/", "")
  ]
}

moved {
  from = google_monitoring_alert_policy.llm_per_agent_spike
  to   = google_monitoring_alert_policy.llm_per_agent_absolute_ceiling
}

# AL1 — per-agent spike vs prior interval (ALIGN_PERCENT_CHANGE; 3σ MQL unsupported on distribution log metrics).
resource "google_monitoring_alert_policy" "llm_per_agent_baseline_spike" {
  count = local.alerts_enabled && var.enable_alert_baseline_spike ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL1: per-agent baseline spike"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Per-agent LLM **call volume** rose more than ${var.per_agent_baseline_spike_percent}% vs the prior alignment period (15-minute buckets, sustained ${var.per_agent_baseline_spike_duration_seconds / 60} min).

      Uses `lens_llm_call_count` (INT64) because token distribution metrics do not support percent-change aligners.
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Per-agent LLM calls / 15 min percent change"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/lens_llm_call_count\" resource.type=\"aiplatform.googleapis.com/ReasoningEngine\""
      duration        = "${var.per_agent_baseline_spike_duration_seconds}s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.per_agent_baseline_spike_percent

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_PERCENT_CHANGE"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = ["metric.label.agent_id"]
      }

      trigger {
        count = 1
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_INACTIVE"
    }
  }

  notification_channels = local.all_notification_channel_ids
}

# AL2 — runaway loop heuristic (high call volume with meaningful token burn).
resource "google_monitoring_alert_policy" "llm_runaway_loop" {
  count = local.alerts_enabled && var.enable_alert_runaway_loop ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL2: runaway LLM loop"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Per-agent LLM call volume exceeded ${var.runaway_loop_call_threshold} calls in a 15-minute bucket (sustained ${var.runaway_loop_duration_seconds / 60} min).

      Pattern: many small round-trips — tool retry, re-prompt, or routing loop. Pair with token charts on the dashboard; token minimum (${var.runaway_loop_min_tokens}) is documented for runbook context.
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "High LLM calls per agent"

    condition_monitoring_query_language {
      query = <<-EOT
        fetch aiplatform.googleapis.com/ReasoningEngine
        | metric 'logging.googleapis.com/user/lens_llm_call_count'
        | align delta(15m)
        | group_by [metric.agent_id], [value: sum(value)]
        | condition val() > ${var.runaway_loop_call_threshold}
      EOT

      duration = "${var.runaway_loop_duration_seconds}s"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channel_ids
}

# AL3 — project-wide token surge (native Vertex publisher metric).
resource "google_monitoring_alert_policy" "project_token_surge" {
  count = local.alerts_enabled && var.enable_alert_project_surge ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL3: project-wide token surge"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Project-wide Vertex Gemini token consumption exceeded ${var.project_token_surge_threshold} tokens in a 15-minute bucket (sustained ${var.project_surge_duration_seconds / 60} min).

      Uses native publisher metrics (all Gemini traffic in the project, not Lens-only).
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Project tokens / 15 min above threshold"

    condition_threshold {
      filter          = "metric.type=\"aiplatform.googleapis.com/publisher/online_serving/token_count\" resource.type=\"aiplatform.googleapis.com/PublisherModel\""
      duration        = "${var.project_surge_duration_seconds}s"
      comparison      = "COMPARISON_GT"
      threshold_value = var.project_token_surge_threshold

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = []
      }

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channel_ids
}

# AL4 — per-agent absolute token ceiling.
resource "google_monitoring_alert_policy" "llm_per_agent_absolute_ceiling" {
  count = local.alerts_enabled && var.enable_alert_absolute_ceiling ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL4: per-agent absolute ceiling"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Per-agent LLM token usage exceeded ${local.absolute_ceiling_threshold} tokens in a 15-minute bucket (sustained ${local.absolute_ceiling_duration_seconds / 60} min).

      Hard ceiling for known high-cost agents or runaway spend.
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Per-agent tokens / 15 min above ceiling"

    condition_monitoring_query_language {
      query = <<-EOT
        fetch aiplatform.googleapis.com/ReasoningEngine
        | metric 'logging.googleapis.com/user/lens_llm_total_tokens'
        | align delta(15m)
        | group_by [metric.agent_id], [value: sum(value)]
        | condition val() > ${local.absolute_ceiling_threshold}
      EOT

      duration = "${local.absolute_ceiling_duration_seconds}s"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channel_ids
}

# AL5 — token spike correlated with llm_usage errors for the same agent.
resource "google_monitoring_alert_policy" "llm_error_token_correlation" {
  count = local.alerts_enabled && var.enable_alert_error_correlation ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL5: error + token correlation"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      Per-agent LLM errors and elevated token usage detected together (tokens > ${var.error_correlation_token_threshold}, errors > ${var.error_correlation_error_threshold} per 15 min, sustained ${var.error_correlation_duration_seconds / 60} min).

      Pattern: failing retries burning tokens.
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Elevated tokens and errors per agent"

    condition_monitoring_query_language {
      query = <<-EOT
        fetch aiplatform.googleapis.com/ReasoningEngine
        | {
            t: metric 'logging.googleapis.com/user/lens_llm_total_tokens'
              | align delta(15m)
              | group_by [metric.agent_id], [tokens: sum(value)];
            e: metric 'logging.googleapis.com/user/lens_llm_error_count'
              | align delta(15m)
              | group_by [metric.agent_id], [errors: sum(value)]
          }
        | join
        | condition tokens > ${var.error_correlation_token_threshold} && errors > ${var.error_correlation_error_threshold}
      EOT

      duration = "${var.error_correlation_duration_seconds}s"

      trigger {
        count = 1
      }
    }
  }

  notification_channels = local.all_notification_channel_ids
}

# AL6 — optional absence alert when no llm_usage calls are recorded project-wide.
resource "google_monitoring_alert_policy" "llm_zero_traffic" {
  count = local.alerts_enabled && var.enable_alert_zero_traffic ? 1 : 0

  project      = var.project_id
  display_name = "Agent Observability AL6: zero llm_usage traffic"
  combiner     = "OR"
  enabled      = true

  documentation {
    content   = <<-EOT
      No `llm_usage` LLM calls recorded for ${var.zero_traffic_duration_seconds / 3600} hours.

      Check Reasoning Engine deploy, instrumentation (`jsonPayload.event="llm_usage"`), or upstream outage.
      ${local.alert_runbook_footer}
    EOT
    mime_type = "text/markdown"
  }

  conditions {
    display_name = "Project llm_usage call_count below 1"

    condition_threshold {
      filter          = "metric.type=\"logging.googleapis.com/user/lens_llm_call_count\" resource.type=\"aiplatform.googleapis.com/ReasoningEngine\""
      duration        = "${var.zero_traffic_duration_seconds}s"
      comparison      = "COMPARISON_LT"
      threshold_value = 1

      aggregations {
        alignment_period     = "900s"
        per_series_aligner   = "ALIGN_DELTA"
        cross_series_reducer = "REDUCE_SUM"
        group_by_fields      = []
      }

      trigger {
        count = 1
      }

      evaluation_missing_data = "EVALUATION_MISSING_DATA_ACTIVE"
    }
  }

  notification_channels = local.all_notification_channel_ids
}
