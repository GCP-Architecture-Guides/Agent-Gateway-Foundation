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

variable "project_id" {
  type = string
}

variable "cloud_run_service_name" {
  type = string
}

variable "armor_layers" {
  type        = list(string)
  description = "Model Armor enforcement layers to emit metrics for."
  default     = ["api", "supervisor", "gateway_ingress"]
}

variable "security_google_chat_space" {
  description = "Google Chat space for Model Armor security alerts (format: spaces/AAAA...). Add the Cloud Monitoring app to the space first."
  type        = string
  default     = ""
}

variable "security_google_chat_display_name" {
  description = "Display name for the Terraform-managed security Google Chat notification channel."
  type        = string
  default     = null
}

variable "security_notification_channel_ids" {
  description = "Pre-existing Cloud Monitoring notification channel IDs for security alerts (alternative to security_google_chat_space)."
  type        = list(string)
  default     = []
}

variable "enable_model_armor_security_alerts" {
  description = "Create Model Armor security alert policies when a security notification channel is configured."
  type        = bool
  default     = true
}

variable "prompt_injection_alert_threshold" {
  description = "Alert when prompt injection matches in a window reach this count (default 10 per minute)."
  type        = number
  default     = 10
}

variable "prompt_injection_alert_window_seconds" {
  description = "Rolling window for counting prompt injection matches."
  type        = number
  default     = 60
}

variable "prompt_injection_alert_duration_seconds" {
  description = "How long the threshold breach must persist before firing (0 = immediate)."
  type        = number
  default     = 0
}
