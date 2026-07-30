# Foundation Security & Agent Gateway Architecture Plan

This document outlines the architectural plan for deploying the foundational security elements of the Agent Gateway. This module is designed to be the highly scalable "hub" that handles security, networking, and observability, without deploying any specific agents (which will be handled in separate submodules).

## Proposed Architecture

### 1. API Enablement Layer
The foundation will automatically enable the necessary GCP APIs:
*   `compute.googleapis.com` (VPC, ILB, PSC)
*   `iap.googleapis.com` (Identity-Aware Proxy)
*   `dlp.googleapis.com` (Data Loss Prevention)
*   `orgpolicy.googleapis.com` (Organization Policies)
*   `networkservices.googleapis.com` (Network Services / Egress gateways)
*   `logging.googleapis.com` & `monitoring.googleapis.com` (Observability)
*   `aiplatform.googleapis.com` (Model Armor / Vertex AI)

### 2. Core Infrastructure & Networking Layer (The Gateway Proxy)
*   **VPC & Subnets:** A dedicated VPC containing a proxy-only subnet for the load balancer.
*   **Internal Application Load Balancer (ILB):** The central entry point, terminating TLS and routing to the gateway backend.
*   **PSC Service Attachment:** Attached to the ILB, allowing consumer projects to connect securely without public IP exposure or VPC peering.

### 3. Security & Governance Layer (The "Shield")
*   **Custom Org Policies:** Application of 3 specific custom org policies to enforce project-level security guardrails:
    * `custom.enforceAgentIdentityForReasoningEngine`
    * `custom.enforceReasoningEngineAgentGatewayConfig`
    * `custom.enforceReasoningEngineOtelConfig`
*   **IAP (Identity-Aware Proxy):** Enabled on the ILB to provide zero-trust identity verification before traffic reaches the gateway.
*   **Model Armor (MA):** Configuration templates for prompt injection detection and response sanitization.
*   **Data Loss Prevention (DLP):** High-threshold inspection templates to identify and redact PII/PHI.
*   **Semantic Governance Policies (SGP):** Egress policy definitions to validate agent output semantics before returning to the user.

### 4. Observability Dashboards Layer
Based on the Agentic-Prism reference architecture, we will deploy three distinct Cloud Monitoring dashboards within this project to showcase full visibility:

#### A. Agent Gateway Observability
*Focus: Security, Policy Enforcement, and Egress Control.*
*   **Network Egress Tracking:** Line charts showing allowed vs. blocked egress requests via the Network Services Gateway.
*   **Model Armor Decisions:** Panels tracking content-safety blocks vs. allowed pass-throughs.
*   **Traffic & Identity:** Traffic overview scorecards and raw log panels for GCP API IAM denials (403 errors).
*   **Raw Logs:** Direct visibility into blocked payloads for immediate policy tuning.

#### B. Agent Observability
*Focus: LLM Token Usage, Cost, and Health Metrics.*
*   **Token Metrics (Project & Per-Agent):** 15-minute and 7-day trend charts for total, input, and output tokens.
*   **Model Mix:** Visibility into token distribution across different Gemini models.
*   **Anomaly Alerting:** Integration with alert policies (AL1-AL6) for per-agent token spikes, runaway loops, and absolute spend ceilings.
*   **Raw Logs:** Panels surfacing `jsonPayload.event="llm_usage"` events for granular auditing.

#### C. Org Agentic Observability (Single-Project Context)
*Focus: Executive and FinOps Rollup.*
*   Deployed locally instead of in a separate metrics scope hub.
*   Provides high-level 7-day aggregated token consumption trends.
*   Includes drill-down links to the more granular Agent and Gateway observability dashboards.
