# Cloud Logging Filters — Agent Gateway & Model Armor

> **Source of truth:** Every filter below is copied verbatim from the
> **deployed Terraform modules**:
>
> | Layer | Module | Terraform file |
> |---|---|---|
> | Gateway (ingress / egress) | `gateway_observability` | [`modules/gateway_observability/log_metrics.tf`](../modules/gateway_observability/log_metrics.tf) |
> | Model Armor (API verdict) | `lens_model_armor` | [`modules/lens_model_armor/log_metrics.tf`](../modules/lens_model_armor/log_metrics.tf) |
> | Model Armor (alert) | `lens_model_armor` | [`modules/lens_model_armor/alerts.tf`](../modules/lens_model_armor/alerts.tf) |
>
> All metrics are `DELTA / INT64` and are accessible in Cloud Monitoring
> under `logging.googleapis.com/user/<metric_name>`.

---

## Table of Contents

1. [How to Use](#how-to-use)
2. [Agent Gateway Filters](#agent-gateway-filters)
   - [Egress Authz — DENIED](#1-egress-authz--denied)
   - [Egress Authz — ALLOWED](#2-egress-authz--allowed)
   - [PSC Egress TCP Drops (no route)](#3-psc-egress-tcp-drops-no-route)
3. [Model Armor Filters](#model-armor-filters)
   - [Blocked (API verdict)](#4-blocked-api-verdict)
   - [Allowed (API verdict)](#5-allowed-api-verdict)
   - [Prompt Injection / Jailbreak Matches](#6-prompt-injection--jailbreak-matches)
   - [Application-Layer: API Blocked (Cloud Run)](#7-application-layer-api-blocked-cloud-run)
   - [Application-Layer: Supervisor Blocked (Reasoning Engine)](#8-application-layer-supervisor-blocked-reasoning-engine)
4. [Log-Based Metrics Reference](#log-based-metrics-reference)
5. [Dashboard Export & BigQuery Sink](#dashboard-export--bigquery-sink)
6. [Log Field Reference](#log-field-reference)

---

## How to Use

### Cloud Logging Explorer
1. **Cloud Logging → Log Explorer** → paste any filter below into the query box.
2. Set time range as needed (default: last 1 h).
3. Click **Run query**.

### gcloud CLI
```bash
gcloud logging read '<PASTE_FILTER_HERE>' \
  --project=YOUR_PROJECT_ID \
  --freshness=24h \
  --limit=50 \
  --format="table(timestamp,jsonPayload.event,jsonPayload.armor_layer)"
```

### Cloud Monitoring — Metrics Explorer
All metrics below are queryable at:
```
logging.googleapis.com/user/<metric_name>
```
e.g. `logging.googleapis.com/user/lens_gateway_egress_blocked`

---

## Agent Gateway Filters

**Log name:** `networkservices.googleapis.com/gateway_requests`  
**Resource type:** `networkservices.googleapis.com/Gateway`

The gateway logs every request. Key decision fields:

| Field | Meaning |
|---|---|
| `httpRequest.requestMethod` | `CONNECT` = outbound tunnel; `POST`/`GET` = ingress API call |
| `jsonPayload.authzPolicyInfo.result` | `DENIED` / `ALLOWED` — network-level authz verdict |
| `jsonPayload.enforcedGatewaySecurityPolicy.matchedRules[].name` | Rule name (e.g. `default_denied` for PSC drops) |
| `jsonPayload.enforcedGatewaySecurityPolicy.hostname` | Destination host:port |

---

### 1. Egress Authz — DENIED

Non-tunnel requests explicitly **denied** by a Network Authorization Policy
(e.g. a content-authz policy that Model Armor/SGP caused the gateway to
enforce). This is the authoritative "gateway blocked it" signal.

```
resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod!="CONNECT"
jsonPayload.authzPolicyInfo.result="DENIED"
```

**Metric:** `logging.googleapis.com/user/lens_gateway_egress_blocked`  
**Dashboard widget:** "Agent Gateway Security Overview"

---

### 2. Egress Authz — ALLOWED

Non-tunnel requests **allowed** through. Useful as the baseline denominator
when calculating block rates.

```
resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod!="CONNECT"
jsonPayload.authzPolicyInfo.result="ALLOWED"
```

**Metric:** `logging.googleapis.com/user/lens_gateway_egress_allowed`  
**Dashboard widget:** "Agent Gateway Security Overview"

---

### 3. PSC Egress TCP Drops (no route)

When an agent tries to reach a host that is **not registered as a PSC
endpoint**, the deny-by-default routing rule drops the TCP `CONNECT` tunnel
and records `matchedRules.name = "default_denied"`. These appear as 200s
in the HTTP field (the CONNECT itself succeeded at the TCP level) but with
the rule name indicating the traffic was silently dropped.

This is an informational filter — no dedicated log-based metric is deployed for
it, but it is visible in the raw gateway_requests log and in the
`agent-gateway-observability` dashboard template.

```
resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod="CONNECT"
jsonPayload.enforcedGatewaySecurityPolicy.matchedRules.name="default_denied"
```

**Filter by blocked hostname:**
```
resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod="CONNECT"
jsonPayload.enforcedGatewaySecurityPolicy.matchedRules.name="default_denied"
jsonPayload.enforcedGatewaySecurityPolicy.hostname=~"linkedin"
```

---

## Model Armor Filters

Two distinct signal planes exist. Use the right one for your context:

| Plane | Log source | What it captures |
|---|---|---|
| **API verdict** | `modelarmor.googleapis.com/SanitizeOperation` | Direct Model Armor API results — the ground truth |
| **Application layer** | `cloud_run_revision` / `ReasoningEngine` | Structured events emitted by the Agentic Lens app code |

---

### 4. Blocked (API verdict)

Every call where the Model Armor template returned a **BLOCK** verdict.
This is the definitive "Model Armor blocked it" signal regardless of which
specific filter (PI, DLP, RAI, etc.) triggered.

```
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_blocked`  
**Alert:** triggered by `lens_model_armor_prompt_injection` (see §6)

**Filter by direction:**
```
-- Inbound user prompts blocked
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK"
jsonPayload.operationType="SANITIZE_USER_PROMPT"

-- Outbound model responses blocked
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK"
jsonPayload.operationType="SANITIZE_MODEL_RESPONSE"
```

---

### 5. Allowed (API verdict)

Calls that passed through Model Armor without a block. Denominator for
block-rate calculations.

```
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_ALLOW"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_allowed`

---

### 6. Prompt Injection / Jailbreak Matches

Calls where the `pi_and_jailbreak` filter matched at **HIGH** confidence.
Fires for classic jailbreaks, DAN persona-hijacks, and instruction-override
attempts. **This metric drives the alert policy.**

```
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState="MATCH_FOUND"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_prompt_injection`  
**Alert:** `Model Armor: prompt injection surge`  
→ fires when count exceeds `var.prompt_injection_alert_threshold` (default: 10)
  within `var.prompt_injection_alert_window_seconds` (default: 60 s).  
→ configured in [`modules/lens_model_armor/alerts.tf`](../modules/lens_model_armor/alerts.tf)

**Deep-drill — add confidence level:**
```
resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState="MATCH_FOUND"
jsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.confidenceLevel="HIGH"
```

---

### 7. Application-Layer: API Blocked (Cloud Run)

Structured events emitted by the **Agentic Lens API** (Cloud Run service) when
it calls Model Armor and receives a block. These are `jsonPayload` events in
the Cloud Run revision log, not the Model Armor API log.

```
resource.type="cloud_run_revision"
resource.labels.service_name="<cloud_run_service_name>"
jsonPayload.event="model_armor_blocked"
jsonPayload.armor_layer="api"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_blocked_api`

**Companion filters:**
```
-- Allowed at API layer
resource.type="cloud_run_revision"
resource.labels.service_name="<cloud_run_service_name>"
jsonPayload.event="model_armor_allowed"
jsonPayload.armor_layer="api"

-- Skipped at API layer (template not invoked)
resource.type="cloud_run_revision"
resource.labels.service_name="<cloud_run_service_name>"
jsonPayload.event="model_armor_skipped"
jsonPayload.armor_layer="api"
```

**Metrics:** `lens_model_armor_allowed_api`, `lens_model_armor_skipped_api`

**Terminal-query block attribution** (query reached terminal, blocked by Model Armor):
```
resource.type="cloud_run_revision"
resource.labels.service_name="<cloud_run_service_name>"
jsonPayload.event="query_terminal"
jsonPayload.block_layer="model_armor"
```
**Metric:** `logging.googleapis.com/user/lens_query_terminal_blocked_model_armor`

---

### 8. Application-Layer: Supervisor Blocked (Reasoning Engine)

Same structured events emitted by the **supervisor agent** running inside the
Vertex AI Reasoning Engine (ADK agent runtime).

```
resource.type="aiplatform.googleapis.com/ReasoningEngine"
jsonPayload.event="model_armor_blocked"
jsonPayload.armor_layer="supervisor"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_blocked_supervisor`

```
-- Allowed at supervisor layer
resource.type="aiplatform.googleapis.com/ReasoningEngine"
jsonPayload.event="model_armor_allowed"
jsonPayload.armor_layer="supervisor"
```

**Metric:** `logging.googleapis.com/user/lens_model_armor_allowed_supervisor`

---

## Log-Based Metrics Reference

All metrics are `DELTA / INT64`. Access in Cloud Monitoring Metrics Explorer
as `logging.googleapis.com/user/<name>`.

### Gateway (`modules/gateway_observability`)

| Metric name | Filter summary | Terraform resource |
|---|---|---|
| `lens_gateway_egress_blocked` | Non-CONNECT + `authzPolicyInfo.result=DENIED` | `google_logging_metric.gateway_egress_blocked` |
| `lens_gateway_egress_allowed` | Non-CONNECT + `authzPolicyInfo.result=ALLOWED` | `google_logging_metric.gateway_egress_allowed` |

### Model Armor (`modules/lens_model_armor`)

| Metric name | Filter summary | Terraform resource |
|---|---|---|
| `lens_model_armor_blocked` | `sanitizationVerdict=BLOCK` | `google_logging_metric.model_armor_blocked` |
| `lens_model_armor_allowed` | `sanitizationVerdict=ALLOW` | `google_logging_metric.model_armor_allowed` |
| `lens_model_armor_prompt_injection` | `pi_and_jailbreak.matchState=MATCH_FOUND` | `google_logging_metric.model_armor_prompt_injection` |
| `lens_model_armor_blocked_api` | Cloud Run + `event=model_armor_blocked` + `layer=api` | `google_logging_metric.model_armor_blocked_api` |
| `lens_model_armor_allowed_api` | Cloud Run + `event=model_armor_allowed` + `layer=api` | `google_logging_metric.model_armor_allowed_api` |
| `lens_model_armor_skipped_api` | Cloud Run + `event=model_armor_skipped` + `layer=api` | `google_logging_metric.model_armor_skipped_api` |
| `lens_model_armor_blocked_supervisor` | RE + `event=model_armor_blocked` + `layer=supervisor` | `google_logging_metric.model_armor_blocked_supervisor` |
| `lens_model_armor_allowed_supervisor` | RE + `event=model_armor_allowed` + `layer=supervisor` | `google_logging_metric.model_armor_allowed_supervisor` |
| `lens_query_terminal` | Cloud Run + `event=query_terminal` | `google_logging_metric.query_terminal` |
| `lens_query_terminal_blocked_model_armor` | Cloud Run + `event=query_terminal` + `block_layer=model_armor` | `google_logging_metric.query_terminal_blocked_armor` |

---

## Dashboard Export & BigQuery Sink

### Open dashboards in console
- **Agent Gateway Observability:** Cloud Monitoring → Dashboards → *Agent Gateway Observability*  
  (rendered from [`modules/gateway_observability/agent-gateway-observability.json.tpl`](../modules/gateway_observability/agent-gateway-observability.json.tpl))
- **Model Armor Security Overview:** Cloud Monitoring → Dashboards → *Model Armor Security Overview*

### Export dashboard IDs
```bash
gcloud monitoring dashboards list --project=YOUR_PROJECT_ID \
  --format="table(name,displayName)"
```

### BigQuery log sinks (long-term analytics / Looker Studio)

```bash
# Create dataset first
bq mk --dataset YOUR_PROJECT_ID:agw_security_logs

# Gateway egress denied → BigQuery
gcloud logging sinks create agw-egress-denied-bq \
  bigquery.googleapis.com/projects/YOUR_PROJECT_ID/datasets/agw_security_logs \
  --log-filter='resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod!="CONNECT"
jsonPayload.authzPolicyInfo.result="DENIED"' \
  --project=YOUR_PROJECT_ID

# PSC TCP drops (no route) → BigQuery
gcloud logging sinks create agw-psc-drops-bq \
  bigquery.googleapis.com/projects/YOUR_PROJECT_ID/datasets/agw_security_logs \
  --log-filter='resource.type="networkservices.googleapis.com/Gateway"
httpRequest.requestMethod="CONNECT"
jsonPayload.enforcedGatewaySecurityPolicy.matchedRules.name="default_denied"' \
  --project=YOUR_PROJECT_ID

# Model Armor blocks → BigQuery
gcloud logging sinks create ma-blocks-bq \
  bigquery.googleapis.com/projects/YOUR_PROJECT_ID/datasets/agw_security_logs \
  --log-filter='resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.sanitizationVerdict="MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK"' \
  --project=YOUR_PROJECT_ID

# PI/Jailbreak only → BigQuery
gcloud logging sinks create ma-pi-bq \
  bigquery.googleapis.com/projects/YOUR_PROJECT_ID/datasets/agw_security_logs \
  --log-filter='resource.type="modelarmor.googleapis.com/SanitizeOperation"
jsonPayload.sanitizationResult.filterResults.pi_and_jailbreak.piAndJailbreakFilterResult.matchState="MATCH_FOUND"' \
  --project=YOUR_PROJECT_ID
```

After creating sinks, grant the sink's service account `roles/bigquery.dataEditor`
on the destination dataset.

---

## Log Field Reference

### Agent Gateway (`networkservices.googleapis.com/Gateway`)

```
logName:  projects/<project>/logs/networkservices.googleapis.com%2Fgateway_requests
resource:
  type: networkservices.googleapis.com/Gateway
  labels:
    gateway_name:    <prefix>-ingress-gateway | <prefix>-egress-gateway
    gateway_type:    SECURE_WEB_GATEWAY
    location:        us-east1
    network_name:    projects/.../networks/<vpc>
    resource_container: <project_number>

httpRequest:
  requestMethod:  CONNECT | POST | GET
  status:         200 | 403

jsonPayload:
  @type:           type.googleapis.com/google.cloud.loadbalancing.type.LoadBalancerLogEntry
  agentGatewayInfo: {}
  authzPolicyInfo:
    result:        DENIED | ALLOWED           ← key field for content-authz blocks
  enforcedGatewaySecurityPolicy:
    hostname:      www.linkedin.com:443       ← blocked destination (PSC drops)
    matchedRules:
      - name:      default_denied             ← PSC deny-by-default
  mtls:
    clientCertPresent:        true | false
    clientCertChainVerified:  true | false
    clientCertSha256Fingerprint: <sha256>
```

### Model Armor API (`modelarmor.googleapis.com/SanitizeOperation`)

```
logName:  projects/<project>/logs/modelarmor.googleapis.com%2Fsanitize_operations
resource:
  type: modelarmor.googleapis.com/SanitizeOperation
  labels:
    template_id:         security-high
    location:            us-east1
    resource_container:  projects/<project_number>

jsonPayload:
  @type:           type.googleapis.com/google.cloud.modelarmor.logging.v1.SanitizeOperationLogEntry
  operationType:   SANITIZE_USER_PROMPT | SANITIZE_MODEL_RESPONSE
  filterConfig:    {}  (template snapshot)
  sanitizationInput:
    text:          <post-redaction text>       ← present when not binary
    byteItem:
      byteData:    <base64>                    ← present for binary input
  sanitizationResult:
    sanitizationVerdict:   MODEL_ARMOR_SANITIZATION_VERDICT_BLOCK   ← KEY BLOCK FIELD
                         | MODEL_ARMOR_SANITIZATION_VERDICT_ALLOW
    invocationResult:  SUCCESS | FAILURE
    filterResults:
      pi_and_jailbreak:
        piAndJailbreakFilterResult:
          matchState:       MATCH_FOUND | NO_MATCH_FOUND
          confidenceLevel:  HIGH | MEDIUM | LOW
          executionState:   EXECUTION_SUCCESS
      sdp:
        sdpFilterResult:
          inspectResult:                           ← detect-only mode
            matchState:     MATCH_FOUND | NO_MATCH_FOUND
            infoTypes:      [US_SOCIAL_SECURITY_NUMBER]
          deidentifyResult:                        ← redact mode
            matchState:     MATCH_FOUND | NO_MATCH_FOUND
            infoTypes:      [CREDIT_CARD_NUMBER]
            transformedBytes: "19"
            data.text:      <redacted text>
      rai:
        raiFilterResult:
          matchState:       MATCH_FOUND | NO_MATCH_FOUND
          raiFilterTypeResults:
            dangerous:        {matchState}
            harassment:       {matchState}
            hate_speech:      {matchState}
            sexually_explicit:{matchState}
      malicious_uris:
        maliciousUriFilterResult: {matchState, executionState}
      csam:
        csamFilterFilterResult:   {matchState, executionState}
```

### Application Layer (Cloud Run / Reasoning Engine)

```
-- Cloud Run (API layer)
resource.type:  cloud_run_revision
resource.labels.service_name:  <cloud_run_service_name>
jsonPayload:
  event:       model_armor_blocked | model_armor_allowed | model_armor_skipped | query_terminal
  armor_layer: api
  block_layer: model_armor   ← only on query_terminal when Model Armor blocked

-- Reasoning Engine (supervisor layer)
resource.type:  aiplatform.googleapis.com/ReasoningEngine
jsonPayload:
  event:       model_armor_blocked | model_armor_allowed
  armor_layer: supervisor
```
