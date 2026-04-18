#!/usr/bin/env bash
# 009-lossless-context.sh -- install the lossless-claw context-engine plugin.
#
# Per 2026.4.x docs (https://docs.openclaw.ai/cli/plugins), use the agent CLI:
#   openclaw plugins install <npm-spec>
#
# The seeded defaults/openclaw.json already references plugins.entries.lossless-claw,
# plugins.slots.contextEngine, and plugins.allow — this update supplies the
# actual plugin code under ~/.openclaw/extensions/lossless-claw.
#
# Errors are NOT swallowed — the previous iteration used `2>/dev/null || true`
# which hid failures and left a stale config entry with no backing plugin.
set -euo pipefail

PLUGIN_ID="lossless-claw"
PLUGIN_SPEC="@martian-engineering/lossless-claw"

# Idempotent: skip if already installed and loaded
if sudo -u azureuser openclaw plugins list 2>/dev/null | grep -qE "\b${PLUGIN_ID}\b.*loaded"; then
    echo "[update-009] ${PLUGIN_ID} already installed and loaded"
    exit 0
fi

echo "[update-009] Installing plugin ${PLUGIN_SPEC}..."
sudo -u azureuser openclaw plugins install "$PLUGIN_SPEC"

# Gateway needs a reload to pick up the plugin
sudo systemctl restart openclaw-gateway 2>/dev/null || true

echo "[update-009] Installed ${PLUGIN_ID}"
