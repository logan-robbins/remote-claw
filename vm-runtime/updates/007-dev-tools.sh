#!/usr/bin/env bash
# 007-dev-tools.sh -- install gh CLI, codex CLI, generate persistent SSH key

# gh CLI
if ! command -v gh >/dev/null 2>&1; then
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list
    apt-get update -qq
    apt-get install -y gh
fi

# codex CLI
if ! command -v codex >/dev/null 2>&1; then
    npm install -g @openai/codex 2>/dev/null || true
fi

# SSH key on data disk (persists across VM replacements)
SSH_DIR="/mnt/claw-data/ssh"
if [ ! -f "$SSH_DIR/id_ed25519" ]; then
    mkdir -p "$SSH_DIR"
    ssh-keygen -t ed25519 -f "$SSH_DIR/id_ed25519" -N "" -C "azureuser@$(hostname)"
    chown -R azureuser:azureuser "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    chmod 600 "$SSH_DIR/id_ed25519"
    chmod 644 "$SSH_DIR/id_ed25519.pub"
fi

# Symlink into ~/.ssh
mkdir -p /home/azureuser/.ssh
ln -sf "$SSH_DIR/id_ed25519" /home/azureuser/.ssh/id_ed25519
ln -sf "$SSH_DIR/id_ed25519.pub" /home/azureuser/.ssh/id_ed25519.pub
chown -h azureuser:azureuser /home/azureuser/.ssh/id_ed25519 /home/azureuser/.ssh/id_ed25519.pub

# Git config
sudo -u azureuser git config --global user.name "$(hostname)"
sudo -u azureuser git config --global user.email "$(hostname)@openclaw.local"

echo "[update-009] Installed gh, codex, SSH key, git config"
