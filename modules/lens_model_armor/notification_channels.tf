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
