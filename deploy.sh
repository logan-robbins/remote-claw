#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw Azure VM Deployment
# ============================================================================
# One command to deploy. One command to destroy.
#
# Deploy:  ./deploy.sh
# Destroy: ./deploy.sh --destroy
#
# See README.md for setup instructions.
# ============================================================================

# --- Configuration -----------------------------------------------------------
RESOURCE_GROUP="rg-openclaw"
VM_NAME="openclaw-vm"
LOCATION="eastus"
VM_SIZE="Standard_E8s_v3"            # 8 vCPUs, 64 GiB RAM
IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
ADMIN_USER="azureuser"
OS_DISK_SIZE=256                      # GB, Premium SSD
NSG_NAME="nsg-openclaw"
VNET_NAME="vnet-openclaw"
SUBNET_NAME="subnet-openclaw"
PUBLIC_IP_NAME="ip-openclaw"
NIC_NAME="nic-openclaw"
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Handle --destroy --------------------------------------------------------
if [[ "${1:-}" == "--destroy" ]]; then
    echo "Destroying resource group ${RESOURCE_GROUP}..."
    az group delete --name "$RESOURCE_GROUP" --yes 2>/dev/null && echo "Done." || echo "Nothing to destroy."
    exit 0
fi

# --- Validate prerequisites --------------------------------------------------

# Azure CLI
if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI (az) not found."
    echo "       Install: https://aka.ms/installazurecli"
    echo "       Then run: az login"
    exit 1
fi
# Check if logged in
if ! az account show &>/dev/null; then
    echo "ERROR: Not logged into Azure CLI. Run: az login"
    exit 1
fi
echo "[OK] Azure CLI authenticated"

# xAI API key
XAI_KEY_FILE="${SCRIPT_DIR}/xai.txt"
if [[ ! -f "$XAI_KEY_FILE" ]]; then
    echo "ERROR: xai.txt not found"
    echo "       Create it: echo 'your-xai-api-key' > xai.txt"
    exit 1
fi
XAI_API_KEY="$(tr -d '[:space:]' < "$XAI_KEY_FILE")"
if [[ -z "$XAI_API_KEY" ]]; then
    echo "ERROR: xai.txt is empty"
    exit 1
fi
echo "[OK] xAI API key loaded"

# Telegram bot token
TELEGRAM_KEY_FILE="${SCRIPT_DIR}/telegram.txt"
if [[ ! -f "$TELEGRAM_KEY_FILE" ]]; then
    echo "ERROR: telegram.txt not found"
    echo "       Create it: echo 'your-bot-token' > telegram.txt"
    echo ""
    echo "       To get a bot token:"
    echo "         1. Open Telegram and message @BotFather"
    echo "         2. Send /newbot"
    echo "         3. Pick a name and username"
    echo "         4. Copy the token into telegram.txt"
    exit 1
fi
TELEGRAM_BOT_TOKEN="$(tr -d '[:space:]' < "$TELEGRAM_KEY_FILE")"
if [[ -z "$TELEGRAM_BOT_TOKEN" ]]; then
    echo "ERROR: telegram.txt is empty"
    exit 1
fi
echo "[OK] Telegram bot token loaded"

# SSH key (generate if missing)
SSH_KEY_FILE=""
for key in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
    if [[ -f "$key" ]]; then
        SSH_KEY_FILE="$key"
        break
    fi
done
if [[ -z "$SSH_KEY_FILE" ]]; then
    echo "No SSH key found. Generating one..."
    ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519" -N "" -q
    SSH_KEY_FILE="$HOME/.ssh/id_ed25519.pub"
fi
echo "[OK] SSH key: ${SSH_KEY_FILE}"

# --- Prepare cloud-init with injected secrets --------------------------------

CLOUD_INIT_TEMPLATE="${SCRIPT_DIR}/cloud-init.yaml"
if [[ ! -f "$CLOUD_INIT_TEMPLATE" ]]; then
    echo "ERROR: cloud-init.yaml not found in ${SCRIPT_DIR}"
    exit 1
fi

GATEWAY_TOKEN="$(openssl rand -hex 32)"
RDP_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)Aa1!"

CLOUD_INIT_RENDERED="$(mktemp)"
trap 'rm -f "$CLOUD_INIT_RENDERED"' EXIT

