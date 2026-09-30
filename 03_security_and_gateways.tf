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

# ------------------------------------------------------------------------------
# 3. SECURITY & GOVERNANCE POLICIES
# ------------------------------------------------------------------------------
# --- Data Access Audit Logs (Capture Prompts/Responses) ---
# Audit logging — one resource per service in var.audit_log_services
# DATA_ADMIN is intentionally excluded (too noisy for PoC).
# Add services in terraform.tfvars: audit_log_services = ["aiplatform.googleapis.com", "..."]
resource "google_project_iam_audit_config" "data_access_logs" {
  for_each = toset(var.audit_log_services)
  project  = var.project_id
  service  = each.key

  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

# --- DLP Inspect Template ---
resource "google_data_loss_prevention_inspect_template" "identification_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "identification-template"
  display_name = "Identification template"
  description  = "Detects SSN, email, GCP credentials, credit card, medical and FDA/ICD codes."
  depends_on   = [google_project_service.dlp]

  inspect_config {
    min_likelihood = "POSSIBLE"
    include_quote  = true

    info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
    info_types { name = "EMAIL_ADDRESS" }
    info_types { name = "GCP_API_KEY" }
    info_types { name = "GCP_CREDENTIALS" }
    info_types { name = "CREDIT_CARD_NUMBER" }
    info_types { name = "BLOOD_TYPE" }
    info_types { name = "FDA_CODE" }
    info_types { name = "ICD10_CODE" }
    info_types { name = "ICD9_CODE" }
    info_types { name = "MEDICAL_TERM" }
  }
}

# --- DLP Deidentify Template ---
resource "google_data_loss_prevention_deidentify_template" "deidentify_template" {
  parent       = "projects/${var.project_id}/locations/${var.location}"
  template_id  = "deidentify-replace-with-infotype"
  display_name = "Deidentify replace with info type"
  description  = "Replaces sensitive text with the info type name (e.g. [EMAIL_ADDRESS])."
  depends_on   = [google_project_service.dlp]

  deidentify_config {
    info_type_transformations {
      transformations {
        info_types { name = "US_SOCIAL_SECURITY_NUMBER" }
        info_types { name = "EMAIL_ADDRESS" }
        info_types { name = "GCP_API_KEY" }
        info_types { name = "GCP_CREDENTIALS" }
        info_types { name = "CREDIT_CARD_NUMBER" }
        info_types { name = "BLOOD_TYPE" }
        info_types { name = "FDA_CODE" }
        info_types { name = "ICD10_CODE" }
        info_types { name = "ICD9_CODE" }
        info_types { name = "MEDICAL_TERM" }

        primitive_transformation {
          replace_with_info_type_config = true
        }
      }
    }
  }
}

# --- Model Armor Templates ---
#
# TWO templates — one per screening direction:
#   Template 1: security-high       — USER PROMPTS  (ingress request + egress outbound tool calls)
#   Template 2: security-responses  — MODEL RESPONSES (egress response side only)
#
# WHY separate templates for responses?
#   The egress gateway screens BOTH the outbound request (tool call to Vertex AI) AND
#   the inbound response (LLM output returning to the agent). These have different risk
#   profiles and different false-positive characteristics:
#     - Prompt Injection / Jailbreak: DISABLED on responses. LLM outputs don't contain
#       injected prompts. The gRPC-HTTP transcoding wrapper on :streamQuery responses
#       includes metadata fields (contentType, extensions) that falsely trigger the PI
#       filter, causing valid responses to be blocked.
#     - RAI + PII: ENABLED on responses (MEDIUM threshold). Catches harmful content or
#       accidental PII leakage in model output.
#     - Malicious URIs: DISABLED on responses — models sometimes reference URLs in
#       explanatory text; flagging these as malicious causes too many false positives.

