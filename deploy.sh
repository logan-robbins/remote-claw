#!/usr/bin/env bash
# Deploy a full OpenClaw VM: Ubuntu 24.04 + xfce4 + lightdm autologin + x11vnc
# on :0 + OpenClaw + Google Chrome + Telegram Desktop, auto-starting an OpenClaw
# gateway bound to Telegram at boot so the moment the machine comes up you can
# message the bot.
#
# Based on:
#   https://learn.microsoft.com/en-us/azure/virtual-machines/linux/use-remote-desktop
#   https://docs.openclaw.ai/tools/browser-linux-troubleshooting

set -euo pipefail

RG="${RG:-rg-linux-desktop}"
LOCATION="${LOCATION:-eastus}"
VM_NAME="${VM_NAME:-linux-desktop}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="${SCRIPT_DIR}/cloud-init.yaml"
ENV_FILE="${SCRIPT_DIR}/.env"
SOUL_FILE="${SCRIPT_DIR}/SOUL.md"
VM_STATE_FILE="${SCRIPT_DIR}/.vm-state"

# --- SSH key selection --------------------------------------------------------
# Precedence:
#   1. $SSH_KEY_FILE env var wins if set and the file exists.
#   2. If ~/.ssh/ has exactly one *.pub, auto-select it (print what was picked).
#   3. If multiple *.pub files exist, prompt the user to choose.
#   4. If zero, fail with a hint to run ssh-keygen.
select_ssh_key() {
    if [[ -n "${SSH_KEY_FILE:-}" ]]; then
        if [[ -f "$SSH_KEY_FILE" ]]; then
            echo "$SSH_KEY_FILE"
            return 0
        fi
        echo "ERROR: SSH_KEY_FILE=$SSH_KEY_FILE does not exist" >&2
        exit 1
    fi

    local keys=()
    shopt -s nullglob
    for key in "$HOME"/.ssh/*.pub; do
        [[ -f "$key" ]] && keys+=("$key")
    done
    shopt -u nullglob

    if [[ ${#keys[@]} -eq 0 ]]; then
        echo "ERROR: no SSH public keys found in ~/.ssh/*.pub" >&2
        echo "Generate one with:  ssh-keygen -t ed25519" >&2
        exit 1
    fi

    if [[ ${#keys[@]} -eq 1 ]]; then
        echo "Using SSH public key: ${keys[0]}" >&2
        echo "${keys[0]}"
        return 0
    fi

    # Multiple keys -- prompt interactively
    echo "Multiple SSH public keys found in ~/.ssh/:" >&2
    local i=1
    for key in "${keys[@]}"; do
        local comment
        comment=$(awk '{for (i=3; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":"")}' "$key" 2>/dev/null || echo "")
        printf "  %d) %s" "$i" "$key" >&2
        [[ -n "$comment" ]] && printf "  (%s)" "$comment" >&2
        printf "\n" >&2
        i=$((i + 1))
    done
    printf "\n" >&2
    local choice
    read -rp "Select a key [1-${#keys[@]}]: " choice </dev/tty
    if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#keys[@]} )); then
        echo "ERROR: invalid selection '$choice'" >&2
        exit 1
    fi
    echo "Using SSH public key: ${keys[$((choice - 1))]}" >&2
    echo "${keys[$((choice - 1))]}"
}

# --- .env loader + validation -------------------------------------------------
# Required vars for Phase 2. If any are unset in .env the script fails with a
# clear error listing which keys are missing.
REQUIRED_ENV_VARS=(
    XAI_API_KEY
    TELEGRAM_BOT_TOKEN
)
OPTIONAL_ENV_VARS=(
    OPENAI_API_KEY
    BRIGHTDATA_API_TOKEN
    TELEGRAM_USER_ID
)

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERROR: $ENV_FILE not found." >&2
        echo "Copy .env.template to .env and fill in your keys:" >&2
        echo "  cp .env.template .env" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    set -a
    source "$ENV_FILE"
    set +a

    local missing=()
    for var in "${REQUIRED_ENV_VARS[@]}"; do
        if [[ -z "${!var:-}" ]] || [[ "${!var}" == *your-*-here* ]]; then
            missing+=("$var")
        fi
    done
    if (( ${#missing[@]} > 0 )); then
        echo "ERROR: missing or placeholder values in $ENV_FILE for:" >&2
        printf "  %s\n" "${missing[@]}" >&2
        exit 1
    fi

    # Optional vars: ensure they're exported even if empty so envsubst sees them
    for var in "${OPTIONAL_ENV_VARS[@]}"; do
        export "$var=${!var:-}"
    done
}

# --- Derived Telegram config for openclaw.json --------------------------------
# If TELEGRAM_USER_ID is set, use allowlist mode with that ID.
# Otherwise open the bot to anyone.
compute_telegram_policy() {
    if [[ -n "${TELEGRAM_USER_ID:-}" ]]; then
        export TELEGRAM_DM_POLICY="allowlist"
        export TELEGRAM_ALLOW_FROM="\"${TELEGRAM_USER_ID}\""
    else
        export TELEGRAM_DM_POLICY="open"
        export TELEGRAM_ALLOW_FROM="\"*\""
    fi
}

# --- SOUL.md base64 encoding (optional) ---------------------------------------
load_soul_md() {
    if [[ -f "$SOUL_FILE" ]]; then
        echo "Including SOUL.md from $SOUL_FILE" >&2
        # base64 without line wraps (macOS base64 + tr pipe works on both macOS and Linux)
        export SOUL_MD_BASE64="$(base64 < "$SOUL_FILE" | tr -d '\n')"
    else
        echo "No SOUL.md found at $SOUL_FILE -- using minimal placeholder" >&2
        export SOUL_MD_BASE64="$(printf '# Agent soul not provided\n' | base64 | tr -d '\n')"
    fi
}

# --- Render cloud-init.yaml with substituted values ---------------------------
render_cloud_init() {
    local rendered
    rendered="$(mktemp -t openclaw-cloud-init.XXXXXX)"

    # Whitelist the variables envsubst should touch so unrelated ${VAR}
    # references in the YAML (if any ever appear) are left alone.
    envsubst '
        ${XAI_API_KEY}
        ${OPENAI_API_KEY}
        ${BRIGHTDATA_API_TOKEN}
        ${TELEGRAM_BOT_TOKEN}
        ${TELEGRAM_USER_ID}
        ${TELEGRAM_DM_POLICY}
        ${TELEGRAM_ALLOW_FROM}
        ${SOUL_MD_BASE64}
    ' < "$CLOUD_INIT" > "$rendered"

    echo "$rendered"
}

# --- Write .vm-state for the shell / other tools to source --------------------
write_vm_state() {
    local ip="$1"
    local vnc_pass="$2"
    cat > "$VM_STATE_FILE" <<EOF
# Runtime state for the currently deployed VM. Gitignored. Overwritten by deploy.sh.
IP=${ip}
VNC_URL=vnc://${ip}:5900
VNC_PASSWORD=${vnc_pass}
SSH="ssh ${ADMIN_USER}@${ip}"
RG=${RG}
VM_NAME=${VM_NAME}
LOCATION=${LOCATION}
VM_SIZE=${VM_SIZE}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    echo "Wrote $VM_STATE_FILE" >&2
}

# --- Preflight checks ---------------------------------------------------------
if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not found. Install with:  brew install gettext" >&2
    exit 1
fi
if [[ ! -f "$CLOUD_INIT" ]]; then
    echo "ERROR: cloud-init.yaml not found next to deploy.sh" >&2
    exit 1
fi

SSH_KEY_FILE=$(select_ssh_key)
load_env
compute_telegram_policy
load_soul_md

RENDERED_CLOUD_INIT=$(render_cloud_init)
trap 'rm -f "$RENDERED_CLOUD_INIT"' EXIT

echo "Creating resource group $RG in $LOCATION..."
az group create --name "$RG" --location "$LOCATION" --output none

echo "Creating VM $VM_NAME ($VM_SIZE)..."
az vm create \
    --resource-group "$RG" \
    --name "$VM_NAME" \
    --image Canonical:ubuntu-24_04-lts:server:latest \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_KEY_FILE" \
    --custom-data "$RENDERED_CLOUD_INIT" \
    --public-ip-sku Standard \
    --output none

echo "Opening NSG wide open (all protocols, all ports, all sources)..."
az vm open-port --resource-group "$RG" --name "$VM_NAME" --port '*' --priority 100 --output none

IP=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)

# Wait briefly for SSH so we can fetch the VNC password cloud-init generates on
# first boot. cloud-init's package install phase takes several minutes, so the
# password file may not exist yet -- we retry a few times and degrade to
# "retrieve manually later" if it's not ready.
echo "Waiting for SSH + VNC password..."
VNC_PASS=""
for i in $(seq 1 30); do
    if ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o BatchMode=yes -o ConnectTimeout=5 \
        "${ADMIN_USER}@${IP}" "test -f ~/vnc-password.txt" 2>/dev/null; then
        VNC_PASS=$(ssh -i ~/.ssh/id_ed25519 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            -o BatchMode=yes "${ADMIN_USER}@${IP}" "cat ~/vnc-password.txt" 2>/dev/null || echo "")
        if [[ -n "$VNC_PASS" ]]; then
            break
        fi
    fi
    sleep 5
done
if [[ -z "$VNC_PASS" ]]; then
    VNC_PASS="<not-ready-yet:  ssh ${ADMIN_USER}@${IP} 'cat ~/vnc-password.txt'>"
fi

write_vm_state "$IP" "$VNC_PASS"

cat <<EOF

[OK] VM deployed at $IP

Phase 2 install (openclaw + chrome + telegram + autostart gateway) is running
in the background. cloud-init typically takes 5-10 min the first time. Watch:
  ssh ${ADMIN_USER}@${IP} 'sudo cloud-init status --wait'

When cloud-init reports 'done', message your Telegram bot and the agent
should respond. No further setup needed.

Connection info (also written to .vm-state):
  VNC:  vnc://${IP}:5900
  VNC password:  ${VNC_PASS}
  SSH:  ssh ${ADMIN_USER}@${IP}

Daily lifecycle (disk and IP persist across stop/start):
  Stop (billing off):  az vm deallocate -g $RG -n $VM_NAME
  Start (billing on):  az vm start      -g $RG -n $VM_NAME

To destroy everything permanently:
  az group delete --name $RG --yes --no-wait
EOF
