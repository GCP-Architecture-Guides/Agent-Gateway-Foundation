# Changelog

All notable changes to **Agent-Gateway-Foundation** are documented here.

Format: [Semantic Versioning](https://semver.org/) — `MAJOR.MINOR.PATCH`

- **MAJOR** — breaking changes to Terraform variables, script interfaces, or SDK API
- **MINOR** — new features, new skills, new agents — backward compatible
- **PATCH** — bug fixes, security patches, documentation updates

Consuming teams should pin to a tag: `?ref=v1.0.0`

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
- `skills/agw-foundation-adoption` — End-to-end onboarding guide
- `skills/agw-terraform-state` — GCS backend setup
- `skills/agw-agent-registry` — Endpoint registration pattern
- GCS Terraform backend support
- README.md with full input/output reference

### Planned for v1.2.0
- Cloud Build / GitHub Actions CI/CD pipeline
- Multi-agent dashboard auto-discovery
- `skills/agw-observability` and `skills/agw-teardown`