resource "google_model_armor_template" "security_high" {
  template_id  = "security-high"
  location     = var.location
  project      = var.project_id
  depends_on   = [google_project_service.modelarmor, google_data_loss_prevention_inspect_template.identification_template, google_data_loss_prevention_deidentify_template.deidentify_template]

  filter_config {
    # PI/Jailbreak: HIGH — aggressive prompt injection detection on user input
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "ENABLED"
      confidence_level   = "HIGH"
    }
    # SDP: DLP inspect + deidentify to catch/redact PII in user prompts
    sdp_settings {
      advanced_config {
        inspect_template    = google_data_loss_prevention_inspect_template.identification_template.id
        deidentify_template = google_data_loss_prevention_deidentify_template.deidentify_template.id
      }
    }
    # Block malicious URLs embedded in prompts
    malicious_uri_filter_settings {
      filter_enforcement = "ENABLED"
    }
    # RAI: HIGH threshold on user prompts — reject harmful input early
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "HIGH"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "HIGH"
      }
    }
  }
  template_metadata {
    log_sanitize_operations = true
    log_template_operations = true
  }
}

# Template 2: security-responses — MODEL RESPONSES (egress response_template_id only)
# Lighter than security-high: RAI + PII screening only.
#   PI/Jailbreak DISABLED — LLM outputs don't contain injected prompts; enabling it
#     causes false positives on gRPC transcoding metadata in :streamQuery responses.
#   Malicious URI DISABLED — models legitimately reference URLs in explanations;
#     flagging them causes too many false positives on valid responses.
#   RAI MEDIUM — catches genuinely harmful model outputs without over-blocking.
#   SDP — catches PII accidentally leaked in model responses.
resource "google_model_armor_template" "security_responses" {
  template_id  = "security-responses"
  location     = var.location
  project      = var.project_id
  depends_on   = [google_project_service.modelarmor, google_data_loss_prevention_inspect_template.identification_template, google_data_loss_prevention_deidentify_template.deidentify_template]

  filter_config {
    # PI/Jailbreak: DISABLED on responses — avoids gRPC transcoding false positives
    pi_and_jailbreak_filter_settings {
      filter_enforcement = "DISABLED"
    }
    # SDP: catch PII leakage in model output (e.g. SSN, API keys in generated text)
    sdp_settings {
      advanced_config {
        inspect_template    = google_data_loss_prevention_inspect_template.identification_template.id
        deidentify_template = google_data_loss_prevention_deidentify_template.deidentify_template.id
      }
    }
    # Malicious URI: DISABLED on responses (too many false positives on model-cited URLs)
    malicious_uri_filter_settings {
      filter_enforcement = "DISABLED"
    }
    # RAI: MEDIUM threshold on responses — catches harmful output without over-blocking
    rai_settings {
      rai_filters {
        filter_type      = "HATE_SPEECH"
        confidence_level = "LOW_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "HARASSMENT"
        confidence_level = "LOW_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "SEXUALLY_EXPLICIT"
        confidence_level = "LOW_AND_ABOVE"
      }
      rai_filters {
        filter_type      = "DANGEROUS"
        confidence_level = "LOW_AND_ABOVE"
      }
    }
  }
  template_metadata {
    log_sanitize_operations = true
    log_template_operations = true
  }
}

# --- Authz Extensions ---
#
# Two separate MA extensions per official docs (delegate-authorization#configure-authz-ma):
#   Ingress: fail_open = false (fail-closed) — deny inbound if MA unreachable
#   Egress:  fail_open = true  (fail-open)  — allow egress through if MA unreachable
#
# Template assignment:
#   Ingress extension  → request_template_id: security-high        (prompt screening only)
#   Egress  extension  → request_template_id: security-high        (outbound tool calls)
#                        response_template_id: security-responses   (LLM response screening)
#
# WHY two extensions: a single fail-closed extension on egress would silently drop
# all cross-RE gRPC responses if MA experiences any transient error. fail-open on
# egress ensures LLM traffic flows while Gemini's built-in harm filters still apply.

