#!/usr/bin/env bash
# 013-mcp-reapply.sh -- re-register MCP servers via the current openclaw CLI.
#
# Why: updates 005 and 007 originally jq-poked the deprecated root
# `mcpServers` key into openclaw.json. OpenClaw 2026.4.x rejects that key
# and `openclaw doctor --fix` strips it, leaving a VM that already advanced
# past 005/007 with no MCP servers registered. This re-applies whichever
# of brightdata + phantom-touch the .env has tokens for, using the current
# `openclaw mcp set` CLI (schema-stable across OpenClaw versions).
#
# Idempotent: openclaw mcp set is an upsert — re-running has no extra effect.

ENV_FILE="/mnt/claw-data/openclaw/.env"

if [[ ! -f "$ENV_FILE" ]]; then
    echo "[update-013] No .env at $ENV_FILE, skipping"
    exit 0
fi

API_TOKEN=$(grep -E '^BRIGHTDATA_API_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | xargs) || true
if [[ -n "$API_TOKEN" ]]; then
    JSON=$(jq -nc --arg t "$API_TOKEN" '{
      command: "npx",
      args: ["@brightdata/mcp"],
      env: { API_TOKEN: $t }
    }')
    sudo -u azureuser openclaw mcp set brightdata "$JSON" >/dev/null
    echo "[update-013] Re-registered Bright Data MCP server"
fi

RELAY_TOKEN=$(grep -E '^RELAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | xargs) || true
if [[ -n "$RELAY_TOKEN" && -d /opt/claw/phantom-touch/gateway ]]; then
    JSON=$(jq -nc '{
      command: "python3",
      args: ["/opt/claw/phantom-touch/gateway/mcp_server.py"],
      env: { PHANTOM_TOUCH_URL: "http://localhost:9090" }
    }')
    sudo -u azureuser openclaw mcp set phantom-touch "$JSON" >/dev/null
    echo "[update-013] Re-registered PhantomTouch MCP server"
fi

# Restart the gateway so it picks up the new MCP config (no harm if already restarting)
systemctl restart openclaw-gateway 2>/dev/null || true

echo "[update-013] MCP re-apply complete"