sed \
    -e "s|__XAI_API_KEY__|${XAI_API_KEY}|g" \
    -e "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g" \
    -e "s|__GATEWAY_TOKEN__|${GATEWAY_TOKEN}|g" \
    -e "s|__RDP_PASSWORD__|${RDP_PASSWORD}|g" \
    "$CLOUD_INIT_TEMPLATE" > "$CLOUD_INIT_RENDERED"

echo "[OK] Cloud-init prepared"

# --- Provision Azure infrastructure -----------------------------------------

echo ""
echo "=========================================="
echo " Deploying OpenClaw VM"
echo "=========================================="
echo " VM Size:    ${VM_SIZE} (8 vCPUs, 64 GiB RAM)"
echo " Region:     ${LOCATION}"
echo " OS:         Ubuntu 24.04 LTS + XFCE Desktop"
echo "=========================================="
echo ""

echo "[1/7] Creating resource group..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

echo "[2/7] Creating virtual network..."
az network vnet create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VNET_NAME" \
    --address-prefix "10.0.0.0/16" \
    --subnet-name "$SUBNET_NAME" \
    --subnet-prefix "10.0.0.0/24" \
    --output none

echo "[3/7] Creating NSG (all ports open)..."
az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --output none

az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "AllowAllInbound" \
    --priority 100 \
    --direction Inbound \
    --access Allow \
    --protocol '*' \
    --source-address-prefixes '*' \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --output none

az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "AllowAllOutbound" \
    --priority 100 \
    --direction Outbound \
    --access Allow \
    --protocol '*' \
    --source-address-prefixes '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges '*' \
    --output none

echo "[4/7] Creating static public IP..."
az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --sku Standard \
    --allocation-method Static \
    --output none

echo "[5/7] Creating network interface..."
az network nic create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --public-ip-address "$PUBLIC_IP_NAME" \
    --output none

echo "[6/7] Creating VM (this takes a few minutes)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --nics "$NIC_NAME" \
    --image "$IMAGE" \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USER" \
    --ssh-key-values "$SSH_KEY_FILE" \
    --os-disk-size-gb "$OS_DISK_SIZE" \
    --storage-sku Premium_LRS \
    --custom-data "$CLOUD_INIT_RENDERED" \
    --zone 3 \
    --output none

echo "[7/7] Retrieving public IP..."
PUBLIC_IP=$(az network public-ip show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --query ipAddress \
    --output tsv)

# --- Wait for cloud-init ----------------------------------------------------

echo ""
echo "VM created at ${PUBLIC_IP}. Waiting for software installation (~5-10 min)..."
echo ""

# Auto-accept SSH host key and wait for cloud-init
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_KEY="$(echo "$SSH_KEY_FILE" | sed 's/\.pub$//')"

# Wait for SSH to become available
for i in $(seq 1 30); do
    if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${ADMIN_USER}@${PUBLIC_IP}" "true" 2>/dev/null; then
        break
    fi
    sleep 10
done

# Wait for cloud-init to finish
ssh $SSH_OPTS -i "$SSH_KEY" -o ServerAliveInterval=15 "${ADMIN_USER}@${PUBLIC_IP}" \
    "sudo cloud-init status --wait" 2>/dev/null || true

# Verify services
echo ""
echo "Verifying services..."
VERIFY=$(ssh $SSH_OPTS -i "$SSH_KEY" "${ADMIN_USER}@${PUBLIC_IP}" "
    OC=\$(sudo systemctl is-active openclaw-gateway 2>/dev/null || echo 'inactive')
    XRDP=\$(sudo systemctl is-active xrdp 2>/dev/null || echo 'inactive')
    XVFB=\$(sudo systemctl is-active xvfb 2>/dev/null || echo 'inactive')
    echo \"  OpenClaw Gateway: \$OC\"
    echo \"  xrdp (desktop):   \$XRDP\"
    echo \"  Xvfb (display):   \$XVFB\"
" 2>/dev/null)
echo "$VERIFY"

# --- Done --------------------------------------------------------------------

echo ""
echo "=========================================="
echo " Ready!"
echo "=========================================="
echo ""
echo " Connect via Remote Desktop (RDP):"
echo "   Host:     ${PUBLIC_IP}:3389"
echo "   Username: ${ADMIN_USER}"
echo "   Password: ${RDP_PASSWORD}"
echo ""
echo " Pair Telegram:"
echo "   1. Send any message to your bot in Telegram"
echo "   2. The pairing code will appear in the desktop terminal:"
echo "      sudo journalctl -u openclaw-gateway -f"
echo ""
echo " Destroy when done:"
echo "   ./deploy.sh --destroy"
echo ""
echo "=========================================="
