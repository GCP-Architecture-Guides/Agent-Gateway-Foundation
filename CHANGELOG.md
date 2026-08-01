# Changelog

All notable changes to **Agent-Gateway-Foundation** are documented here.

Format: [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`

- **MAJOR** — breaking changes to Terraform variables, script interfaces, or SDK API
- **MINOR** — new features, new skills, new agents — backward compatible
- **PATCH** — bug fixes, security patches, documentation updates

Consuming teams should pin to a tag: `?ref=v1.0.0`

---

## [v1.0.2] — 2026-08-01

### Bug Fixes

#### Infrastructure (Terraform)
- **IAP service extension** (`03_security_and_gateways.tf`) — Corrected a
  fundamental design error: the IAP authz extension was gated behind
  `iap_enabled = false` as if it were for user authentication. IAP in the
  Agent Gateway context validates **service identity** (RE→RE, Cloud Run→RE).
  The extension and its `REQUEST_AUTHZ` ingress policy are now **always created**.
- **Auto-grant for RE service agent** — Added unconditional
  `roles/iap.httpsResourceAccessor` grant to
  `service-PROJECT_NUMBER@gcp-sa-aiplatform-re.iam.gserviceaccount.com` so
  Reasoning Engines can call through the gateway without manual IAM setup.
- **Gateway SA Model Armor access** — Added `roles/modelarmor.inspector`
  grant to the gateway's `gcp-sa-dep` service account. Without this, the
  gateway cannot invoke the MA extension and all requests fail with 403.
- **SGP ingress policy** (NEW) — Added `ran-sgp-ingress-policy` targeting
  the ingress gateway, mirroring the existing egress SGP policy. Inbound
  prompts are now screened by SGP before reaching any agent.
- **Removed `iap_enabled` variable** — No longer needed. `iap_allowed_members`
  now controls only additional callers beyond the auto-granted RE service agent.

### Breaking Changes
- `iap_enabled` variable removed. Remove it from `terraform.tfvars` if set.
  The IAP extension is now unconditional; `iap_allowed_members` controls extras.

### Upgrade Path
```bash
# If iap_enabled = true was in terraform.tfvars:
#   1. Remove the iap_enabled line
#   2. terraform apply  (creates iap_extension + grants as new resources)
# If iap_enabled = false (default):
#   1. terraform apply  (creates 4 new resources — no state conflict)
```

---

## [v1.0.1] — 2026-07-29

### Bug Fixes

#### Infrastructure (Terraform)
- **IAP extension** — Fixed three blocking issues in `03_security_and_gateways.tf`:
  - Replaced regional IAP endpoint `iap.${var.location}.rep.googleapis.com` with correct global `iap.googleapis.com`
  - Changed `policy_profile` from `PRINCIPAL_AUTHZ` to `REQUEST_AUTHZ` (per official docs)
  - Added mandatory `iapPolicyVersion = "V1"` metadata (required by IAP authz pattern)
  - Removed non-existent `fail_open` Terraform attribute

#### Deployment Scripts
- **`deploy_all.sh`** — Added `--phases` argument support:
  - `--phases infra` — run bootstrap + terraform only
  - `--phases agent` — redeploy Reasoning Engine only
  - `--phases sgp` — recreate SGP policy only
  - `--phases test` — rerun guardrail tests only
  - Combinations: `--phases agent,sgp,test`
  - `--help` flag documents all options
  - Phase 3 (SGP) clarifies: `create_sgp_policy.sh` reads `agent_name` from tfvars only (primary agent)

#### Skills Library
- **`agw-foundation-adoption`** — Added IAP enablement guide (REQUEST_AUTHZ pattern, dry-run mode);
  updated `--phases` docs to match all new flag options; v1.0.1 version pin
- **`agw-add-sgp-policy`** (NEW) — Complete SGP NLC policy workflow skill; fix PREFIX
  empty-check (`${PREFIX:+${PREFIX}-}`); added IMPORTANT warning for multi-agent `--agent-name`
  deploys (use manual Step 4, not `create_sgp_policy.sh`)
- **`sgp-network-authz-pattern`** — Added `fail_open` removal note, `iap.googleapis.com`
  global endpoint clarification, REQUEST_AUTHZ vs PRINCIPAL_AUTHZ disambiguation
- **`agent-gateway-deploy-patch`** — Added scope header clarifying this skill is for
  `YOUR_PROJECT_ID`/`agentic-lens` only; foundation users: `deploy_chat_agent.sh`
  handles all patching automatically
- **`gateway-agent-sdk`** — Fixed Step 1 path references from `agent/` to
  `agents/chat-agent/` to match foundation directory structure

#### Documentation
- `README.md` — Updated version, added Phase 0 table row, `--phases` usage examples,
  IAP row in What You Get table, 8 skills (was 7), `agw-add-sgp-policy` in skills table,
  multi-agent SGP limitation note, v1.0.1 pin for Path B submodule
- `KNOWN_ISSUES.md` — Added `KNOWN_ISSUES.md` reference in rollback procedures
- `CHANGELOG.md` — This entry

### Notes
- No breaking changes to `terraform.tfvars` schema
- No breaking changes to `deploy_all.sh`, `destroy_all.sh`, or SDK API
- `--phases` flag is additive; omitting it runs all phases (backwards compatible)
- IAP service extension is now always created (service identity validation is unconditional)
  `iap_enabled` was removed; `iap_allowed_members` controls additional callers only

---

## [v1.0.0] — 2026-07-28

### 🎉 Initial Public Release

First stable release of the Agent Gateway Foundation. Battle-tested over 6 weeks of
production deployment in a fully org-policy-enforced GCP environment.

### Infrastructure (Terraform)
- PSC-based Agent Gateway ingress + egress
- Model Armor with dual templates (`security-high` for requests, `security-responses` for model output)
- Three custom org policies enforced at project level:
  - `EnforceReasoningEngineAgentGatewayConfig`
  - `EnforceAgentIdentityForReasoningEngine`
  - `EnforceReasoningEngineOtelConfig`
- Cloud Armor WAF on the ingress load balancer
- Authz extensions wired to Model Armor
- SGP (Semantic Governance Policy) NLC engine
- Multi-project observability dashboard (Cloud Monitoring)
- Allowed egress host management via `allowed_egress_hosts` in `terraform.tfvars`

### Agent SDK (`lib/gateway_agent/`)
- `GatewayAgent` — drop-in replacement for ADK `Agent`
- `GlobalGemini` — PSC-compatible regional Gemini wrapper
- `emit_llm_usage_from_response` — OTEL token telemetry callback
- Three-layer OTEL fix: mTLS SSL crash, TCP-block timeout, aiohttp event loop singleton
- Org Policy compliance: `get_project_id` monkey-patch

### Deployment Pipeline
- `deploy_all.sh` — 4-phase end-to-end deploy (Terraform → Agent → SGP → Tests)
- `destroy_all.sh` — 4-phase mirrored teardown (reverse order)
- `scripts/deploy_chat_agent.sh` — reads ALL values from `terraform.tfvars` (zero hardcodes)
- `scripts/create_sgp_policy.sh` — NLC policy registration
- `scripts/patch_sdk_for_rest_create.py` — ADK SDK monkey-patch for org policy bypass
- `scripts/patch_add_context_spec.py` — contextSpec stripping

### Guardrail Test Suite (`test-agent/`)
- 8 test cases: Prompt Injection ×2, Egress Block ×2, DLP ×2, Allow ×2
- JSON result output with per-test HTTP status and response snippets

### Skills Library (`skills/`)
- `agent-gateway-deploy-patch` — ADK `.pth` monkey-patch pattern
- `cloud-run-deploy-guardrails` — Cloud Run IAP, VPC egress guardrails
- `gateway-agent-sdk` — GatewayAgent SDK wiring and tribal knowledge
- `sgp-network-authz-pattern` — SGP infra setup (correct path, not the dead-end CLI)
- `sgp-policy-rules` — NLC constraint writing and debugging
- `vertex-ai-global-endpoint-adk` — Gemini 3.x global endpoint pattern

### Documentation
- `KNOWN_ISSUES.md` — complete failure runbook (8 documented issues + fixes)
- `template/terraform.tfvars.example` — consumer onboarding template
- `CHANGELOG.md` — this file

### Known Limitations (v1.0.0)
- Terraform state is local (GCS backend is a v1.1.0 target)
- Skills library is complete for infra; agent registry + model armor skills are v1.1.0
- No CI/CD pipeline (Cloud Build / GitHub Actions) — planned for v1.2.0

---

## [Unreleased]

### Planned for v1.1.0
- `skills/agw-model-armor-setup` — Model Armor dual-template pattern
- `skills/agw-terraform-state` — GCS backend setup
- `skills/agw-agent-registry` — Endpoint registration pattern
- GCS Terraform backend support

### Planned for v1.2.0
- Cloud Build / GitHub Actions CI/CD pipeline
- Multi-agent dashboard auto-discovery
- `skills/agw-observability` and `skills/agw-teardown`
