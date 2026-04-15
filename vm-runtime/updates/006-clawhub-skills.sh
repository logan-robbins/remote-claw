#!/usr/bin/env bash
# 006-clawhub-skills.sh -- install clawhub CLI and default skills
WS="/mnt/claw-data/workspace"

# Install clawhub CLI globally
npm install -g clawhub 2>/dev/null || true

# Install skills into workspace
cd "$WS"
sudo -u azureuser npx clawhub install mcporter 2>/dev/null || true
sudo -u azureuser npx clawhub install github 2>/dev/null || true
sudo -u azureuser npx clawhub install tmux 2>/dev/null || true

echo "[update-006] Installed clawhub skills: mcporter, github, tmux"
