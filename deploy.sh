#!/usr/bin/env bash
# Deploy a simple Ubuntu 24.04 VM with xfce4 + lightdm auto-login + x11vnc on :0.
# Based on: https://learn.microsoft.com/en-us/azure/virtual-machines/linux/use-remote-desktop
# (substitutes x11vnc-on-:0 for xrdp so always-on workloads are observable across
#  viewer disconnect/reconnect.)

set -euo pipefail

RG="${RG:-rg-linux-desktop}"
LOCATION="${LOCATION:-eastus}"
VM_NAME="${VM_NAME:-linux-desktop}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v5}"
ADMIN_USER="${ADMIN_USER:-azureuser}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT="${SCRIPT_DIR}/cloud-init.yaml"

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

    # Multiple keys — prompt interactively
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

SSH_KEY_FILE=$(select_ssh_key)

if [[ ! -f "$CLOUD_INIT" ]]; then
    echo "ERROR: cloud-init.yaml not found next to deploy.sh" >&2
    exit 1
fi

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
    --custom-data "$CLOUD_INIT" \
    --public-ip-sku Standard \
    --output none

echo "Opening NSG wide open (all protocols, all ports, all sources)..."
az vm open-port --resource-group "$RG" --name "$VM_NAME" --port '*' --priority 100 --output none

IP=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)

cat <<EOF

[OK] VM deployed at $IP

Next steps:
  1. Wait ~5-10 min for cloud-init to finish installing xfce4 + lightdm + x11vnc.
     Watch progress:  ssh $ADMIN_USER@$IP 'sudo cloud-init status --wait'
  2. Retrieve the generated VNC password:
     ssh $ADMIN_USER@$IP 'cat ~/vnc-password.txt'
  3. Connect with a VNC client to port 5900:
     - macOS:  Finder > Go > Connect to Server > vnc://$IP:5900
     - Linux:  remmina or vncviewer vnc://$IP:5900
     - Windows: RealVNC Viewer, TightVNC, or similar
     Use the password from step 2.

You are connected to the persistent :0 session. Anything running there
stays running across your viewer disconnect/reconnect cycles.

Daily lifecycle (disk and IP persist across stop/start):
  Stop (billing off):  az vm deallocate -g $RG -n $VM_NAME
  Start (billing on):  az vm start      -g $RG -n $VM_NAME

To destroy everything permanently:
  az group delete --name $RG --yes --no-wait
EOF
