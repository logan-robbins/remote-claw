#!/usr/bin/env bash
# 006-deep-research-skill.sh -- deploy deep-research skill to existing data disks
WS="/mnt/claw-data/workspace"
DEFAULTS="/opt/claw/defaults/workspace"

mkdir -p "$WS/skills/deep-research"
cp "$DEFAULTS/skills/deep-research/SKILL.md" "$WS/skills/deep-research/SKILL.md"
chown -R azureuser:azureuser "$WS/skills/deep-research"

echo "[update-007] Deployed deep-research skill"
