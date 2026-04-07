#!/bin/bash
# ============================================================================
# Claw Runtime Init Script (SSH-injected by deploy.sh)
# ============================================================================
# This script runs on a freshly-deployed claw VM AFTER it boots from the
# specialized image. It mounts the data disk, seeds config files from
# templates (with secrets substituted), starts services, and runs post-start
# validation.
#
# Runs as root (via sudo). Expects to be in /tmp on the target VM, with
# secrets already substituted into the template placeholders below.
#
# Template placeholders replaced by deploy.sh before SCP:
#   __XAI_API_KEY__           xAI API key
#   __TELEGRAM_BOT_TOKEN__    Telegram bot token
#   __TELEGRAM_DM_POLICY__    "allowlist" or "open"
#   __TELEGRAM_ALLOW_FROM__   JSON inner value: "123456789" or "*"
#   __RDP_PASSWORD__          Random RDP password
# ============================================================================

set -euo pipefail
exec > /var/log/openclaw-runtime-init.log 2>&1

echo "=== OpenClaw runtime init starting ==="

# ---------------------------------------------------------------
# Set RDP password for azureuser
# ---------------------------------------------------------------
echo "Setting RDP password..."
echo 'azureuser:__RDP_PASSWORD__' | chpasswd

# ---------------------------------------------------------------
# Mount the data disk (Azure attaches at LUN 0)
# ---------------------------------------------------------------
DATA_DEV="/dev/disk/azure/scsi1/lun0"
DATA_MOUNT="/data"

echo "Mounting data disk..."
mkdir -p "$DATA_MOUNT"

if ! blkid "$DATA_DEV" &>/dev/null; then
    echo "Fresh data disk detected. Formatting ext4..."
    mkfs.ext4 -F "$DATA_DEV"
else
    echo "Existing data disk detected. Preserving data."
fi

if ! mountpoint -q "$DATA_MOUNT"; then
    mount "$DATA_DEV" "$DATA_MOUNT"
fi

# Persist mount across reboots
if ! grep -q "$DATA_MOUNT" /etc/fstab; then
    echo "$DATA_DEV $DATA_MOUNT ext4 defaults,nofail 0 2" >> /etc/fstab
fi

# ---------------------------------------------------------------
# Initialize /data/openclaw and /data/workspace
# ---------------------------------------------------------------
mkdir -p "$DATA_MOUNT/openclaw" "$DATA_MOUNT/workspace"

# Seed .env from inline heredoc if missing
if [[ ! -f "$DATA_MOUNT/openclaw/.env" ]]; then
    echo "Seeding .env..."
    cat > "$DATA_MOUNT/openclaw/.env" << 'ENVEOF'
XAI_API_KEY=__XAI_API_KEY__
TELEGRAM_BOT_TOKEN=__TELEGRAM_BOT_TOKEN__
ENVEOF
    chmod 600 "$DATA_MOUNT/openclaw/.env"
else
    echo "Existing .env on data disk. Keeping it."
fi

