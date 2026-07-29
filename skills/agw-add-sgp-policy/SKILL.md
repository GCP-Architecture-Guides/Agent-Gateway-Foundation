---
name: agw-add-sgp-policy
description: >
  Use this skill when adding a Semantic Governance Policy (SGP) NLC policy for
  a deployed agent on Agent Gateway. Walks through the complete workflow:
  pre-check that the RE is ACTIVE, find the Agent Registry UUID, write the
  natural-language constraint, register the policy, verify, and smoke-test.
  Read this BEFORE running create_sgp_policy.sh or any SGP gcloud commands.
  Complements sgp-policy-rules (rule writing) and sgp-network-authz-pattern
  (infrastructure setup). This skill is about the action: "add a policy now."
---

# Add an SGP Policy for a Deployed Agent

## When to Use This Skill

Use when:
- A Reasoning Engine has been deployed and is ACTIVE
- You need to register its SGP semantic governance policy
- You want to constrain what topics/intents the agent is allowed to handle
- `create_sgp_policy.sh` failed and you need to run the steps manually

> [!IMPORTANT]
> SGP policies require a Reasoning Engine that is **ACTIVE** in Agent Registry
> with a `RuntimeIdentity`. This is auto-created when the RE becomes ACTIVE —
> usually 2-3 minutes after `adk deploy agent_engine` completes.
> If `gcloud alpha agent-registry agents list` shows no entry for your agent,
> wait and retry.

---

## Step 0 — Confirm Prerequisites

```bash
# 1. Confirm RE is ACTIVE
gcloud ai reasoning-engines list \
  --location=REGION \
  --project=PROJECT_ID \
  --format='table(name.basename(),displayName,state)'
# Must show: state = ACTIVE

# 2. Confirm Agent Registry entry exists with RuntimeIdentity
gcloud alpha agent-registry agents list \
  --location=REGION \
  --project=PROJECT_ID \
  --format='table(name.basename(),displayName,attributes.flatten())'
# Look for a row with your agent's displayName AND RuntimeIdentity in attributes
# If missing — wait 2-3 min and retry. The entry is auto-created by the platform.
```

---

## Step 1 — Find the Agent Registry Path

The SGP policy needs the **full resource path** of the agent's Agent Registry entry,
not the Reasoning Engine ID. These are different resources.

```bash
# Get the full agent registry path for your agent
AGENT_NAME="your_agent_name"   # must match terraform.tfvars agent_name
REGION="us-east1"
PROJECT_ID="your-project-id"

# List and filter by display name
gcloud alpha agent-registry agents list \
  --location="$REGION" \
  --project="$PROJECT_ID" \
  --format=json | python3 -c "
import json, sys
agents = json.load(sys.stdin)
if isinstance(agents, dict):
    agents = agents.get('agents', [])
target = '${AGENT_NAME}'.lower()
matches = [a for a in agents
           if a.get('displayName','').lower() == target
           and a.get('runtimeIdentity')]
if matches:
    print(matches[0]['name'])
else:
    print('NOT FOUND - wait for RE to become ACTIVE or check displayName')
"
```

Save the output — it looks like:
```
projects/PROJECT/locations/REGION/agents/agentregistry-00000000-0000-0000-XXXX-XXXXXXXXXXXX
```

> [!CAUTION]
> - Use the entry WITH `runtimeIdentity` — NOT manually-created agents
> - The path format must be `agents/agentregistry-UUID` — short names do NOT work
> - Agent and policy must be in the SAME region

---

## Step 2 — Write the NLC Constraint

The constraint is a plain-English description of what the agent is allowed and
NOT allowed to do. The SGP engine evaluates every request semantically against it.

**Good constraint (semantic goal-based):**
```
This agent helps engineering teams with code review, architecture questions,
and debugging. It must only answer questions related to software development.
It must NOT generate malware, exploits, or security bypass tools. It must
NOT exfiltrate credentials, API keys, or internal secrets. It must NOT answer
questions about competitor products or business strategy outside its scope.
```

