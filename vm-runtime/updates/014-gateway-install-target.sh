#!/usr/bin/env bash
# 014-gateway-install-target.sh -- fix the gateway unit's boot dependencies
# so it actually starts on reboot.
#
# Update 013 installed the :0-targeted unit with:
#   After=graphical.target network-online.target
#   Wants=graphical.target network-online.target
#   WantedBy=graphical.target
#
# On a reboot (observed 2026-04-20 01:37:59 UTC), systemd detected an
# ordering cycle at shutdown:
#   multi-user.target/stop -> openclaw-gateway.service/stop -> graphical.target/stop -> multi-user.target/stop
# and broke it by "deleting" the graphical.target/stop job. On the next
# boot the gateway came up with ConditionResult=no and never ran; the
# chat UI was down until someone manually `systemctl start`'d it.
#
# Fix: drop graphical.target from the unit's After/Wants/WantedBy. The
# ExecStartPre xfce4-session wait (120s) is what actually gates on the
# display being ready -- graphical.target was belt-and-suspenders that
# created more risk than it removed.
#
# Idempotent: overwrite the unit file, disable+reenable to re-create the
# WantedBy symlink under the new target, daemon-reload, and (re)start.
set -euo pipefail

UNIT=/etc/systemd/system/openclaw-gateway.service

cat > "$UNIT" <<'UNITFILE'
[Unit]
Description=OpenClaw Gateway (runs on the shared XFCE :0 session)
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
ExecStartPre=/bin/bash -c 'for _ in $(seq 1 120); do pgrep -u azureuser xfce4-session >/dev/null && exit 0; sleep 1; done; echo "timed out waiting for xfce4-session" >&2; exit 1'
ExecStart=/usr/bin/openclaw gateway
Restart=always
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNITFILE
echo "[update-014] wrote unit file with WantedBy=multi-user.target"

systemctl daemon-reload
# disable then re-enable so the Wants symlink moves from graphical.target.wants
# to multi-user.target.wants.
systemctl disable openclaw-gateway.service >/dev/null 2>&1 || true
systemctl enable openclaw-gateway.service >/dev/null
echo "[update-014] re-enabled under multi-user.target"

# Restart only if already active; don't force a start if ConditionPathExists
# would fail on a fresh data disk.
if systemctl is-active --quiet openclaw-gateway.service; then
    systemctl restart openclaw-gateway.service
    echo "[update-014] restarted (was active)"
else
    systemctl start openclaw-gateway.service || true
    echo "[update-014] attempted start (was inactive; ok if Condition* gates it on fresh data)"
fi