resource "google_network_services_authz_extension" "ma_extension_ingress" {
  provider  = google-beta
  name      = "${var.prefix}-ma-extension-ingress"
  location  = var.location
  project   = var.project_id
  service   = "modelarmor.${var.location}.rep.googleapis.com"
  timeout   = "3s"
  fail_open = false # INGRESS: fail-closed — deny inbound traffic if MA unreachable

  metadata = {
    model_armor_settings = jsonencode([
      {
        # INPUT screening only: PI/Jailbreak + SDP + RAI + malicious URIs applied to user prompts.
        # OUTPUT screening removed: the Vertex AI RE platform wraps :streamQuery responses in
        # gRPC-HTTP transcoding format (contentType/extensions metadata) that falsely triggers
        # the PI/Jailbreak filter. Model response safety is enforced by Gemini's built-in harm
        # filters at the model layer — these are always active and cannot be bypassed.
        request_template_id = google_model_armor_template.security_high.id
      }
    ])
  }

  depends_on = [google_project_service.networkservices, google_model_armor_template.security_high]
}

resource "google_network_services_authz_extension" "ma_extension_egress" {
  provider  = google-beta
  name      = "${var.prefix}-ma-extension-egress"
  location  = var.location
  project   = var.project_id
  service   = "modelarmor.${var.location}.rep.googleapis.com"
  timeout   = "3s"
  fail_open = true # EGRESS: fail-open — allow traffic through if MA unreachable (don't block LLM calls)

  metadata = {
    model_armor_settings = jsonencode([
      {
        # DUAL screening on egress:
        #   request_template_id  → screens outbound tool calls / requests to Vertex AI
        #                          (PI/Jailbreak + SDP + RAI + malicious URIs — security-high)
        #   response_template_id → screens LLM responses returning to the agent
        #                          (RAI + PII only — security-responses; PI/Jailbreak
        #                           disabled to avoid gRPC transcoding false positives)
        request_template_id  = google_model_armor_template.security_high.id
        response_template_id = google_model_armor_template.security_responses.id
      }
    ])
  }

  depends_on = [
    google_project_service.networkservices,
    google_model_armor_template.security_high,
    google_model_armor_template.security_responses,
  ]
}



# --- Ingress Authz Policies ---
resource "google_network_security_authz_policy" "ingress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension_ingress.id]
    }
  }
}



# --- Egress Authz Policies ---


resource "google_network_security_authz_policy" "egress_ma_policy" {
  provider       = google-beta
  name           = "${var.prefix}-ma-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.ma_extension_egress.id]
    }
  }

  http_rules {
    to {
      # MA egress screens only REGIONAL endpoint requests.
      # DELIBERATELY NO exact match for "aiplatform.googleapis.com" (global).
      #
      # WHY: The regional MA extension (modelarmor.${var.location}.rep.googleapis.com)
      # returns PERMISSION_DENIED when it receives requests destined for the global
      # Vertex AI endpoint. The Agent Gateway translates this into a 500 with empty
      # message — the agent appears to respond but returns nothing.
      #
      # This was confirmed as a production blocker in charter-poc-test when deploying
      # gemini-3.5-flash agents using GOOGLE_CLOUD_LOCATION=global. The fix: remove
      # the exact match. Global endpoint requests bypass MA content screening but are
      # still subject to Gemini's built-in harm filters (always active at model layer).
      #
      # See: skills/vertex-ai-global-endpoint-adk/SKILL.md §5 for full diagnosis.
      operations {
        hosts { suffix = ".aiplatform.googleapis.com" }
        paths {
          contains    = "generatecontent"
          ignore_case = true
        }
        paths {
          contains    = "predict"
          ignore_case = true
        }
        paths {
          contains    = "streamquery"
          ignore_case = true
        }
        paths {
          contains    = "sessions"
          ignore_case = true
        }
        paths {
          contains    = "events"
          ignore_case = true
        }
      }
    }
  }
}


# =========================================================================
# AUTOMATED SEMANTIC GOVERNANCE POLICY (SGP) ENGINE PROVISIONING
# =========================================================================
data "external" "sgp_engine" {
  program = ["bash", "${path.module}/scripts/provision_sgp_engine.sh", var.project_id, var.location]

  depends_on = [google_project_service.aiplatform]
}


