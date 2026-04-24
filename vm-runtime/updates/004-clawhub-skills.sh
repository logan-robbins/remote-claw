#!/usr/bin/env bash
# 004-clawhub-skills.sh -- install clawhub CLI and sync vendored skills
set -euo pipefail

WS="/mnt/claw-data/workspace"
DEFAULTS="/opt/claw/defaults/workspace"

# Install clawhub CLI globally for later operator use.
npm install -g clawhub 2>/dev/null || true

install -d -o azureuser -g azureuser -m 0755 \
    "$WS/skills" \
    "$WS/.clawhub"

if [[ -d "$DEFAULTS/skills" ]]; then
    cp -a "$DEFAULTS/skills/." "$WS/skills/"
fi

if [[ -f "$DEFAULTS/.clawhub/lock.json" ]]; then
    cp "$DEFAULTS/.clawhub/lock.json" "$WS/.clawhub/lock.json"
fi

chown -R azureuser:azureuser "$WS/skills" "$WS/.clawhub"
echo "[update-004] Synced vendored workspace skills and ClawHub lockfile"
