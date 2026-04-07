#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw Azure VM Deployment
# ============================================================================
#
# ./deploy.sh            Deploy (creates data disk if needed, or reuses it)
# ./deploy.sh --update   Rebuild VM with fresh OS, keep data disk
# ./deploy.sh --destroy  Delete everything including data
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
DATA_DISK_NAME="disk-openclaw-data"
DATA_DISK_SIZE=64                     # GB, Premium SSD
NSG_NAME="nsg-openclaw"
VNET_NAME="vnet-openclaw"
SUBNET_NAME="subnet-openclaw"
PUBLIC_IP_NAME="ip-openclaw"
NIC_NAME="nic-openclaw"
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${1:-deploy}"

# --- Handle --destroy --------------------------------------------------------
if [[ "$ACTION" == "--destroy" ]]; then
    echo "Destroying everything (VM + data disk)..."
    az group delete --name "$RESOURCE_GROUP" --yes 2>/dev/null && echo "Done." || echo "Nothing to destroy."
    exit 0
fi

# --- Handle --update ---------------------------------------------------------
if [[ "$ACTION" == "--update" ]]; then
    echo "Updating: destroying VM but keeping data disk..."

    # Detach data disk from VM first
    az vm disk detach \
        --resource-group "$RESOURCE_GROUP" \
        --vm-name "$VM_NAME" \
        --name "$DATA_DISK_NAME" \
        --output none 2>/dev/null || true

    # Delete VM and its OS disk
    az vm delete \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VM_NAME" \
        --yes \
        --force-deletion none \
        --output none 2>/dev/null || true

    # Delete the old OS disk
    OS_DISKS=$(az disk list --resource-group "$RESOURCE_GROUP" \
        --query "[?name!='${DATA_DISK_NAME}'].name" --output tsv 2>/dev/null)
    for disk in $OS_DISKS; do
        az disk delete --resource-group "$RESOURCE_GROUP" --name "$disk" --yes --output none 2>/dev/null || true
    done

    # Delete NIC (will be recreated)
    az network nic delete \
        --resource-group "$RESOURCE_GROUP" \
        --name "$NIC_NAME" \
        --output none 2>/dev/null || true

    echo "VM destroyed. Data disk preserved. Redeploying..."
    echo ""
    # Fall through to deploy
fi

# --- Validate prerequisites --------------------------------------------------

if ! command -v az &>/dev/null; then
    echo "ERROR: Azure CLI (az) not found."
    echo "       Install: https://aka.ms/installazurecli"
    echo "       Then run: az login"
    exit 1
fi
if ! az account show &>/dev/null; then
    echo "ERROR: Not logged into Azure CLI. Run: az login"
    exit 1
fi
echo "[OK] Azure CLI authenticated"

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

TELEGRAM_ID_FILE="${SCRIPT_DIR}/telegram-userid.txt"
if [[ ! -f "$TELEGRAM_ID_FILE" ]]; then
    echo "ERROR: telegram-userid.txt not found"
    echo "       Create it: echo 'your-numeric-user-id' > telegram-userid.txt"
    echo ""
    echo "       To get your Telegram user ID:"
    echo "         1. Open Telegram and message @userinfobot"
    echo "         2. It replies with your numeric ID (e.g. 123456789)"
    echo "         3. Copy that number into telegram-userid.txt"
    exit 1
fi
TELEGRAM_USER_ID="$(tr -d '[:space:]' < "$TELEGRAM_ID_FILE")"
if [[ -z "$TELEGRAM_USER_ID" ]]; then
    echo "ERROR: telegram-userid.txt is empty"
    exit 1
fi
if ! [[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]]; then
    echo "ERROR: telegram-userid.txt must contain a numeric ID (e.g. 123456789)"
    echo "       Got: ${TELEGRAM_USER_ID}"
    echo "       Message @userinfobot on Telegram to get your ID."
    exit 1
fi
echo "[OK] Telegram user ID: ${TELEGRAM_USER_ID}"

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

RDP_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)Aa1!"

CLOUD_INIT_RENDERED="$(mktemp)"
trap 'rm -f "$CLOUD_INIT_RENDERED"' EXIT

sed \
    -e "s|__XAI_API_KEY__|${XAI_API_KEY}|g" \
    -e "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g" \
    -e "s|__TELEGRAM_USER_ID__|${TELEGRAM_USER_ID}|g" \
    -e "s|__RDP_PASSWORD__|${RDP_PASSWORD}|g" \
    "$CLOUD_INIT_TEMPLATE" > "$CLOUD_INIT_RENDERED"

echo "[OK] Cloud-init prepared"

# --- Check for existing data disk -------------------------------------------

