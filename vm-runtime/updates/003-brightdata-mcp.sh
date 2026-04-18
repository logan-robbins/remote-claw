#!/usr/bin/env bash
# 003-brightdata-mcp.sh -- register Bright Data MCP server with OpenClaw
#
# Uses `openclaw mcp set` (the CLI) instead of jq-poking openclaw.json
# directly, so the schema stays in sync with whatever OpenClaw version
# is installed (the deprecated root `mcpServers` key was removed in
# OpenClaw 2026.4.x — config-poking against an old schema breaks the
# gateway with "Unrecognized key: mcpServers").

ENV_FILE="/mnt/claw-data/openclaw/.env"

API_TOKEN=$(grep -E '^BRIGHTDATA_API_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | xargs) || true

if [[ -z "$API_TOKEN" ]]; then
    echo "[update-005] No BRIGHTDATA_API_TOKEN in .env, skipping MCP setup"
    exit 0
fi

JSON=$(jq -nc --arg t "$API_TOKEN" '{
  command: "npx",
  args: ["@brightdata/mcp"],
  env: { API_TOKEN: $t }
}')

sudo -u azureuser openclaw mcp set brightdata "$JSON" >/dev/null

echo "[update-005] Registered Bright Data MCP server via openclaw mcp set"
