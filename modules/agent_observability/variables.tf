variable "project_id" {
  description = "GCP project for the Agent Observability dashboard."
  type        = string
}

variable "demo_project_placeholder" {
  description = "Placeholder string in dashboard JSON replaced with project_id."
  type        = string
  default     = "AGENT_GATEWAY_PROJECT_PLACEHOLDER"
}

variable "notification_channel_ids" {
  description = "Additional pre-existing notification channel resource names (email, PagerDuty, etc.)."
  type        = list(string)
  default     = []
}

variable "slack_channel_name" {
  description = "Slack channel for token alerts (e.g. #agentic-lens-alerts). Requires slack_auth_token."
  type        = string
  default     = ""
}

variable "slack_auth_token" {
  description = "Slack Bot User OAuth Token (xoxb-...) with chat:write and chat:write.public scopes."
  type        = string
  default     = ""
  sensitive   = true
}

variable "slack_display_name" {
  description = "Display name for the Terraform-managed Slack notification channel."
  type        = string
  default     = null
}

variable "google_chat_space" {
  description = "Google Chat space ID for token alerts (format: spaces/AAAA...). Add the Cloud Monitoring app to the space first."
  type        = string
  default     = ""
}

variable "google_chat_display_name" {
  description = "Display name for the Terraform-managed Google Chat notification channel."
  type        = string
  default     = null
}

variable "alert_email_address" {
  description = "AL7: email address for token alert notifications (creates a Monitoring email channel)."
  type        = string
  default     = ""
}

variable "alert_email_display_name" {
  description = "Display name for the Terraform-managed email notification channel."
  type        = string
  default     = null
}

variable "enable_token_alerts" {
  description = "Master switch for Agent Observability alert policies (requires notification channels)."
  type        = bool
  default     = true
}

variable "enable_alert_baseline_spike" {
  description = "AL1: per-agent spike vs 1-day baseline (percent change on 15-minute buckets)."
  type        = bool
  default     = true
}

variable "enable_alert_runaway_loop" {
  description = "AL2: suspected runaway LLM loop (high call count with elevated tokens)."
  type        = bool
  default     = true
}

variable "enable_alert_project_surge" {
  description = "AL3: project-wide Vertex token surge."
  type        = bool
  default     = true
}

variable "enable_alert_absolute_ceiling" {
  description = "AL4: per-agent absolute token ceiling per 15-minute bucket."
  type        = bool
  default     = true
}

variable "enable_alert_error_correlation" {
  description = "AL5: per-agent token spike correlated with llm_usage errors."
  type        = bool
  default     = true
}

variable "enable_alert_zero_traffic" {
  description = "AL6: no llm_usage traffic project-wide (instrumentation or outage signal)."
  type        = bool
  default     = false
}

variable "project_token_surge_threshold" {
  description = "AL3: total project tokens per 15-minute bucket before alerting."
  type        = number
  default     = 750000
}

variable "project_surge_duration_seconds" {
  description = "AL3: how long the surge must persist before firing."
  type        = number
  default     = 900
}

variable "per_agent_baseline_spike_percent" {
  description = "AL1: percent increase vs same 15-minute bucket one day ago before alerting (200 = 2× baseline)."
  type        = number
  default     = 200
}

variable "per_agent_baseline_spike_duration_seconds" {
  description = "AL1: how long the baseline spike must persist before firing."
  type        = number
  default     = 1800
}

variable "per_agent_absolute_ceiling_threshold" {
  description = "AL4: hard token ceiling per agent per 15-minute bucket."
  type        = number
  default     = 100000
}

variable "per_agent_absolute_ceiling_duration_seconds" {
  description = "AL4: how long the ceiling breach must persist before firing."
  type        = number
  default     = 1800
}

variable "runaway_loop_call_threshold" {
  description = "AL2: LLM calls per agent per 15-minute bucket indicating a possible loop."
  type        = number
  default     = 30
}

variable "runaway_loop_min_tokens" {
  description = "AL2: minimum tokens in the same bucket (avoids noise on tiny call counts)."
  type        = number
  default     = 5000
}

variable "runaway_loop_duration_seconds" {
  description = "AL2: how long the loop pattern must persist before firing."
  type        = number
  default     = 900
}

variable "error_correlation_token_threshold" {
  description = "AL5: tokens per 15-minute bucket when paired with errors."
  type        = number
  default     = 50000
}

variable "error_correlation_error_threshold" {
  description = "AL5: llm_usage error events per 15-minute bucket per agent."
  type        = number
  default     = 3
}

variable "error_correlation_duration_seconds" {
  description = "AL5: how long both conditions must persist before firing."
  type        = number
  default     = 900
}

variable "zero_traffic_duration_seconds" {
  description = "AL6: duration with zero llm_usage call_count before alerting."
  type        = number
  default     = 21600
}

# Deprecated aliases kept for backward-compatible tfvars.
variable "per_agent_token_spike_threshold" {
  description = "Deprecated: use per_agent_absolute_ceiling_threshold. Maps to AL4."
  type        = number
  default     = null
}

variable "per_agent_spike_duration_seconds" {
  description = "Deprecated: use per_agent_absolute_ceiling_duration_seconds. Maps to AL4."
  type        = number
  default     = null
}
