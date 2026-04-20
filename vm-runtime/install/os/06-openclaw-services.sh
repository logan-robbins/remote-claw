#!/usr/bin/env bash
# 06-openclaw-services.sh -- systemd unit for the OpenClaw agent running on
# the XFCE :0 session shared with the human operator.
#
# Why :0 (not a dedicated Xvfb):
#   The earlier design parked the agent on :99 so it would survive xrdp
#   session churn. Sunshine/Moonlight don't spawn new sessions (they
#   capture the existing display), so there's no churn to defend against.
#   Running everything on :0 means one Chrome process, one user-data-dir
#   (~/.config/google-chrome), and one browser session — so when the human
#   Moonlights in and logs into GitHub/Google/etc., the agent inherits
#   that auth state (and vice versa). That's what the operator actually
#   wants: "same functionality as running on my local Mac."
#
# Trade-off: operator and agent share the mouse/keyboard on :0. Active
# input races are expected and fine for the observe-and-assist workflow.
#
# :0 is owned by LightDM-autologin (xfce4-session running as azureuser).
# The service waits for xfce4-session, then launches the gateway with
# DISPLAY=:0 and XAUTHORITY=/home/azureuser/.Xauthority (same pattern as
# the already-working sunshine.service).
set -euo pipefail

cat > /etc/systemd/system/openclaw-gateway.service <<'UNIT'
[Unit]
Description=OpenClaw Gateway (runs on the shared XFCE :0 session)
# Avoid graphical.target here: WantedBy=graphical.target + After=graphical.target
# creates a shutdown-ordering cycle with multi-user.target (observed on a reboot
# 2026-04-20 where systemd resolved the cycle by dropping the service from the
# boot set entirely -- ConditionResult=no, never started). The xfce4-session
# wait in ExecStartPre already gates on the display being ready.
After=network-online.target
Wants=network-online.target
ConditionPathExists=/home/azureuser/.openclaw/openclaw.json
ConditionPathExists=/home/azureuser/.openclaw/.env

[Service]
Type=simple
User=azureuser
Group=azureuser
WorkingDirectory=/home/azureuser
Environment=HOME=/home/azureuser
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/azureuser/.Xauthority
Environment=XDG_RUNTIME_DIR=/run/user/1000
Environment=NODE_COMPILE_CACHE=/var/tmp/openclaw-compile-cache
Environment=OPENCLAW_NO_RESPAWN=1
EnvironmentFile=/home/azureuser/.openclaw/.env
# Wait for the XFCE session on :0 to be fully up before launching the
# gateway. Same pattern sunshine.service uses. 120s is generous — typical
# cold boot has xfce4-session live in ~15-20s.
ExecStartPre=/bin/bash -c 'for _ in $(seq 1 120); do pgrep -u azureuser xfce4-session >/dev/null && exit 0; sleep 1; done; echo "timed out waiting for xfce4-session" >&2; exit 1'
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload

# Enable the service so it starts on boot. ConditionPathExists on the data
# disk's openclaw.json / .env keeps it inactive on fresh images until
# boot.sh seeds the data disk.
systemctl enable openclaw-gateway.service