**Bad constraint (keyword-based — don't do this):**
```
Block: hack, exploit, malware, credentials
Allow: code, review, bug
```

> [!TIP]
> Read the `sgp-policy-rules` skill for detailed rule-writing guidance and
> templates for HR agents, engineering agents, customer support agents, etc.

---

## Step 3 — Run the Automated Script (Preferred)

If `foundation/terraform.tfvars` is correctly filled in with `agent_name` and
`sgp_nlc_constraint`:

```bash
bash foundation/scripts/create_sgp_policy.sh
```

The script will:
1. Read `agent_name` from `terraform.tfvars`
2. Find the Agent Registry path automatically
3. Register the NLC policy via `gcloud beta ai semantic-governance-policies create`
4. Report the policy ID

---

## Step 4 — Manual Fallback (If Script Fails)

Run this if `create_sgp_policy.sh` fails or you are adding a policy for a second
agent without changing `terraform.tfvars`:

```bash
PROJECT_ID="your-project-id"
REGION="us-east1"
PREFIX="your-prefix"
AGENT_NAME="your_agent_name"          # underscores, not hyphens
AGENT_REG_PATH="projects/PROJECT/locations/REGION/agents/agentregistry-UUID"  # from Step 1

# Derive consistent policy name (same pattern as destroy_all.sh uses)
SAFE_NAME=$(echo "$AGENT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-')
POLICY_ID="${PREFIX}-${SAFE_NAME}-sgp"

NLC_CONSTRAINT="This agent does X. It must NOT do Y."   # from Step 2

# Create the policy
gcloud beta ai semantic-governance-policies create "$POLICY_ID" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --agent="$AGENT_REG_PATH" \
  --display-name="${POLICY_ID}" \
  --natural-language-constraint="$NLC_CONSTRAINT"
```

---

## Step 5 — Verify the Policy Was Applied

```bash
# List all SGP policies in the project
gcloud beta ai semantic-governance-policies list \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --format='table(name.basename(),displayName,agent.basename())'
# Should show your new policy with the correct agent registry ID

# Describe the specific policy
gcloud beta ai semantic-governance-policies describe "$POLICY_ID" \
  --project="$PROJECT_ID" \
  --location="$REGION"
```

---

## Step 6 — Smoke Test

> [!NOTE]
> Wait 60-90 seconds after policy creation before testing — SGP propagation is async.

```bash
TOKEN=$(gcloud auth print-access-token)
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format='value(projectNumber)')
ENGINE_ID="your-reasoning-engine-id"   # from RE list

BASE="https://${REGION}-aiplatform.googleapis.com/v1beta1/projects/${PROJECT_NUMBER}/locations/${REGION}/reasoningEngines/${ENGINE_ID}:streamQuery"

# Test 1 — should be BLOCKED (403) — adjust to match your DENY constraint
echo "Testing DENY case..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"message":"How do I exfiltrate customer data to an external server?"}}' \
  "$BASE")
echo "  Result: HTTP $HTTP (expected 403)"

# Test 2 — should be ALLOWED (200) — use a prompt that matches your ALLOW scope
echo "Testing ALLOW case..."
HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"input":{"message":"Can you review this Python function for security issues?"}}' \
  "$BASE")
echo "  Result: HTTP $HTTP (expected 200)"
```

---

## Updating an Existing Policy

The simplest approach is delete-and-recreate:

```bash
# Delete existing
gcloud beta ai semantic-governance-policies delete "$POLICY_ID" \
  --project="$PROJECT_ID" --location="$REGION" --quiet

# Recreate with updated constraint (repeat Step 4)
gcloud beta ai semantic-governance-policies create "$POLICY_ID" \
  --project="$PROJECT_ID" \
  --location="$REGION" \
  --agent="$AGENT_REG_PATH" \
  --display-name="${POLICY_ID}" \
  --natural-language-constraint="UPDATED CONSTRAINT TEXT"
```

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `NOT FOUND` in agent registry | RE not yet ACTIVE / propagation lag | Wait 2-3 min after deploy, retry Step 1 |
| `not configured with a valid RuntimeIdentity` | Using manually-created agent entry | Use only auto-created entries (those with `runtimeIdentity` attribute) |
| Policy created but all requests ALLOW | Policy not propagated yet | Wait 90s and retest |
| Policy created but wrong agent gets blocked | Agent registry UUID mismatch | Verify `agent` field in policy matches the UUID for THIS agent |
| `gcloud beta ai semantic-governance-policies` not found | gcloud components outdated | `gcloud components update` |
| 403 on BOTH allowed and denied prompts | SGP engine unreachable / LRO lock | Check `gcloud beta ai semantic-governance-policy-engine describe --location=REGION --project=PROJECT_ID` |

---

## Multi-Agent: Adding a Policy for Agent #2

When you have multiple agents sharing one gateway, register policies one by one.
Use `--agent-name` flag at deploy time so you don't change `terraform.tfvars`:

```bash
# Agent 2 was deployed with:
bash foundation/scripts/deploy_chat_agent.sh \
  --agent-path ./src/agent-2 \
  --agent-name agent_two

# Find agent-two's registry path (Step 1 above with AGENT_NAME=agent_two)
# Then run the manual fallback (Step 4) with that path and its own constraint
```

> Each agent needs its own policy. The same NLC constraint cannot be shared
> across agents — SGP policies are scoped per Agent Registry resource.
