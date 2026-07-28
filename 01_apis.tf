# ------------------------------------------------------------------------------
# 1. API ENABLEMENT
# ------------------------------------------------------------------------------
resource "google_project_service" "compute" {
  service            = "compute.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "modelarmor" {
  service            = "modelarmor.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networksecurity" {
  service            = "networksecurity.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "networkservices" {
  service            = "networkservices.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "aiplatform" {
  service            = "aiplatform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dlp" {
  service            = "dlp.googleapis.com"
  disable_on_destroy = false
}


resource "google_project_service" "dns" {
  service            = "dns.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "agentregistry" {
  service            = "agentregistry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iap" {
  service            = "iap.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "cloudtrace" {
  service            = "cloudtrace.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "dataform" {
  service            = "dataform.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iam" {
  service            = "iam.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "iamconnectors" {
  service            = "iamconnectors.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "logging" {
  service            = "logging.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "monitoring" {
  service            = "monitoring.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "observability" {
  service            = "observability.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "securitycenter" {
  service            = "securitycenter.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "storage" {
  service            = "storage.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "telemetry" {
  service            = "telemetry.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "orgpolicy" {
  service            = "orgpolicy.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "apphub" {
  service            = "apphub.googleapis.com"
  disable_on_destroy = false
}

# NOTE: Custom org policies (enforceReasoningEngineAgentGatewayConfig,
# enforceAgentIdentityForReasoningEngine, enforceReasoningEngineOtelConfig)
# are applied via a best-effort gcloud step in cloudbuild.yaml (apply-org-policies).
# Cloud Build SA lacks orgpolicy.policies.create — applied with elevated ADC.