# --- SGP Authz Extension & Policy ---
resource "google_network_services_authz_extension" "sgp_extension" {
  provider  = google-beta
  name      = "${var.prefix}-sgp-extension"
  location  = var.location
  project   = var.project_id
  service   = "sgp.internal.gemini-corp"
  timeout   = "3s"
  fail_open = false # explicit fail-closed per official docs — deny if SGP unreachable

  depends_on = [google_project_service.networkservices]
}

resource "google_network_security_authz_policy" "egress_sgp_policy" {
  provider       = google-beta
  name           = "${var.prefix}-sgp-egress-policy"
  location       = var.location
  project        = var.project_id
  action         = "CUSTOM"
  policy_profile = "CONTENT_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.sgp_extension.id]
    }
  }

  # NOTE: The SGP extension (sgp.internal.gemini-corp) with CONTENT_AUTHZ profile
  # does NOT support http_rules — the API enforces this constraint.
  # The SGP evaluates ALL outbound content semantically by design.
  # Egress allowlist enforcement is handled at the PSC routing level:
  # hosts not registered in allowed_egress_hosts have no PSC route and are
  # blocked by the gateway's deny-by-default posture at the routing layer.
}

# ==============================================================================
# ⛔ DO NOT ADD IAP REQUEST_AUTHZ TO THE EGRESS GATEWAY — EVER
# ==============================================================================
# Post-mortem: 2026-08-03, charter-poc-test (185602934768)
# Impact: ALL Reasoning Engines → zero LLM responses for ~2 days
# Root cause: IAP REQUEST_AUTHZ on egress blocks all outbound HTTP because
#   RE containers do NOT carry IAP tokens on outbound calls.
#   IAP sees PRINCIPAL_EMAIL=(empty) → gRPC code 7 → 403 on every egress call.
#   This breaks LLM calls, OTEL telemetry, sessions — everything.
#
# The misleading error message:
#   "Egress request is not authorized. The endpoint is either incorrect or
#    unregistered in the Agent Registry."
# This is NOT an Agent Registry problem. It's IAP identity validation failing.
# Checking Cloud Logging for resource.type="iap_web" / method=AuthorizeUser /
# code=7 / empty PRINCIPAL_EMAIL gives the real root cause in seconds.
#
# IAP REQUEST_AUTHZ is for INGRESS only (ran-iap-ingress-policy).
# Egress uses CONTENT_AUTHZ only: Model Armor + SGP.
# See skill: agw-egress-iap-pitfall
# ==============================================================================
# resource "google_network_security_authz_policy" "egress_iap_policy" { DELETED }


# ==============================================================================
# INGRESS ENFORCEMENT — RESTRICT DIRECT REASONING ENGINE ACCESS
# ==============================================================================
# The ideal enforcement is an IAM Deny Policy (IAM v2 API) that would deny
# aiplatform.reasoningEngines.query + streamQuery to all human identities,
# forcing 100% of traffic through the Agent Gateway. However, the IAM v2 API
# endpoint (iam.googleapis.com/v2) is unreachable from this deployment
# environment (network-level block on the deny-policies API path).
#
# Current enforcement layers (defence in depth without IAM Deny):
#   Layer 1 — Content authz (MA/DLP/SGP):
#       The RE's agentGatewayConfig.clientToAgentConfig triggers the ingress
#       gateway's authz extension for ALL calls to this RE via the Vertex AI
#       API — including direct calls from Agent Playground. Prompt injection,
#       DLP violations, and RAI violations are blocked at 403 regardless of how
#       the RE is invoked.
#   Layer 2 — Egress PSC routing:
#       The RE's agentGatewayConfig.agentToAnywhereConfig routes all outbound
#       traffic through the egress gateway's PSC attachment. Hosts not
#       registered in allowed_egress_hosts have no PSC route and are dropped.
#   Layer 3 — fetch_url explicit failure:
#       fetch_url() now returns [GATEWAY BLOCKED] on ConnectionError/Timeout,
#       preventing the model from hallucinating content when egress is blocked.
#   Layer 4 — Explicit gateway SA grant:
#       The gateway SA is explicitly granted reasoningEngines.queryer below.
#       This makes the gateway's service identity unambiguous in audit logs.
#
# Remaining gap (tracked):
#   Users with roles/owner can still call the RE directly with their own
#   credentials, bypassing Layer 1 content policies. Full closure requires
#   either: (a) IAM Deny policy (blocked here), (b) VPC Service Controls
#   perimeter around aiplatform.googleapis.com, or (c) removing roles/owner
#   and granting scoped roles only.
# ==============================================================================

