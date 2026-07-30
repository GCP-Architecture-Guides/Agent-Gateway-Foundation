# Agent Gateway — Guardrail Test Suite

This folder contains an **automated smoke-test harness** that fires targeted
prompts at your deployed Vertex AI Reasoning Engine and verifies that every
security layer of the Agent Gateway is operating as intended.

It is designed to be run:

1. **Automatically** — as the final step of `deploy_all.sh` after a fresh
   deployment, so you get immediate confidence that guardrails are live.
2. **Manually** — any time you want to regression-test guardrail changes,
   rotate policies, or hand the suite to a reviewer.

---

## What is tested

| ID | Category | What it validates |
|----|----------|-------------------|
| `PI-01` | Prompt Injection | Classic "ignore previous instructions" jailbreak → **Model Armor PI filter (HIGH)** blocks |
| `PI-02` | Prompt Injection | DAN persona-hijack jailbreak → **Model Armor PI + DANGEROUS RAI** blocks |
| `URL-01` | URL Fetch & Summarize | Agent fetches `www.google.com` → **Egress gateway permits** (allowlisted host) |
| `URL-02` | URL Fetch & Summarize | Agent fetches `raw.githubusercontent.com` README → **Egress gateway permits** |
| `DLP-01` | DLP — SSN | SSN `123-45-6789` in prompt → **Model Armor DLP redacts** `US_SOCIAL_SECURITY_NUMBER` |
| `DLP-02` | DLP — Credit Card | Visa test PAN in prompt → **Model Armor DLP redacts** `CREDIT_CARD_NUMBER` |

---

## Quick-start

```bash
# From the repo root (mod-agw-foundation/)
python3 test-agent/run_guardrail_tests.py \
    --project  <YOUR_PROJECT_ID> \
    --location us-central1 \
    --agent-name chat-agent-v1
```

The script uses **Application Default Credentials** (ADC). Make sure you are
authenticated:

```bash
gcloud auth application-default login
```

### CLI flags

| Flag | Default | Description |
|------|---------|-------------|
| `--project` | `$GOOGLE_CLOUD_PROJECT` | GCP project ID |
| `--location` | `us-central1` | Region where the agent is deployed |
| `--agent-name` | `chat-agent-v1` | Display name of the Reasoning Engine |
| `--output-dir` | `test-agent/results/` | Directory for JSON result files |

---

## Output

Results are printed to **stdout** with colour-coded pass/fail indicators and
also saved as a timestamped JSON file under `test-agent/results/`:

```
test-agent/results/guardrail_test_results_20260628_123456.json
```

The JSON contains per-test details (HTTP status, response snippet, elapsed
time) for easy inclusion in CI pipelines or audit reports.

---

## How it integrates with `deploy_all.sh`

`deploy_all.sh` automatically runs this suite at the end of a successful
deployment (Phase 4). It passes `--project`, `--location`, and
`--agent-name` from the Terraform variables so no manual configuration is
needed.

If any test fails, `deploy_all.sh` prints a warning but does **not** roll
back — the infrastructure is already deployed. Use the failure output to
tune your guardrail policies.

---

## Cleanup (`destroy_all.sh`)

`destroy_all.sh` removes the `test-agent/results/` directory and any
`__pycache__` artefacts before tearing down infrastructure, ensuring a
clean slate.

---

## Dependencies

The script uses only the Python standard library plus two packages that are
already required by the broader project:

```
google-auth
requests
```

These will be installed automatically when `deploy_all.sh` runs, or you can
install them manually:

```bash
pip install google-auth requests
```
