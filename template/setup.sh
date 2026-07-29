#!/usr/bin/env bash
# =============================================================================
# setup.sh — Agent-Gateway-Foundation bootstrap for team repos (Path C)
#
# Copy this file into YOUR team repo root. Do NOT copy it into the foundation.
#
# Usage:
#   bash setup.sh            # first-time setup
#   bash setup.sh --upgrade  # re-clone at new FOUNDATION_VERSION
#
# What it does:
#   1. Clones Agent-Gateway-Foundation into foundation/ (gitignored)
#   2. Checks out the pinned FOUNDATION_VERSION
#   3. Creates foundation/terraform.tfvars from the example template
#   4. Symlinks all foundation skills into ~/.gemini/config/skills/
#
# After running:
#   Fill in foundation/terraform.tfvars, then:
#     terraform -chdir=foundation init
#     terraform -chdir=foundation apply -auto-approve
#     bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent
# =============================================================================

set -euo pipefail

# ── Version pin ───────────────────────────────────────────────────────────────
# Bump this when upgrading the foundation. Commit the change to your team repo
# so the version is tracked in git history. Each developer then runs:
#   cd foundation && git fetch && git checkout vX.Y.Z && cd ..
#   terraform -chdir=foundation apply -auto-approve
FOUNDATION_VERSION="v1.0.0"
FOUNDATION_URL="https://github.com/GCP-Architecture-Guides/Agent-Gateway-Foundation.git"

# ── Parse args ────────────────────────────────────────────────────────────────
UPGRADE=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --upgrade) UPGRADE=true; shift ;;
    --help|-h)
      echo "Usage: $0 [--upgrade]"
      echo ""
      echo "  (no args)   First-time setup: clone foundation, create tfvars, link skills"
      echo "  --upgrade   Re-clone at new FOUNDATION_VERSION (edit the version above first)"
      exit 0 ;;
    *) echo "❌ Unknown argument: $1"; exit 1 ;;
  esac
done

# ── Guard: already set up ─────────────────────────────────────────────────────
if [[ -d "foundation/.git" && "$UPGRADE" == "false" ]]; then
  CURRENT=$(cd foundation && git describe --tags 2>/dev/null || git rev-parse --short HEAD)
  echo "✅ Foundation already cloned at $CURRENT"
  echo "   To upgrade: edit FOUNDATION_VERSION in setup.sh, then run: bash setup.sh --upgrade"
  exit 0
fi

# ── Upgrade: remove old clone ─────────────────────────────────────────────────
if [[ "$UPGRADE" == "true" && -d "foundation" ]]; then
  echo "🔄 Removing existing foundation/ for upgrade..."
  rm -rf foundation
fi

# ── Clone ─────────────────────────────────────────────────────────────────────
echo "Cloning Agent-Gateway-Foundation at $FOUNDATION_VERSION..."
git clone "$FOUNDATION_URL" foundation
cd foundation && git checkout "$FOUNDATION_VERSION" && cd ..
echo "✅ Cloned at $FOUNDATION_VERSION"

# ── terraform.tfvars ──────────────────────────────────────────────────────────
if [[ ! -f "foundation/terraform.tfvars" ]]; then
  cp foundation/terraform.tfvars.example foundation/terraform.tfvars
  echo "📝 Created foundation/terraform.tfvars — fill in your GCP project details."
else
  echo "ℹ️  foundation/terraform.tfvars already exists — skipping template copy."
fi

# ── Antigravity skills ────────────────────────────────────────────────────────
mkdir -p ~/.gemini/config/skills
SKILLS_LINKED=0
for d in foundation/skills/*/; do
  SKILL_NAME="$(basename "$d")"
  ln -sf "$(pwd)/$d" ~/.gemini/config/skills/"$SKILL_NAME"
  SKILLS_LINKED=$((SKILLS_LINKED + 1))
done
echo "🔗 $SKILLS_LINKED Antigravity skills linked to ~/.gemini/config/skills/"

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "✅ Setup complete — Agent-Gateway-Foundation $FOUNDATION_VERSION"
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Next steps:"
echo "  1. Fill in foundation/terraform.tfvars (project_id, org_id, location, prefix)"
echo "  2. terraform -chdir=foundation init"
echo "  3. terraform -chdir=foundation apply -auto-approve"
echo "  4. bash foundation/scripts/deploy_chat_agent.sh --agent-path ./src/my-agent"
echo ""
echo "Ask Antigravity: 'Set up the Agent Gateway for my project'"
echo "It will read the agw-foundation-adoption skill and guide you through."