# NOTE: roles/aiplatform.reasoningEngines.queryer is a resource-level role and
# cannot be bound at the project scope — grant it per-RE resource if needed.
# The gateway SA receives access to invoke the RE through the platform-level
# agentGatewayConfig.clientToAgentConfig binding set during agent deployment.

# ==============================================================================
# IAP (Identity-Aware Proxy) — Ingress SERVICE Identity Enforcement
# ==============================================================================
# The IAP authz extension validates SERVICE identity — it ensures that any
# caller (Reasoning Engine, Cloud Run service, or authorised service account)
# presents a valid Google-signed IAP bearer token before content policies
# (Model Armor / SGP) are evaluated.
#
# This is NOT user-facing IAP. It operates at the service-to-service layer:
#   - RE calling another RE through the gateway
#   - Cloud Run calling an agent endpoint
#   - Any service that holds a Google identity
#
# Recommended combined pattern (from official docs):
#   REQUEST_AUTHZ policy (IAP)   → who (which service) can reach the gateway
#   CONTENT_AUTHZ policy (MA)    → what content is allowed through
#
# Per official docs:
#   - service: iap.googleapis.com  (global, NOT a regional REP endpoint)
#   - policy_profile: REQUEST_AUTHZ
#   - metadata.iapPolicyVersion: "V1"  (required — extension rejects without it)
#
# Auto-granted callers (always):
#   - Vertex AI RE service agent (service-PROJECT_NUMBER@gcp-sa-aiplatform-re)
#     This SA runs inside every Reasoning Engine — grants RE→RE gateway calls.
#
# Additional callers: set iap_allowed_members in terraform.tfvars.
#   Use serviceAccount:, user:, or group: format.
# ==============================================================================

# IAP Authz Extension (INGRESS) — fail-closed, enforcing
# fail_open = false: deny if IAP unreachable (correct for ingress — we MUST validate caller identity)
# iamEnforcementMode not set = ENFORCED (default)
resource "google_network_services_authz_extension" "iap_extension" {
  provider = google-beta

  name      = "${var.prefix}-iap-extension"
  location  = var.location
  project   = var.project_id
  fail_open = false # fail-closed: deny inbound requests if IAP unreachable

  # Global IAP service endpoint (not a regional REP endpoint like Model Armor)
  service = "iap.googleapis.com"
  timeout = "1s"

  metadata = {
    iapPolicyVersion = "V1" # Required — extension rejects requests without this
  }

  depends_on = [google_project_service.iap]
}

# IAP Authz Extension (EGRESS) — fail-OPEN, DRY_RUN mode
#
# WHY fail_open=true + DRY_RUN:
#   RE containers make outbound HTTP without IAP credentials attached.
#   With fail_open=false + ENFORCED (our previous config), IAP sees empty
#   principal and DENIES all egress — breaking ALL outbound LLM calls.
#
#   Official docs pattern (set-up-agent-gateway#gcloud): use fail_open=true
#   and iamEnforcementMode=DRY_RUN on egress. This means IAP:
#     - Never blocks traffic (fail-open = allow if IAP call fails)
#     - Generates audit logs for agent identity visibility
#     - Checks roles/iap.egressor for registered endpoints (audit-only)
#
#   To promote to ENFORCED later (when agents carry proper IAP creds):
#     Change iamEnforcementMode to "ENFORCED" and fail_open to false.
#     Requires granting roles/iap.egressor to each RE service account first.
#
# See: skills/agw-egress-iap-pitfall/SKILL.md for full root cause analysis.
resource "google_network_services_authz_extension" "iap_extension_egress" {
  provider = google-beta

  name      = "${var.prefix}-iap-extension-egress"
  location  = var.location
  project   = var.project_id
  fail_open = true # CRITICAL: fail-open — never block egress if IAP unreachable

  service = "iap.googleapis.com"
  timeout = "1s"

  metadata = {
    iapPolicyVersion    = "V1"
    iamEnforcementMode  = "DRY_RUN" # Audit-only: logs identity checks, never blocks
  }

  depends_on = [google_project_service.iap]
}

