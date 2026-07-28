resource "google_monitoring_notification_channel" "security_google_chat" {
  count = var.security_google_chat_space != "" ? 1 : 0

  project      = var.project_id
  display_name = coalesce(var.security_google_chat_display_name, "Agent Gateway Observability — Security Google Chat")
  type         = "google_chat"

  labels = {
    space = var.security_google_chat_space
  }
}

locals {
  security_notification_channels_configured = (
    var.security_google_chat_space != ""
    || length(var.security_notification_channel_ids) > 0
  )

  managed_security_notification_channel_ids = [
    for ch in google_monitoring_notification_channel.security_google_chat : ch.id
  ]

  all_security_notification_channel_ids = distinct(concat(
    local.managed_security_notification_channel_ids,
    var.security_notification_channel_ids,
  ))
}
