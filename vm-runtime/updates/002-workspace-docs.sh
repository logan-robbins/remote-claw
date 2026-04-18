#!/usr/bin/env bash
# 002-workspace-docs.sh -- deploy AGENTS.md and TOOLS.md to existing data disks
DEFAULTS="/opt/claw/defaults/workspace"
WS="/mnt/claw-data/workspace"

cp "$DEFAULTS/AGENTS.md" "$WS/AGENTS.md"
cp "$DEFAULTS/TOOLS.md"  "$WS/TOOLS.md"
chown azureuser:azureuser "$WS/AGENTS.md" "$WS/TOOLS.md"
echo "[update-004] Deployed AGENTS.md and TOOLS.md"
