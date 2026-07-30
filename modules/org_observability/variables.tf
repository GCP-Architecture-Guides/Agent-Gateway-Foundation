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

variable "metrics_scope_project_id" {
  description = "Hub GCP project that owns the metrics scope and org dashboard."
  type        = string
}

variable "monitored_project_ids" {
  description = "Additional GCP projects to add to the hub metrics scope (hub project is always in scope)."
  type        = list(string)
  default     = []
}

variable "scope_project_agent_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Observability in the scope (hub) project."
  type        = string
  default     = ""
}

variable "scope_project_gateway_dashboard_id" {
  description = "Cloud Monitoring dashboard id for Agent Gateway Observability in the scope (hub) project."
  type        = string
  default     = ""
}
