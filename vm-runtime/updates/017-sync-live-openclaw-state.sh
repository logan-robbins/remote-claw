#!/usr/bin/env bash
# 017-sync-live-openclaw-state.sh -- align existing data disks with the vendored
# workspace/OpenClaw defaults while preserving runtime-generated secrets.
set -euo pipefail

ADMIN_USER="azureuser"
DEFAULTS="/opt/claw/defaults"
OPENCLAW_DIR="/mnt/claw-data/openclaw"
WS="/mnt/claw-data/workspace"

install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0755 \
    "$WS/.claude" \
    "$WS/.clawhub" \
    "$WS/.openclaw" \
    "$WS/skills"

for file in AGENTS.md CLAUDE.md HEARTBEAT.md IDENTITY.md SOUL.md TOOLS.md USER.md; do
    if [[ -f "$DEFAULTS/workspace/$file" ]]; then
        cp "$DEFAULTS/workspace/$file" "$WS/$file"
        chown "$ADMIN_USER:$ADMIN_USER" "$WS/$file"
    fi
done

for rel in .claude/settings.local.json .clawhub/lock.json .openclaw/workspace-state.json; do
    if [[ -f "$DEFAULTS/workspace/$rel" ]]; then
        install -d -o "$ADMIN_USER" -g "$ADMIN_USER" -m 0755 "$WS/$(dirname "$rel")"
        cp "$DEFAULTS/workspace/$rel" "$WS/$rel"
        chown "$ADMIN_USER:$ADMIN_USER" "$WS/$rel"
    fi
done

if [[ -d "$DEFAULTS/workspace/skills" ]]; then
    cp -a "$DEFAULTS/workspace/skills/." "$WS/skills/"
    chown -R "$ADMIN_USER:$ADMIN_USER" "$WS/skills"
fi

if [[ -f "$DEFAULTS/openclaw/openclaw.json" ]]; then
    tmp=$(mktemp)
    if [[ -f "$OPENCLAW_DIR/openclaw.json" ]]; then
        jq -s '
          .[0] as $defaults |
          .[1] as $live |
          $defaults
          | if ($live.gateway.auth.token? // "") != "" then .gateway.auth.token = $live.gateway.auth.token else . end
          | if $live.plugins.installs? then .plugins.installs = $live.plugins.installs else . end
          | if $live.meta? then .meta = $live.meta else . end
        ' "$DEFAULTS/openclaw/openclaw.json" "$OPENCLAW_DIR/openclaw.json" > "$tmp"
    else
        cp "$DEFAULTS/openclaw/openclaw.json" "$tmp"
    fi
    mv "$tmp" "$OPENCLAW_DIR/openclaw.json"
    chown "$ADMIN_USER:$ADMIN_USER" "$OPENCLAW_DIR/openclaw.json"
fi

if [[ -f "$DEFAULTS/openclaw/exec-approvals.json" ]]; then
    tmp=$(mktemp)
    if [[ -f "$OPENCLAW_DIR/exec-approvals.json" ]]; then
        jq -s '
          .[0] as $defaults |
          .[1] as $live |
          $defaults
          | if ($live.socket.path? // "") != "" then .socket.path = $live.socket.path else . end
          | if ($live.socket.token? // "") != "" then .socket.token = $live.socket.token else . end
        ' "$DEFAULTS/openclaw/exec-approvals.json" "$OPENCLAW_DIR/exec-approvals.json" > "$tmp"
    else
        cp "$DEFAULTS/openclaw/exec-approvals.json" "$tmp"
    fi
    mv "$tmp" "$OPENCLAW_DIR/exec-approvals.json"
    chown "$ADMIN_USER:$ADMIN_USER" "$OPENCLAW_DIR/exec-approvals.json"
fi

echo "[update-017] Synced existing data disk state from vendored defaults"