# Seed openclaw.json from inline heredoc if missing
if [[ ! -f "$DATA_MOUNT/openclaw/openclaw.json" ]]; then
    echo "Seeding openclaw.json..."
    cat > "$DATA_MOUNT/openclaw/openclaw.json" << 'CFGEOF'
{
  // --- Agent defaults ---
  "agents": {
    "defaults": {
      "model": {
        "primary": "xai/grok-4"
      },
      "workspace": "/home/azureuser/workspace",
      "maxConcurrent": 4,
      "sandbox": {
        "mode": "off"
      },
      "elevatedDefault": "full"
    },
    "list": [
      {
        "id": "main",
        "default": true
      }
    ]
  },

  // --- Model provider ---
  "models": {
    "mode": "merge",
    "providers": {
      "xai": {
        "baseUrl": "https://api.x.ai/v1",
        "api": "openai-completions",
        "models": [
          {
            "id": "grok-4",
            "name": "Grok 4",
            "reasoning": false,
            "input": ["text"],
            "contextWindow": 200000,
            "maxTokens": 8192
          }
        ]
      }
    }
  },

  // --- Channels ---
  "channels": {
    "telegram": {
      "enabled": true,
      "dmPolicy": "__TELEGRAM_DM_POLICY__",
      "allowFrom": [__TELEGRAM_ALLOW_FROM__],
      "groupPolicy": "disabled",
      "streaming": "partial"
    }
  },

  // --- Gateway ---
  "gateway": {
    "port": 18789,
    "mode": "local",
    "bind": "loopback"
  },

  // --- Tools: full autonomy ---
  "tools": {
    "exec": {
      "security": "full",
      "ask": "off",
      "backgroundMs": 10000,
      "timeoutSec": 1800
    },
    "web": {
      "search": { "enabled": true },
      "fetch": { "enabled": true }
    }
  },

  // --- Browser: headed on Xvfb :99 ---
  "browser": {
    "enabled": true,
    "executablePath": "/usr/bin/google-chrome-stable",
    "headless": false,
    "noSandbox": true
  },

  // --- Logging ---
  "logging": {
    "redactSensitive": "tools"
  }
}
CFGEOF
    chmod 644 "$DATA_MOUNT/openclaw/openclaw.json"
else
    echo "Existing openclaw.json on data disk. Keeping it."
fi

# Seed exec-approvals.json if missing
if [[ ! -f "$DATA_MOUNT/openclaw/exec-approvals.json" ]]; then
    cat > "$DATA_MOUNT/openclaw/exec-approvals.json" << 'APPROVEEOF'
{
  "version": 1,
  "defaults": {
    "security": "full",
    "ask": "off",
    "askFallback": "full"
  },
  "agents": {
    "*": {
      "security": "full",
      "ask": "off",
      "askFallback": "full",
      "allowlist": [
        { "pattern": "**" }
      ]
    },
    "main": {
      "security": "full",
      "ask": "off",
      "askFallback": "full",
      "allowlist": [
        { "pattern": "**" }
      ]
    }
  }
}
APPROVEEOF
    chmod 644 "$DATA_MOUNT/openclaw/exec-approvals.json"
fi

chown -R azureuser:azureuser "$DATA_MOUNT"

# ---------------------------------------------------------------
# Symlink /data/openclaw -> ~/.openclaw and /data/workspace -> ~/workspace
# ---------------------------------------------------------------
echo "Creating symlinks..."
rm -rf /home/azureuser/.openclaw /home/azureuser/workspace 2>/dev/null || true
ln -s "$DATA_MOUNT/openclaw" /home/azureuser/.openclaw
ln -s "$DATA_MOUNT/workspace" /home/azureuser/workspace
chown -h azureuser:azureuser /home/azureuser/.openclaw /home/azureuser/workspace

# ---------------------------------------------------------------
# Make sure iptables IMDS block is active (baked rule should already be in place)
# ---------------------------------------------------------------
if ! iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null; then
    echo "Re-applying IMDS block..."
    iptables -A OUTPUT -d 169.254.169.254 -j DROP
    iptables-save > /etc/iptables/rules.v4
fi

# ---------------------------------------------------------------
# Start services (already enabled in the image)
# ---------------------------------------------------------------
echo "Starting services..."
systemctl daemon-reload
systemctl restart xvfb.service
systemctl restart x11vnc-xvfb.service
systemctl restart openclaw-gateway.service

# ---------------------------------------------------------------
# Post-start: run doctor, remove stray gateway.auth, set approvals
# ---------------------------------------------------------------
sleep 5
su - azureuser -c "openclaw doctor --fix" 2>/dev/null || true
su - azureuser -c "openclaw config unset gateway.auth" 2>/dev/null || true
su - azureuser -c 'openclaw approvals allowlist add --agent "*" "**"' 2>/dev/null || true
su - azureuser -c 'openclaw approvals allowlist add --agent "main" "**"' 2>/dev/null || true

echo "=== OpenClaw runtime init complete ==="
