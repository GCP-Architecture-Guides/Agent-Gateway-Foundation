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

# ==============================================================================
# MODULE INTERFACE OUTPUTS
# When this repo is used as a Terraform module by another project, these outputs
# provide everything needed to bind agents to the shared security platform.
#
# Usage in consuming project:
#   module.agw_foundation.ingress_gateway_name  → agentGatewayConfig.clientToAgentConfig
#   module.agw_foundation.egress_gateway_name   → agentGatewayConfig.agentToAnywhereConfig
#   module.agw_foundation.model_armor_template_high_id → custom MA template references
# ==============================================================================

# --- Network ---
output "network_id" {
  value       = google_compute_network.vpc.id
  description = "The ID of the VPC network."
}

output "intf_subnet_id" {
  value       = google_compute_subnetwork.intf_subnet.id
  description = "The ID of the interface subnet."
}

output "psc_network_attachment" {
  value       = google_compute_network_attachment.psc_network_attachment.id
  description = "The ID of the PSC network attachment for egress."
}

# --- Gateways (IDs for Terraform references) ---
output "ingress_gateway_id" {
  value       = google_network_services_agent_gateway.ingress_gateway.id
  description = "The Terraform resource ID of the ingress Agent Gateway."
}

output "egress_gateway_id" {
  value       = google_network_services_agent_gateway.egress_gateway.id
  description = "The Terraform resource ID of the egress Agent Gateway."
}

# --- Gateway Names (resource paths for agentGatewayConfig — use these in RE deployments) ---
output "ingress_gateway_name" {
  value       = "projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-ingress-gateway"
  description = "Full resource path for agentGatewayConfig.clientToAgentConfig.agentGateway."
}

output "egress_gateway_name" {
  value       = "projects/${var.project_id}/locations/${var.location}/agentGateways/${var.prefix}-egress-gateway"
  description = "Full resource path for agentGatewayConfig.agentToAnywhereConfig.agentGateway."
}

# --- Model Armor ---
output "model_armor_template_id" {
  value       = google_model_armor_template.security_high.id
  description = "The ID of the Model Armor high security template (for user prompt screening)."
}

# NOTE: model_armor_template_responses_id intentionally absent.
# Response template screening causes false-positive 403 on :streamQuery responses
# (gRPC-HTTP transcoding format triggers PI/Jailbreak filter). Model output safety
# is handled by Gemini built-in harm filters. See KNOWN_ISSUES.md #001.

# --- IAP Service Extension ---
output "iap_extension_id" {
  value       = google_network_services_authz_extension.iap_extension.id
  description = "The ID of the IAP authz extension (REQUEST_AUTHZ service identity validation)."
}

output "ingress_iap_policy_id" {
  value       = google_network_security_authz_policy.ingress_iap_policy.id
  description = "The ID of the IAP REQUEST_AUTHZ policy on the ingress gateway."
}

# --- Authz Policy Summary ---
# Ingress gateway (CLIENT_TO_AGENT):
#   ├── REQUEST_AUTHZ → IAP (validates caller service identity)
#   └── CONTENT_AUTHZ → Model Armor (prompt/content screening)
# Egress gateway (AGENT_TO_ANYWHERE):
#   ├── REQUEST_AUTHZ → IAP (validates agent service identity on outbound)
#   ├── CONTENT_AUTHZ → Model Armor (AI call screening)
#   └── CONTENT_AUTHZ → SGP (semantic governance policy)
# Note: CLIENT_TO_AGENT hard limit — at most 1 CONTENT_AUTHZ per ingress gateway.
# SGP ingress policy is not possible; see 03_security_and_gateways.tf.
output "egress_sgp_policy_id" {
  value       = google_network_security_authz_policy.egress_sgp_policy.id
  description = "The ID of the SGP CONTENT_AUTHZ policy on the egress gateway."
}

output "egress_iap_policy_id" {
  value       = google_network_security_authz_policy.egress_iap_policy.id
  description = "The ID of the IAP REQUEST_AUTHZ policy on the egress gateway (validates agent service identity)."
}

# --- Agent Registry ---
output "registered_egress_endpoints" {
  value       = { for host, sid in local.egress_host_ids : host => sid }
  description = "Map of hostname → Agent Registry service_id for all hosts registered from allowed_egress_hosts."
}

output "re_agent_registry_viewer" {
  value       = google_project_iam_member.re_agent_registry_viewer.member
  description = "The RE service agent identity granted roles/agentregistry.viewer (can discover all registered endpoints)."
}

# --- Project ---
output "project_number" {
  value       = data.google_project.project.number
  description = "Numeric GCP project number — required for direct REST API calls to Vertex AI."
}

# --- Observability ---
output "agent_observability_dashboard_id" {
  value       = module.agent_observability.dashboard_id
  description = "The ID of the Agent Observability dashboard."
}

output "gateway_observability_dashboard_id" {
  value       = module.gateway_observability.dashboard_id
  description = "The ID of the Gateway Observability dashboard."
}