DATA_DISK_EXISTS=false
if az disk show --resource-group "$RESOURCE_GROUP" --name "$DATA_DISK_NAME" &>/dev/null; then
    DATA_DISK_EXISTS=true
    echo "[OK] Existing data disk found (data will be preserved)"
fi

# --- Provision Azure infrastructure -----------------------------------------

MODE="Fresh deploy"
if [[ "$DATA_DISK_EXISTS" == true ]]; then
    MODE="Update (preserving data)"
fi

echo ""
echo "=========================================="
echo " Deploying OpenClaw VM"
echo "=========================================="
echo " Mode:       ${MODE}"
echo " VM Size:    ${VM_SIZE} (8 vCPUs, 64 GiB RAM)"
echo " Region:     ${LOCATION}"
echo " OS:         Ubuntu 24.04 LTS + XFCE Desktop"
echo "=========================================="
echo ""

# Resource group (idempotent)
echo "[1/8] Creating resource group..."
az group create \
    --name "$RESOURCE_GROUP" \
    --location "$LOCATION" \
    --output none

# Virtual network (skip if exists)
if ! az network vnet show --resource-group "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then
    echo "[2/8] Creating virtual network..."
    az network vnet create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$VNET_NAME" \
        --address-prefix "10.0.0.0/16" \
        --subnet-name "$SUBNET_NAME" \
        --subnet-prefix "10.0.0.0/24" \
        --output none
else
    echo "[2/8] Virtual network exists"
fi

# NSG (skip if exists)
if ! az network nsg show --resource-group "$RESOURCE_GROUP" --name "$NSG_NAME" &>/dev/null; then
    echo "[3/8] Creating NSG (all ports open)..."
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
else
    echo "[3/8] NSG exists"
fi

# Public IP (skip if exists)
if ! az network public-ip show --resource-group "$RESOURCE_GROUP" --name "$PUBLIC_IP_NAME" &>/dev/null; then
    echo "[4/8] Creating static public IP..."
    az network public-ip create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$PUBLIC_IP_NAME" \
        --sku Standard \
        --allocation-method Static \
        --output none
else
    echo "[4/8] Public IP exists"
fi

# Data disk (create only if fresh deploy)
if [[ "$DATA_DISK_EXISTS" == false ]]; then
    echo "[5/8] Creating data disk (${DATA_DISK_SIZE} GB)..."
    az disk create \
        --resource-group "$RESOURCE_GROUP" \
        --name "$DATA_DISK_NAME" \
        --size-gb "$DATA_DISK_SIZE" \
        --sku Premium_LRS \
        --zone 3 \
        --output none
else
    echo "[5/8] Data disk exists"
fi

# NIC
echo "[6/8] Creating network interface..."
az network nic create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --network-security-group "$NSG_NAME" \
    --public-ip-address "$PUBLIC_IP_NAME" \
    --output none 2>/dev/null || true

# VM
echo "[7/8] Creating VM (this takes a few minutes)..."
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
    --attach-data-disks "$DATA_DISK_NAME" \
    --custom-data "$CLOUD_INIT_RENDERED" \
    --zone 3 \
    --output none

echo "[8/8] Retrieving public IP..."
PUBLIC_IP=$(az network public-ip show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --query ipAddress \
    --output tsv)

# --- Wait for cloud-init ----------------------------------------------------

echo ""
echo "VM created at ${PUBLIC_IP}. Waiting for software installation (~5-10 min)..."
echo ""

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"
SSH_KEY="$(echo "$SSH_KEY_FILE" | sed 's/\.pub$//')"

for i in $(seq 1 30); do
    if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${ADMIN_USER}@${PUBLIC_IP}" "true" 2>/dev/null; then
        break
    fi
    sleep 10
done

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
    if mount | grep -q '/data'; then
        echo \"  Data disk:        mounted at /data\"
    else
        echo \"  Data disk:        NOT MOUNTED (check logs)\"
    fi
    IMDS=\$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 -H 'Metadata: true' 'http://169.254.169.254/metadata/instance?api-version=2023-07-01' 2>/dev/null || echo 'blocked')
    if [[ \"\$IMDS\" == '000' || \"\$IMDS\" == 'blocked' ]]; then
        echo \"  Azure IMDS:       blocked (agent can't touch Azure)\"
    else
        echo \"  Azure IMDS:       REACHABLE (firewall rule may have failed)\"
    fi
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
echo " Telegram:"
echo "   Send any message to your bot -- it responds immediately."
echo ""
echo " Dashboard (inside RDP):"
echo "   Double-click 'OpenClaw Dashboard' on the desktop."
echo ""
echo " Update (new OS, keep data):"
echo "   ./deploy.sh --update"
echo ""
echo " Destroy everything:"
echo "   ./deploy.sh --destroy"
echo ""
echo "=========================================="
