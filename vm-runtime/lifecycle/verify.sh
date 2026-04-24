#!/usr/bin/env bash
# /opt/claw/verify.sh -- post-deploy health checks for claw VMs
#
# Run on the VM after deploy or upgrade. Exits 0 if all checks pass, 1 otherwise.

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

env_file="/mnt/claw-data/openclaw/.env"
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

# -- AMD GPU --------------------------------------------------------------------
echo "GPU:"
if lspci -d 1002:7461 2>/dev/null | grep -q 7461; then
    pass "AMD Radeon Pro V710 (1002:7461) detected"
else
    fail "AMD Radeon Pro V710 not detected on PCI bus"
fi
if lsmod 2>/dev/null | grep -q '^amdgpu'; then
    pass "amdgpu kernel module loaded"
elif lsmod 2>/dev/null | grep -Eq '^(amddrm_ttm_helper|amdttm|amddrm_buddy|amddrm_exec|amdkcl|hyperv_drm)\b'; then
    warn "amdgpu not present, but AMD/Hyper-V graphics helper modules are loaded"
else
    warn "no AMD-specific kernel modules detected"
fi
if command -v amd-smi >/dev/null 2>&1; then
    if amd-smi monitor -p 2>/dev/null | head -n1 | grep -qi 'gpu\|power'; then
        pass "amd-smi reports GPU state"
    else
        warn "amd-smi installed but did not report state"
    fi
else
    warn "amd-smi not installed (graphics-only install may omit it)"
fi
check "Xorg dummy driver config /etc/X11/xorg.conf.d/99-dummy.conf exists" test -f /etc/X11/xorg.conf.d/99-dummy.conf

# -- Systemd services -----------------------------------------------------------
echo "Services (human display):"
for svc in lightdm xrdp sunshine; do
    state=$(systemctl is-active "$svc" 2>/dev/null)
    if [[ "$state" == "active" || "$state" == "activating" ]]; then
        pass "$svc is $state"
    else
        fail "$svc is $state"
    fi
done

echo "Services (agent runtime):"
state=$(systemctl is-active openclaw-gateway 2>/dev/null)
if [[ "$state" == "active" || "$state" == "activating" ]]; then
    pass "openclaw-gateway is $state"
else
    fail "openclaw-gateway is $state"
fi

for svc in openclaw-xvfb openclaw-wm openclaw-observe; do
    state=$(systemctl is-active "$svc" 2>/dev/null || true)
    if [[ "$state" == "inactive" || "$state" == "unknown" || "$state" == "failed" ]]; then
        pass "$svc retired/not running"
    else
        warn "$svc unexpectedly $state"
    fi
done

# -- Display --------------------------------------------------------------------
echo "Displays:"
check "X11 socket /tmp/.X11-unix/X0 exists (human :0)" test -S /tmp/.X11-unix/X0
if [[ -S /tmp/.X11-unix/X99 ]]; then
    warn "X11 socket /tmp/.X11-unix/X99 exists (legacy agent display)"
else
    pass "No dedicated :99 display present (agent shares :0)"
fi

# -- Remote desktop ports -------------------------------------------------------
echo "Remote-desktop ports:"
if ss -tlnp 2>/dev/null | grep -q ':3389'; then
    pass "xrdp listening on port 3389"
else
    fail "nothing listening on 3389 (xrdp)"
fi
if ss -tlnp 2>/dev/null | grep -q ':47989'; then
    pass "sunshine listening on port 47989 (HTTP)"
else
    fail "nothing listening on 47989 (Sunshine)"
fi
if ss -tlnp 2>/dev/null | grep -q ':5901'; then
    pass "openclaw-observe x11vnc listening on port 5901"
else
    warn "no observer on 5901 (openclaw-observe is optional)"
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
for bin in openclaw node npm google-chrome-stable claude tmux jq git xrdp sunshine Xvfb xfwm4; do
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
