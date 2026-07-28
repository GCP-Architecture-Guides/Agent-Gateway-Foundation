resource "google_monitoring_notification_channel" "slack" {
  count = var.slack_channel_name != "" && var.slack_auth_token != "" ? 1 : 0

  project      = var.project_id
  display_name = coalesce(var.slack_display_name, "Agent Observability — Slack")
  type         = "slack"

  labels = {
    channel_name = var.slack_channel_name
  }

  sensitive_labels {
    auth_token = var.slack_auth_token
  }
}

resource "google_monitoring_notification_channel" "google_chat" {
  count = var.google_chat_space != "" ? 1 : 0

  project      = var.project_id
  display_name = coalesce(var.google_chat_display_name, "Agent Observability — Google Chat")
  type         = "google_chat"

  labels = {
    space = var.google_chat_space
  }
}

resource "google_monitoring_notification_channel" "email" {
  count = var.alert_email_address != "" ? 1 : 0

  project      = var.project_id
  display_name = coalesce(var.alert_email_display_name, "Agent Observability — Email")
  type         = "email"

  labels = {
    email_address = var.alert_email_address
  }
}

locals {
  notification_channels_configured = (
    var.google_chat_space != ""
    || (var.slack_channel_name != "" && var.slack_auth_token != "")
    || var.alert_email_address != ""
    || length(var.notification_channel_ids) > 0
  )

  managed_notification_channel_ids = concat(
    [for ch in google_monitoring_notification_channel.slack : ch.id],
    [for ch in google_monitoring_notification_channel.google_chat : ch.id],
    [for ch in google_monitoring_notification_channel.email : ch.id],
  )

  all_notification_channel_ids = distinct(concat(
    local.managed_notification_channel_ids,
    var.notification_channel_ids,
  ))

  absolute_ceiling_threshold = coalesce(
    var.per_agent_token_spike_threshold,
    var.per_agent_absolute_ceiling_threshold,
  )

  absolute_ceiling_duration_seconds = coalesce(
    var.per_agent_spike_duration_seconds,
    var.per_agent_absolute_ceiling_duration_seconds,
  )
}
