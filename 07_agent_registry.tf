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
# Registers ALL egress hosts (foundation defaults + project-specific) as
# discoverable service endpoints in the Agent Registry, and grants:
#   1. roles/agentregistry.viewer        (project-level) — agents can LIST all endpoints
#   2. roles/agentregistry.endpointConsumer (per-endpoint) — agents explicitly
#      authorized to INVOKE each registered endpoint (granular, auditable, revocable)
#
# TWO classes of endpoints:
#   foundation_egress_hosts — standard GCP APIs required by any agent deployment.
#     Always registered regardless of var.allowed_egress_hosts. Teams never need
#     to add these manually.
#   var.allowed_egress_hosts — project-specific hosts (team APIs, 3rd-party services).
#     Merged with foundation defaults; deduplication handled by toset().
#
# WHY: all_egress_hosts drives three layers simultaneously:
#   Layer 1 (network)   — PSC routing: hosts not in this merged list have no PSC
#                         route and are dropped by the egress gateway (deny-by-default).
#   Layer 2 (registry)  — Agent Registry: each host is registered as a named
#                         service that agents can discover dynamically.
#   Layer 3 (IAM)       — Per-endpoint endpointConsumer grant: explicit, auditable
#                         IAM authorization per registered endpoint. Visible in
#                         console: Agent Registry -> Services -> [service] -> IAM tab.
#
# NOTE: google_agent_registry_service Terraform resource requires google-beta
# provider >= 7.42.0. This deployment runs 7.38.0, so we use null_resource +
# gcloud alpha agent-registry services create (confirmed-working pattern, same
# as the SGP engine lookup in 02_network.tf). When the provider is upgraded to
# >= 7.42.0, replace null_resource blocks with google_agent_registry_service.
# ==============================================================================

locals {
  # --------------------------------------------------------------------------
  # Foundation defaults: GCP APIs required by every agent deployment.
  # Always registered; teams never need to add these to var.allowed_egress_hosts.
  # --------------------------------------------------------------------------
  foundation_egress_hosts = [
    "aiplatform.googleapis.com",                   # Vertex AI global (Gemini 3.x, RE control plane)
    "${var.location}-aiplatform.googleapis.com",   # Vertex AI regional (Gemini 2.x)
    "iamcredentials.googleapis.com",               # WIF token exchange
    "oauth2.googleapis.com",                       # OAuth token refresh
    "cloudresourcemanager.googleapis.com",         # Project/org lookups
    "logging.googleapis.com",                      # Cloud Logging (OTEL log export)
    "cloudtrace.googleapis.com",                   # Cloud Trace (OTEL trace export)
    "monitoring.googleapis.com",                   # Cloud Monitoring (metrics export)
    "storage.googleapis.com",                      # GCS (staging bucket, artifacts)
    "secretmanager.googleapis.com",                # Secret Manager (agent credentials)
    "agentregistry.googleapis.com",                # Agent Registry API (dynamic discovery)
    "telemetry.googleapis.com",                    # OTEL telemetry endpoint
  ]

  # Merge foundation defaults + project-specific hosts.
  # toset() deduplicates — safe if a project host already appears in foundation list.
  all_egress_hosts = toset(concat(local.foundation_egress_hosts, var.allowed_egress_hosts))

  # Map of hostname -> sanitized service_id (dots -> hyphens)
  # e.g. "api.github.com" -> "api-github-com"
  all_egress_host_ids = {
    for host in local.all_egress_hosts :
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
  for_each = local.all_egress_host_ids

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
        --description="Egress endpoint managed by Terraform. PSC-routed via ${var.prefix}-egress-gateway." \
        --endpoint-spec-type=no-spec \
        --interfaces="url=https://${each.key},protocolBinding=http-json" \
        --quiet 2>&1 || echo "  (already exists or non-fatal error -- continuing)"
      # NOTE: The Agent Registry API (gcloud alpha) only accepts ONE --interfaces
      # entry per create call. Multiple --interfaces flags cause a fieldViolations
      # error on service.interfaces[1]. The gateway matches by hostname (FQDN
      # from PSC DNS override), not by protocol binding -- http-json is sufficient
      # to register the host in the allowlist. If grpc-specific bindings are
      # needed in future, use the REST API directly: PATCH /v1beta1/.../services
      # with a full interfaces[] JSON array body.
    EOT
  }

  # Deletion: de-register from Agent Registry when removed from host lists
  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "De-registering ${self.triggers.host} from Agent Registry..."
      gcloud alpha agent-registry services delete "${self.triggers.service_id}" \
        --project="${self.triggers.project}" \
        --location="${self.triggers.location}" \
        --quiet 2>&1 || echo "  (not found or already deleted -- continuing)"
    EOT
  }

  depends_on = [google_project_service.agentregistry]
}

