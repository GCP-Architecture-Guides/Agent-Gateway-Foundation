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
# 7. AGENT REGISTRY — ENDPOINT REGISTRATION + ACCESS POLICY
# ==============================================================================
# Registers every host in var.allowed_egress_hosts as a discoverable service
# endpoint in the Agent Registry, and grants the Vertex AI RE service agent
# roles/agentregistry.viewer so all deployed Reasoning Engines can discover
# these endpoints at runtime.
#
# WHY: allowed_egress_hosts drives two layers:
#   Layer 1 (network)  — PSC routing: hosts not in this list have no PSC route
#                        and are dropped by the egress gateway (deny-by-default).
#   Layer 2 (registry) — Agent Registry: each host is registered as a named
#                        service that agents can discover dynamically, removing
#                        the need to hardcode endpoint URLs in agent code.
#
# NOTE: google_agent_registry_service Terraform resource requires google-beta
# provider >= 7.42.0. This deployment runs 7.38.0, so we use null_resource +
# gcloud alpha agent-registry services create (confirmed-working pattern, same
# as the SGP engine lookup in 02_network.tf). When the provider is upgraded to
# >= 7.42.0, replace null_resource blocks with google_agent_registry_service.
# ==============================================================================

# ------------------------------------------------------------------------------
# Convert each hostname into a valid service-id (dots → hyphens).
# e.g. "api.github.com" → "api-github-com"
# ------------------------------------------------------------------------------
locals {
  # Map of hostname → sanitized service_id
  egress_host_ids = {
    for host in var.allowed_egress_hosts :
    host => replace(host, ".", "-")
  }
}

# ------------------------------------------------------------------------------
# Register each egress host as an Agent Registry service endpoint.
# Uses null_resource + local-exec because google_agent_registry_service
# requires provider >= 7.42.0 (installed: 7.38.0).
#
# Idempotent: the || true suppresses the "already exists" error on re-apply.
# The trigger is the host name — re-registers only if the host list changes.
# ------------------------------------------------------------------------------
resource "null_resource" "register_egress_endpoint" {
  for_each = local.egress_host_ids

  triggers = {
    host       = each.key
    service_id = each.value
    project    = var.project_id
    location   = var.location
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Registering ${each.key} in Agent Registry..."
      gcloud alpha agent-registry services create "${each.value}" \
        --project="${var.project_id}" \
        --location="${var.location}" \
        --display-name="${each.key}" \
        --description="Egress endpoint managed by Terraform. PSC-routed via ${var.prefix}-egress-gateway. Source: allowed_egress_hosts." \
        --endpoint-spec-type=no-spec \
        --interfaces="url=https://${each.key},protocolBinding=http-json" \
        --quiet 2>&1 || echo "  (already exists or non-fatal error — continuing)"
    EOT
  }

  # Deletion: de-register from Agent Registry when removed from allowed_egress_hosts
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "De-registering ${self.triggers.host} from Agent Registry..."
      gcloud alpha agent-registry services delete "${self.triggers.service_id}" \
        --project="${self.triggers.project}" \
        --location="${self.triggers.location}" \
        --quiet 2>&1 || echo "  (not found or already deleted — continuing)"
    EOT
  }

  depends_on = [google_project_service.agentregistry]
}

# ------------------------------------------------------------------------------
# IAM: Grant the Vertex AI RE service agent roles/agentregistry.viewer
# so all deployed Reasoning Engines can discover registered services at runtime.
#
# The RE service agent SA format:
#   service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com
# This SA is shared across all REs in the project — one grant covers all agents.
# ------------------------------------------------------------------------------
resource "google_project_iam_member" "re_agent_registry_viewer" {
  project = var.project_id
  role    = "roles/agentregistry.viewer"
  member  = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com"

  depends_on = [
    google_project_service.agentregistry,
    google_project_service.aiplatform,
  ]
}
