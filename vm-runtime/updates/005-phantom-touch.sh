#!/usr/bin/env bash
# 005-phantom-touch.sh -- install PhantomTouch relay server and register MCP server
ENV_FILE="/mnt/claw-data/openclaw/.env"
INSTALL_DIR="/opt/claw/phantom-touch"

RELAY_TOKEN=$(grep -E '^RELAY_TOKEN=' "$ENV_FILE" 2>/dev/null | cut -d= -f2- | xargs) || true

if [[ -z "$RELAY_TOKEN" ]]; then
    echo "[update-007] No RELAY_TOKEN in .env, skipping PhantomTouch setup"
    exit 0
fi

if [[ -f "${INSTALL_DIR}/gateway/requirements.txt" ]]; then
    pip3 install -q -r "${INSTALL_DIR}/gateway/requirements.txt" 2>/dev/null || true
fi

cat > /etc/systemd/system/phantom-relay.service <<'UNIT'
[Unit]
Description=PhantomTouch Relay Server
After=network.target
Wants=network.target

[Service]
Type=simple
User=azureuser
WorkingDirectory=/opt/claw/phantom-touch/gateway
EnvironmentFile=/mnt/claw-data/openclaw/.env
ExecStart=/usr/bin/python3 relay_server.py
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable phantom-relay 2>/dev/null || true

# Register the MCP server via the OpenClaw CLI (current schema; the old
# root .mcpServers key is rejected in OpenClaw 2026.4.x).
JSON=$(jq -nc '{
  command: "python3",
  args: ["/opt/claw/phantom-touch/gateway/mcp_server.py"],
  env: { PHANTOM_TOUCH_URL: "http://localhost:9090" }
}')
sudo -u azureuser openclaw mcp set phantom-touch "$JSON" >/dev/null

echo "[update-007] PhantomTouch relay installed and MCP server registered"
