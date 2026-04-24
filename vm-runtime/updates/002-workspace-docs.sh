#!/usr/bin/env bash
# 002-workspace-docs.sh -- sync the vendored workspace baseline onto the data disk
set -euo pipefail

DEFAULTS="/opt/claw/defaults/workspace"
WS="/mnt/claw-data/workspace"

install -d -o azureuser -g azureuser -m 0755 \
    "$WS/.claude" \
    "$WS/.clawhub" \
    "$WS/.openclaw"

for file in AGENTS.md CLAUDE.md HEARTBEAT.md IDENTITY.md SOUL.md TOOLS.md USER.md; do
    if [[ -f "$DEFAULTS/$file" ]]; then
        cp "$DEFAULTS/$file" "$WS/$file"
        chown azureuser:azureuser "$WS/$file"
    fi
done

for rel in .claude/settings.local.json .clawhub/lock.json .openclaw/workspace-state.json; do
    if [[ -f "$DEFAULTS/$rel" ]]; then
        cp "$DEFAULTS/$rel" "$WS/$rel"
        chown azureuser:azureuser "$WS/$rel"
    fi
done

echo "[update-002] Synced workspace baseline files"