# ------------------------------------------------------------------------------
# IAM (project-level): Grant the Vertex AI RE service agent roles/agentregistry.viewer
# so all deployed Reasoning Engines can LIST and DISCOVER registered services at runtime.
#
# IMPORTANT: The SA service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com
# is a Google-managed service agent that is only created when the FIRST Reasoning Engine
# is deployed in the project. It does NOT exist on a fresh project, so a
# google_project_iam_member resource would fail with "SA does not exist" on initial apply.
#
# Fix: null_resource + gcloud with || true (idempotent):
#   - Fresh project (SA doesn't exist yet): gcloud fails gracefully (|| true)
#   - After first RE deploy: SA exists; re-run terraform apply to apply the grant.
# ------------------------------------------------------------------------------
resource "null_resource" "re_agent_registry_viewer" {
  triggers = {
    project = var.project_id
    number  = data.google_project.project.number
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Granting roles/agentregistry.viewer to RE service agent..."
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="serviceAccount:service-${data.google_project.project.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
        --role="roles/agentregistry.viewer" \
        --quiet 2>&1 || echo "  (SA not yet created -- will be granted after first RE deploy; continuing)"
    EOT
  }

  depends_on = [
    google_project_service.agentregistry,
    google_project_service.aiplatform,
  ]
}

# ------------------------------------------------------------------------------
# IAM (per-endpoint): Grant roles/agentregistry.endpointConsumer to the RE service agent
# on EACH registered endpoint individually.
#
# WHY per-endpoint IAM (in addition to project-level viewer above)?
#   agentregistry.viewer (project-level): agents can LIST/DISCOVER all services.
#   agentregistry.endpointConsumer (per-service): agents explicitly authorized to
#     INVOKE each specific endpoint. Visible in GCP Console:
#     Agent Registry -> Services -> [service name] -> IAM tab.
#     Granular, auditable, and revocable per endpoint — not a broad project grant.
#
# CURRENT STATUS: roles/agentregistry.endpointConsumer is in preview (gcloud alpha).
# Using null_resource + local-exec (same pattern as endpoint registration above).
# Idempotent: || true suppresses "already bound" errors.
#
# SA lifecycle note: same caveat as re_agent_registry_viewer — the RE service agent
# may not exist on a fresh project. The || true handles this gracefully; the grant
# will be applied on the next terraform apply after the first RE is deployed.
#
# Future: when roles/agentregistry.endpointConsumer reaches GA, replace with
# google_agent_registry_service_iam_member for native Terraform state tracking.
# ------------------------------------------------------------------------------
resource "null_resource" "endpoint_iam_consumer" {
  for_each = local.all_egress_host_ids

  triggers = {
    host       = each.key
    service_id = each.value
    project    = var.project_id
    location   = var.location
    number     = data.google_project.project.number
  }

  provisioner "local-exec" {
    command = <<-EOT
      echo "Granting endpointConsumer on ${each.key} to RE service agent..."
      gcloud alpha agent-registry services add-iam-policy-binding "${each.value}" \
        --project="${var.project_id}" \
        --location="${var.location}" \
        --member="serviceAccount:service-${data.google_project.project.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
        --role="roles/agentregistry.endpointConsumer" \
        --quiet 2>&1 || echo "  (SA not yet created or already bound -- continuing)"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      echo "Removing endpointConsumer on ${self.triggers.host}..."
      gcloud alpha agent-registry services remove-iam-policy-binding "${self.triggers.service_id}" \
        --project="${self.triggers.project}" \
        --location="${self.triggers.location}" \
        --member="serviceAccount:service-${self.triggers.number}@gcp-sa-aiplatform-re.iam.gserviceaccount.com" \
        --role="roles/agentregistry.endpointConsumer" \
        --quiet 2>&1 || echo "  (not found -- continuing)"
    EOT
  }

  depends_on = [
    null_resource.register_egress_endpoint,
    null_resource.re_agent_registry_viewer,
  ]
}
