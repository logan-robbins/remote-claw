#!/usr/bin/env bash
# /opt/claw/verify.sh -- post-deploy health checks for claw VMs
#
# Run on the VM after deploy or upgrade. Exits 0 if all checks pass, 1 otherwise.
# deploy.sh calls this via SSH at the end of every deploy/upgrade.

set -uo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  [PASS] $1"; (( PASS++ )); }
fail() { echo "  [FAIL] $1"; (( FAIL++ )); }
warn() { echo "  [WARN] $1"; (( WARN++ )); }

check() {
    local label="$1"; shift
    if "$@" >/dev/null 2>&1; then
        pass "$label"
    else
        fail "$label"
    fi
}

echo "=== Claw Health Check ==="
echo ""

# -- Disk and filesystem -------------------------------------------------------
echo "Disk:"
check "Data disk mounted at /mnt/claw-data" mountpoint -q /mnt/claw-data
check ".claw-initialized marker exists" test -f /mnt/claw-data/.claw-initialized
check "update-version.txt exists" test -f /mnt/claw-data/update-version.txt

# -- Bind mounts ----------------------------------------------------------------
echo "Mounts:"
check "~/.openclaw is a bind mount" mountpoint -q /home/azureuser/.openclaw
check "~/workspace is a bind mount" mountpoint -q /home/azureuser/workspace
check "~/.openclaw resolves to a directory" test -d /home/azureuser/.openclaw

# -- Config files ---------------------------------------------------------------
echo "Config:"
check "openclaw.json exists" test -f /home/azureuser/.openclaw/openclaw.json
check "openclaw.json is valid JSON" jq empty /home/azureuser/.openclaw/openclaw.json
check "exec-approvals.json exists" test -f /home/azureuser/.openclaw/exec-approvals.json
check ".env exists on data disk" test -f /mnt/claw-data/openclaw/.env

# Verify required env vars are non-empty
env_file="/mnt/claw-data/openclaw/.env"
# At least one provider API key must be set
provider_key_found=false
for var in XAI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY; do
    val=$(grep "^${var}=" "$env_file" 2>/dev/null | cut -d= -f2-)
    if [[ -n "$val" && "$val" != *"your-"*"-here"* ]]; then
        pass "$var is set"
        provider_key_found=true
    fi
done
if [[ "$provider_key_found" != "true" ]]; then
    fail "No provider API key set (need at least one of XAI/OPENAI/ANTHROPIC/MOONSHOT/DEEPSEEK)"
fi

for var in TELEGRAM_BOT_TOKEN; do
    val=$(grep "^${var}=" "$env_file" 2>/dev/null | cut -d= -f2-)
    if [[ -n "$val" && "$val" != *"your-"*"-here"* ]]; then
        pass "$var is set"
    else
        fail "$var is missing or placeholder"
    fi
done

# -- Config values --------------------------------------------------------------
echo "Config values:"
workspace=$(jq -r '.agents.defaults.workspace // empty' /home/azureuser/.openclaw/openclaw.json 2>/dev/null)
if [[ "$workspace" == "/mnt/claw-data/workspace" ]]; then
    pass "workspace points to data disk"
else
    fail "workspace is '$workspace' (expected /mnt/claw-data/workspace)"
fi

sandbox=$(jq -r '.agents.defaults.sandbox.mode // empty' /home/azureuser/.openclaw/openclaw.json 2>/dev/null)
if [[ "$sandbox" == "off" ]]; then
    pass "sandbox mode is off"
else
    warn "sandbox mode is '$sandbox' (expected off)"
fi

telegram_enabled=$(jq -r '.channels.telegram.enabled // empty' /home/azureuser/.openclaw/openclaw.json 2>/dev/null)
if [[ "$telegram_enabled" == "true" ]]; then
    pass "telegram channel enabled"
else
    fail "telegram channel not enabled"
fi

# -- Systemd services -----------------------------------------------------------
echo "Services:"
for svc in lightdm x11vnc openclaw-gateway; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" || "$state" == "activating" ]]; then
        pass "$svc is $state"
    else
        fail "$svc is $state"
    fi
done

# -- Display --------------------------------------------------------------------
echo "Display:"
check "X11 socket /tmp/.X11-unix/X0 exists" test -S /tmp/.X11-unix/X0

# -- VNC ------------------------------------------------------------------------
echo "VNC:"
check "VNC password file exists" test -f /mnt/claw-data/vnc-password.txt
if ss -tlnp 2>/dev/null | grep -q ':5900'; then
    pass "x11vnc listening on port 5900"
else
    fail "nothing listening on port 5900"
fi

# -- Gateway port ---------------------------------------------------------------
echo "Gateway:"
if ss -tlnp 2>/dev/null | grep -q ':18789'; then
    pass "gateway listening on port 18789"
else
    fail "nothing listening on port 18789"
fi

# -- PhantomTouch relay (optional) -----------------------------------------------
echo "PhantomTouch:"
if [[ -f /etc/systemd/system/phantom-relay.service ]]; then
    state=$(systemctl is-active phantom-relay 2>/dev/null)
    if [[ "$state" == "active" || "$state" == "activating" ]]; then
        pass "phantom-relay is $state"
    else
        fail "phantom-relay is $state"
    fi
    if ss -tlnp 2>/dev/null | grep -q ':9090'; then
        pass "relay HTTP listening on port 9090"
    else
        fail "nothing listening on port 9090"
    fi
    if ss -tlnp 2>/dev/null | grep -q ':9091'; then
        pass "relay WS listening on port 9091"
    else
        fail "nothing listening on port 9091"
    fi
else
    warn "phantom-relay not installed (optional)"
fi

# -- Binaries -------------------------------------------------------------------
echo "Binaries:"
for bin in openclaw node npm google-chrome-stable claude tmux jq git x11vnc; do
    if command -v "$bin" >/dev/null 2>&1; then
        pass "$bin found"
    else
        fail "$bin not found"
    fi
done

# -- Boot script ----------------------------------------------------------------
echo "Boot infrastructure:"
check "/opt/claw/boot.sh exists and is executable" test -x /opt/claw/boot.sh
check "/opt/claw/run-updates.sh exists and is executable" test -x /opt/claw/run-updates.sh

# -- Summary --------------------------------------------------------------------
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $WARN warnings ==="

if (( FAIL > 0 )); then
    exit 1
fi
exit 0