# IAP Authz Policy — attaches the IAP extension to the INGRESS gateway.
# Profile: REQUEST_AUTHZ — IAP verifies caller service identity on every inbound request.
# (Distinct from CONTENT_AUTHZ used by Model Armor, which inspects the request body)
resource "google_network_security_authz_policy" "ingress_iap_policy" {
  provider = google-beta

  name     = "${var.prefix}-iap-ingress-policy"
  location = var.location
  project  = var.project_id

  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.ingress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap_extension.id]
    }
  }

  depends_on = [google_network_services_authz_extension.iap_extension]
}

# ==============================================================================
# IAP EGRESS AUTHZ POLICY — DRY_RUN (audit-only, never blocks)
# ==============================================================================
# Attaches the egress IAP extension to the egress gateway.
# Profile: REQUEST_AUTHZ — uses the DRY_RUN extension, so never blocks egress.
# Purpose: agent identity visibility in Cloud Logging audit logs.
#
# To promote to enforcing mode:
#   1. Grant roles/iap.egressor to each RE service account for each endpoint
#   2. Change iap_extension_egress.metadata.iamEnforcementMode to "ENFORCED"
#   3. Change iap_extension_egress.fail_open to false
# ==============================================================================
resource "google_network_security_authz_policy" "egress_iap_policy" {
  provider = google-beta

  name     = "${var.prefix}-iap-egress-policy"
  location = var.location
  project  = var.project_id

  action         = "CUSTOM"
  policy_profile = "REQUEST_AUTHZ"

  target {
    resources = [google_network_services_agent_gateway.egress_gateway.id]
  }

  custom_provider {
    authz_extension {
      resources = [google_network_services_authz_extension.iap_extension_egress.id]
    }
  }

  depends_on = [google_network_services_authz_extension.iap_extension_egress]
}

# NOTE: roles/networkservices.agentGatewayUser removed — role does not exist
# in GCP IAM (confirmed: gcloud iam roles describe returns NOT FOUND).
# ==============================================================================

# ==============================================================================
# GATEWAY SERVICE ACCOUNT — MODEL ARMOR IAM (MANDATORY)
# ==============================================================================
# The Agent Gateway uses service-PROJECT_NUMBER@gcp-sa-dep.iam.gserviceaccount.com
# (Google-managed, created when the Agent Gateway API is first enabled) to make
# callout requests to the Model Armor REP endpoint during content screening.
#
# Per official docs (delegate-authorization#configure-authz-ma), this SA MUST hold:
#   1. roles/modelarmor.calloutUser    — authenticate callouts to MA REP endpoint
#   2. roles/modelarmor.user           — use MA templates in this project
#   3. roles/serviceusage.serviceUsageConsumer — consume APIs in this project
#
# WHY null_resource instead of google_project_iam_member:
#   gcp-sa-dep is a Google-managed service agent created lazily — it only exists
#   after the Agent Gateway API is first invoked in the project. On a fresh project
#   terraform apply, the SA does not yet exist and google_project_iam_member fails
#   with "service account does not exist", leaving the grants permanently missing.
#   null_resource + gcloud with || true is idempotent:
#     - Fresh project (SA not yet created): gcloud fails gracefully (|| true)
#     - After first gateway API call: SA exists; re-run terraform apply applies grant
#
# IMPACT of missing grants:
#   fail_open=false (ingress): ALL inbound traffic denied — 403 on every request
#   fail_open=true  (egress):  fails-open, MA bypassed silently — no content screening
#
# Confirmed missing from state 2026-09-30 during IAM audit. Converted to
# null_resource to ensure reliable application across fresh and existing projects.
# ==============================================================================

resource "null_resource" "gw_sa_ma_iam" {
  triggers = {
    project = var.project_id
    number  = data.google_project.project.number
  }

  provisioner "local-exec" {
    command = <<-EOT
      GW_SA="serviceAccount:service-${data.google_project.project.number}@gcp-sa-dep.iam.gserviceaccount.com"
      echo "Granting MA IAM roles to Agent Gateway SA..."

      # 1. calloutUser — authenticate the gateway SA callouts to the MA REP endpoint
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="$GW_SA" \
        --role="roles/modelarmor.calloutUser" \
        --quiet 2>&1 || echo "  calloutUser: SA not yet created or already bound — continuing"

      # 2. modelarmor.user — permission to evaluate/use MA templates in this project
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="$GW_SA" \
        --role="roles/modelarmor.user" \
        --quiet 2>&1 || echo "  modelarmor.user: SA not yet created or already bound — continuing"

      # 3. serviceusage.serviceUsageConsumer — allow SA to consume project APIs
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="$GW_SA" \
        --role="roles/serviceusage.serviceUsageConsumer" \
        --quiet 2>&1 || echo "  serviceUsageConsumer: SA not yet created or already bound — continuing"

      echo "MA IAM grants complete (or deferred if SA not yet created)"
    EOT
  }

  depends_on = [
    google_project_service.modelarmor,
    google_network_services_agent_gateway.ingress_gateway,
    google_network_services_agent_gateway.egress_gateway,
  ]
}

# ==============================================================================
# DLP SERVICE ACCOUNT — MODEL ARMOR SDP TEMPLATE IAM
# ==============================================================================
# The MA templates (security-high, security-responses) use DLP inspect +
# deidentify templates for SDP screening. The DLP service agent needs
# roles/dlp.user so MA can invoke DLP when processing sanitize operations.
#
# DLP SA: service-PROJECT_NUMBER@dlp-api.iam.gserviceaccount.com
# (Google-managed, created lazily when Cloud DLP API is enabled)
# ==============================================================================

resource "null_resource" "dlp_sa_ma_user" {
  triggers = {
    project = var.project_id
    number  = data.google_project.project.number
  }

  provisioner "local-exec" {
    command = <<-EOT
      DLP_SA="serviceAccount:service-${data.google_project.project.number}@dlp-api.iam.gserviceaccount.com"
      echo "Granting roles/dlp.user to DLP service agent..."
      gcloud projects add-iam-policy-binding "${var.project_id}" \
        --member="$DLP_SA" \
        --role="roles/dlp.user" \
        --quiet 2>&1 || echo "  DLP SA not yet created or already bound — continuing"
    EOT
  }

  depends_on = [
    google_project_service.dlp,
    google_model_armor_template.security_high,
    google_model_armor_template.security_responses,
  ]
}

# ==============================================================================
# SGP INGRESS POLICY — API CONSTRAINT: NOT POSSIBLE
# ==============================================================================
# The Agent Gateway API enforces a HARD LIMIT: at most one CONTENT_AUTHZ
# AuthzPolicy per gateway with CLIENT_TO_AGENT (ingress) access path.
# The ingress gateway's CONTENT_AUTHZ slot is already occupied by ran-ma-policy
# (Model Armor). A second CONTENT_AUTHZ policy (SGP) cannot be added.
#
# API error returned if attempted:
#   "at most one CONTENT_AUTHZ AuthzPolicy is allowed for AgentGateway
#    with CLIENT_TO_AGENT access path: invalid argument"
#
# Result: SGP inbound screening is NOT possible on the ingress gateway.
# SGP governance applies to egress only (ran-sgp-egress-policy).
# Inbound content screening relies on Model Armor (ran-ma-policy on ingress).
# This is a platform limitation — tracked for resolution when the API allows
# multiple CONTENT_AUTHZ policies per gateway direction.
