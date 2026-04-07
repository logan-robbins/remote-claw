#!/usr/bin/env bash
set -euo pipefail

# ============================================================================
# OpenClaw Multi-Claw Deployment
# ============================================================================
#
# Claw-scoped commands (name REQUIRED as first positional arg):
#   ./deploy.sh research                   Create new claw "research"
#   ./deploy.sh research --update          Rebuild VM, keep data disk
#   ./deploy.sh research --fresh           Rebuild VM + wipe data disk
#   ./deploy.sh research --destroy         Delete claw entirely
#   ./deploy.sh research --image 1.0.2     Pin to specific image version
#
# No-claw commands:
#   ./deploy.sh                            Show help + existing claws
#   ./deploy.sh list                       List all claws (name, status, IP)
#   ./deploy.sh images                     List image versions in the gallery
#   ./deploy.sh --bake                     Bake new image version
#   ./deploy.sh --destroy-all              Delete entire resource group
#
# See README.md for setup instructions.
# ============================================================================

# --- Configuration -----------------------------------------------------------
RESOURCE_GROUP="rg-openclaw"
LOCATION="eastus"
VM_SIZE="Standard_E8s_v3"             # 8 vCPUs, 64 GiB RAM
STOCK_UBUNTU_IMAGE="Canonical:ubuntu-24_04-lts:server:latest"
ADMIN_USER="azureuser"
OS_DISK_SIZE=256                       # GB, Premium SSD
DATA_DISK_SIZE=64                      # GB, Premium SSD (per-claw)

# Shared networking
VNET_NAME="vnet-openclaw"
VNET_CIDR="10.0.0.0/16"
NSG_NAME="nsg-openclaw"

# Compute Gallery (gallery names allow alphanumerics and periods; no dashes)
GALLERY_NAME="openclawgallery"
IMAGE_DEFINITION="openclaw"
IMAGE_PUBLISHER="remoteclaw"
IMAGE_OFFER="openclaw-ubuntu-2404"
IMAGE_SKU="base"
KEEP_IMAGE_VERSIONS=3

# Bake VM (temporary, only during --bake)
BAKE_VM_NAME="openclaw-bake-vm"
BAKE_OS_DISK_SIZE=64                   # smaller disk = faster bake
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLOUD_INIT_BAKE="${SCRIPT_DIR}/cloud-init-bake.yaml"
RUNTIME_INIT_TEMPLATE="${SCRIPT_DIR}/runtime-init.sh"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR"

# --- Argument parsing --------------------------------------------------------

CLAW_NAME=""
SUBCOMMAND=""
UPDATE=false
FRESH=false
DESTROY=false
BAKE_ONLY=false
DESTROY_ALL=false
PINNED_IMAGE=""

show_help() {
    cat <<'EOF'
OpenClaw Multi-Claw Deployment

Claw operations (claw name required):
  ./deploy.sh <name>                  Create new claw
  ./deploy.sh <name> --update         Rebuild VM, keep data disk
  ./deploy.sh <name> --fresh          Rebuild VM + wipe data disk
  ./deploy.sh <name> --destroy        Delete claw entirely
  ./deploy.sh <name> --image 1.0.2    Pin to specific image version

Gallery / info:
  ./deploy.sh list                    List all claws
  ./deploy.sh images                  List image versions
  ./deploy.sh --bake                  Bake new image version

Nuclear:
  ./deploy.sh --destroy-all           Delete entire resource group

Claw names: lowercase, 1-20 chars, alphanumeric + hyphens, must start with letter/digit.
EOF
}

# Look at first positional arg
case "${1:-}" in
    "")
        show_help
        echo ""
        echo "Existing claws:"
        if command -v az &>/dev/null && az account show &>/dev/null; then
            az vm list -g "$RESOURCE_GROUP" --query "[?starts_with(name, 'claw-')].name" -o tsv 2>/dev/null | sed 's/^claw-/  /; s/-vm$//' || echo "  (none)"
        else
            echo "  (run 'az login' first)"
        fi
        exit 0
        ;;
    list)
        SUBCOMMAND="list"
        ;;
    images)
        SUBCOMMAND="images"
        ;;
    --bake)
        BAKE_ONLY=true
        ;;
    --destroy-all)
        DESTROY_ALL=true
        ;;
    --help|-h)
        show_help
        exit 0
        ;;
    -*)
        echo "ERROR: unknown flag '$1'. First argument must be a claw name or subcommand."
        show_help
        exit 1
        ;;
    *)
        CLAW_NAME="$1"
        shift
        # Parse remaining flags
        while (( $# > 0 )); do
            case "$1" in
                --update)   UPDATE=true ;;
                --fresh)    FRESH=true ;;
                --destroy)  DESTROY=true ;;
                --image)
                    shift
                    PINNED_IMAGE="${1:-}"
                    [[ -z "$PINNED_IMAGE" ]] && { echo "ERROR: --image requires a version argument (e.g. 1.0.2)"; exit 1; }
                    ;;
                *)
                    echo "ERROR: unknown flag '$1'"
                    show_help
                    exit 1
                    ;;
            esac
            shift
        done

        # Validate claw name
        if ! [[ "$CLAW_NAME" =~ ^[a-z0-9][a-z0-9-]{0,19}$ ]]; then
            echo "ERROR: invalid claw name '$CLAW_NAME'"
            echo "       Must be 1-20 chars, lowercase, alphanumeric + hyphens, start with letter/digit."
            exit 1
        fi
        ;;
esac

# --- Helpers: validation + prereqs ------------------------------------------

validate_prereqs() {
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
}

validate_secrets() {
    # xAI key
    local xai_file="${SCRIPT_DIR}/xai.txt"
    if [[ ! -f "$xai_file" ]]; then
        echo "ERROR: xai.txt not found"
        echo "       Create it: echo 'your-xai-api-key' > xai.txt"
        exit 1
    fi
    XAI_API_KEY="$(tr -d '[:space:]' < "$xai_file")"
    [[ -z "$XAI_API_KEY" ]] && { echo "ERROR: xai.txt is empty"; exit 1; }
    echo "[OK] xAI API key loaded"

    # Telegram bot token
    local tg_file="${SCRIPT_DIR}/telegram.txt"
    if [[ ! -f "$tg_file" ]]; then
        echo "ERROR: telegram.txt not found"
        echo "       Create it: echo 'your-bot-token' > telegram.txt"
        echo ""
        echo "       To get a bot token: message @BotFather, send /newbot"
        exit 1
    fi
    TELEGRAM_BOT_TOKEN="$(tr -d '[:space:]' < "$tg_file")"
    [[ -z "$TELEGRAM_BOT_TOKEN" ]] && { echo "ERROR: telegram.txt is empty"; exit 1; }
    echo "[OK] Telegram bot token loaded"

    # Telegram user ID (optional)
    local tgid_file="${SCRIPT_DIR}/telegram-userid.txt"
    if [[ -f "$tgid_file" ]]; then
        local uid
        uid="$(tr -d '[:space:]' < "$tgid_file")"
        if [[ -z "$uid" ]]; then
            echo "ERROR: telegram-userid.txt is empty (delete the file to skip the allowlist)"
            exit 1
        fi
        if ! [[ "$uid" =~ ^[0-9]+$ ]]; then
            echo "ERROR: telegram-userid.txt must contain a numeric ID (got: $uid)"
            exit 1
        fi
        TELEGRAM_DM_POLICY="allowlist"
        TELEGRAM_ALLOW_FROM="\"${uid}\""
        echo "[OK] Telegram user ID: ${uid} (allowlist mode)"
    else
        TELEGRAM_DM_POLICY="open"
        TELEGRAM_ALLOW_FROM="\"*\""
        echo "[OK] Telegram: open policy (no telegram-userid.txt found)"
    fi
}

validate_ssh_key() {
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
    SSH_KEY="${SSH_KEY_FILE%.pub}"
    echo "[OK] SSH key: ${SSH_KEY_FILE}"
}

# --- Helpers: resource group + networking -----------------------------------

ensure_resource_group() {
    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        echo "Creating resource group ${RESOURCE_GROUP}..."
        az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none
    fi
}

ensure_shared_networking() {
    # Shared vnet
    if ! az network vnet show -g "$RESOURCE_GROUP" --name "$VNET_NAME" &>/dev/null; then
        echo "Creating shared vnet ${VNET_NAME}..."
        az network vnet create \
            -g "$RESOURCE_GROUP" \
            --name "$VNET_NAME" \
            --address-prefix "$VNET_CIDR" \
            --output none
    fi

    # Shared NSG (open firewall)
    if ! az network nsg show -g "$RESOURCE_GROUP" --name "$NSG_NAME" &>/dev/null; then
        echo "Creating shared NSG ${NSG_NAME} (all ports open)..."
        az network nsg create -g "$RESOURCE_GROUP" --name "$NSG_NAME" --output none

        az network nsg rule create \
            -g "$RESOURCE_GROUP" \
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
            -g "$RESOURCE_GROUP" \
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
    fi
}

# --- Helpers: compute gallery + image management ----------------------------

ensure_gallery() {
    if ! az sig show -g "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" &>/dev/null; then
        echo "Creating compute gallery ${GALLERY_NAME}..."
        az sig create -g "$RESOURCE_GROUP" --gallery-name "$GALLERY_NAME" --output none
    fi
}

ensure_image_definition() {
    if ! az sig image-definition show \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" &>/dev/null; then
        echo "Creating image definition ${IMAGE_DEFINITION}..."
        az sig image-definition create \
            -g "$RESOURCE_GROUP" \
            --gallery-name "$GALLERY_NAME" \
            --gallery-image-definition "$IMAGE_DEFINITION" \
            --publisher "$IMAGE_PUBLISHER" \
            --offer "$IMAGE_OFFER" \
            --sku "$IMAGE_SKU" \
            --os-type Linux \
            --os-state specialized \
            --hyper-v-generation V2 \
            --features SecurityType=TrustedLaunch \
            --output none
    fi
}

next_version() {
    local latest
    latest=$(az sig image-version list \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --query "[].name" -o tsv 2>/dev/null | sort -V | tail -1)
    if [[ -z "$latest" ]]; then
        echo "1.0.0"
    else
        IFS='.' read -r maj min pat <<< "$latest"
        echo "${maj}.${min}.$((pat + 1))"
    fi
}

latest_image_id() {
    local sub latest
    sub=$(az account show --query id -o tsv)
    latest=$(az sig image-version list \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --query "[].name" -o tsv 2>/dev/null | sort -V | tail -1)
    [[ -z "$latest" ]] && return 0
    echo "/subscriptions/${sub}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY_NAME}/images/${IMAGE_DEFINITION}/versions/${latest}"
}

image_id_for_version() {
    local version="$1" sub
    sub=$(az account show --query id -o tsv)
    # Verify the version exists
    if ! az sig image-version show \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --gallery-image-version "$version" &>/dev/null; then
        echo "ERROR: image version '$version' not found in gallery" >&2
        echo "       Run './deploy.sh images' to see available versions." >&2
        exit 1
    fi
    echo "/subscriptions/${sub}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY_NAME}/images/${IMAGE_DEFINITION}/versions/${version}"
}

cleanup_old_versions() {
    local versions count
    versions=$(az sig image-version list \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --query "[].name" -o tsv 2>/dev/null | sort -V)
    [[ -z "$versions" ]] && return 0
    count=$(printf '%s\n' "$versions" | wc -l | tr -d ' ')
    if (( count > KEEP_IMAGE_VERSIONS )); then
        local to_delete
        to_delete=$(printf '%s\n' "$versions" | head -n $((count - KEEP_IMAGE_VERSIONS)))
        for v in $to_delete; do
            echo "Deleting old image version: $v"
            az sig image-version delete \
                -g "$RESOURCE_GROUP" \
                --gallery-name "$GALLERY_NAME" \
                --gallery-image-definition "$IMAGE_DEFINITION" \
                --gallery-image-version "$v" \
                --output none
        done
    fi
}

bake_image() {
    echo ""
    echo "=========================================="
    echo " Baking new OpenClaw image"
    echo "=========================================="

    ensure_gallery
    ensure_image_definition
    local new_version
    new_version=$(next_version)
    echo "Version: $new_version"
    echo ""

    # Make sure no leftover bake VM exists
    az vm delete -g "$RESOURCE_GROUP" --name "$BAKE_VM_NAME" --yes --output none 2>/dev/null || true
    az network nic delete -g "$RESOURCE_GROUP" --name "${BAKE_VM_NAME}VMNic" --output none 2>/dev/null || true
    az network public-ip delete -g "$RESOURCE_GROUP" --name "${BAKE_VM_NAME}PublicIP" --output none 2>/dev/null || true

    echo "Creating temporary bake VM (stock Ubuntu + cloud-init-bake.yaml)..."
    az vm create \
        -g "$RESOURCE_GROUP" \
        --name "$BAKE_VM_NAME" \
        --image "$STOCK_UBUNTU_IMAGE" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --ssh-key-values "$SSH_KEY_FILE" \
        --os-disk-size-gb "$BAKE_OS_DISK_SIZE" \
        --storage-sku Premium_LRS \
        --custom-data "$CLOUD_INIT_BAKE" \
        --zone 3 \
        --public-ip-sku Standard \
        --nsg "$NSG_NAME" \
        --output none

    local bake_ip
    bake_ip=$(az vm show -g "$RESOURCE_GROUP" --name "$BAKE_VM_NAME" -d --query publicIps -o tsv)
    echo "Bake VM: $bake_ip"
    echo ""
    echo "Waiting for software installation (~8-10 min)..."

    # Wait for SSH (up to 3 minutes — VM boot is fast, but custom-data agent may take a moment)
    local ssh_ready=false
    for i in $(seq 1 36); do
        if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${ADMIN_USER}@${bake_ip}" "true" 2>/dev/null; then
            ssh_ready=true
            break
        fi
        sleep 5
    done
    if [[ "$ssh_ready" != true ]]; then
        echo "ERROR: bake VM didn't accept SSH within 3 minutes"
        exit 1
    fi

    # Wait for cloud-init to finish
    ssh $SSH_OPTS -i "$SSH_KEY" -o ServerAliveInterval=30 "${ADMIN_USER}@${bake_ip}" \
        "sudo cloud-init status --wait" || true

    # Sanity checks
    echo ""
    echo "Verifying bake..."
    if ! ssh $SSH_OPTS -i "$SSH_KEY" "${ADMIN_USER}@${bake_ip}" \
        "which openclaw && which google-chrome-stable && test -x /opt/Telegram/Telegram && echo BAKE_OK" \
        | grep -q BAKE_OK; then
        echo "ERROR: bake verification failed. Check the bake VM at $bake_ip"
        echo "       SSH: ssh ${ADMIN_USER}@${bake_ip}"
        echo "       Logs: sudo cat /var/log/openclaw-bake.log"
        exit 1
    fi
    echo "[OK] openclaw, google-chrome, telegram all present"

    # Deallocate, then capture (specialized — no generalize, no deprovision)
    echo ""
    echo "Deallocating bake VM..."
    az vm deallocate -g "$RESOURCE_GROUP" --name "$BAKE_VM_NAME" --output none

    echo "Capturing image version $new_version..."
    local bake_vm_id
    bake_vm_id=$(az vm show -g "$RESOURCE_GROUP" --name "$BAKE_VM_NAME" --query id -o tsv)
    # For specialized images, use --virtual-machine (not --managed-image)
    az sig image-version create \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --gallery-image-version "$new_version" \
        --virtual-machine "$bake_vm_id" \
        --output none

    echo "Cleaning up bake VM..."
    az vm delete -g "$RESOURCE_GROUP" --name "$BAKE_VM_NAME" --yes --output none
    az network nic delete -g "$RESOURCE_GROUP" --name "${BAKE_VM_NAME}VMNic" --output none 2>/dev/null || true
    az network public-ip delete -g "$RESOURCE_GROUP" --name "${BAKE_VM_NAME}PublicIP" --output none 2>/dev/null || true
    # Delete any leftover OS disks from the bake VM
    local bake_disks
    bake_disks=$(az disk list -g "$RESOURCE_GROUP" --query "[?starts_with(name, '${BAKE_VM_NAME}')].name" -o tsv 2>/dev/null || true)
    for disk in $bake_disks; do
        az disk delete -g "$RESOURCE_GROUP" --name "$disk" --yes --output none 2>/dev/null || true
    done

    cleanup_old_versions
    echo ""
    echo "[OK] Baked image version $new_version"
    echo ""
}

# --- Helpers: per-claw operations -------------------------------------------

claw_vm_name()   { echo "claw-${1}-vm"; }
claw_data_name() { echo "claw-${1}-data"; }
claw_nic_name()  { echo "claw-${1}-nic"; }
claw_ip_name()   { echo "claw-${1}-ip"; }
claw_subnet_name() { echo "claw-${1}-subnet"; }

claw_exists() {
    az vm show -g "$RESOURCE_GROUP" --name "$(claw_vm_name "$1")" &>/dev/null
}

next_subnet_cidr() {
    # Count existing subnets in the vnet, use next /24 slot
    local used
    used=$(az network vnet subnet list -g "$RESOURCE_GROUP" --vnet-name "$VNET_NAME" \
        --query "[].addressPrefix" -o tsv 2>/dev/null | \
        grep -oE '10\.0\.[0-9]+\.0/24' | \
        sed -E 's|10\.0\.([0-9]+)\.0/24|\1|' | sort -n)
    local next=0
    for n in $used; do
        if (( n == next )); then
            next=$((next + 1))
        fi
    done
    echo "10.0.${next}.0/24"
}

ensure_claw_subnet() {
    local claw="$1"
    local subnet_name
    subnet_name=$(claw_subnet_name "$claw")
    if ! az network vnet subnet show \
        -g "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$subnet_name" &>/dev/null; then
        local cidr
        cidr=$(next_subnet_cidr)
        echo "Creating subnet ${subnet_name} (${cidr})..."
        az network vnet subnet create \
            -g "$RESOURCE_GROUP" \
            --vnet-name "$VNET_NAME" \
            --name "$subnet_name" \
            --address-prefix "$cidr" \
            --network-security-group "$NSG_NAME" \
            --output none
    fi
}

ensure_claw_public_ip() {
    local claw="$1"
    local ip_name
    ip_name=$(claw_ip_name "$claw")
    if ! az network public-ip show -g "$RESOURCE_GROUP" --name "$ip_name" &>/dev/null; then
        echo "Creating public IP ${ip_name}..."
        az network public-ip create \
            -g "$RESOURCE_GROUP" \
            --name "$ip_name" \
            --sku Standard \
            --allocation-method Static \
            --output none
    fi
}

ensure_claw_nic() {
    local claw="$1"
    local nic_name subnet_name ip_name
    nic_name=$(claw_nic_name "$claw")
    subnet_name=$(claw_subnet_name "$claw")
    ip_name=$(claw_ip_name "$claw")
    if ! az network nic show -g "$RESOURCE_GROUP" --name "$nic_name" &>/dev/null; then
        echo "Creating NIC ${nic_name}..."
        az network nic create \
            -g "$RESOURCE_GROUP" \
            --name "$nic_name" \
            --vnet-name "$VNET_NAME" \
            --subnet "$subnet_name" \
            --network-security-group "$NSG_NAME" \
            --public-ip-address "$ip_name" \
            --output none
    fi
}

ensure_claw_data_disk() {
    local claw="$1"
    local disk_name
    disk_name=$(claw_data_name "$claw")
    if ! az disk show -g "$RESOURCE_GROUP" --name "$disk_name" &>/dev/null; then
        echo "Creating data disk ${disk_name} (${DATA_DISK_SIZE} GB)..."
        az disk create \
            -g "$RESOURCE_GROUP" \
            --name "$disk_name" \
            --size-gb "$DATA_DISK_SIZE" \
            --sku Premium_LRS \
            --zone 3 \
            --output none
    fi
}

destroy_vm_only() {
    # Delete VM + OS disk + NIC + public IP, preserve data disk
    local claw="$1"
    local vm data_disk nic ip
    vm=$(claw_vm_name "$claw")
    data_disk=$(claw_data_name "$claw")
    nic=$(claw_nic_name "$claw")
    ip=$(claw_ip_name "$claw")

    echo "Destroying VM for claw '$claw' (keeping data disk)..."

    # Detach data disk first so it doesn't get deleted with the VM
    az vm disk detach \
        -g "$RESOURCE_GROUP" \
        --vm-name "$vm" \
        --name "$data_disk" \
        --output none 2>/dev/null || true

    az vm delete -g "$RESOURCE_GROUP" --name "$vm" --yes --output none 2>/dev/null || true

    # Delete orphaned OS disks from this claw's VM
    local os_disks
    os_disks=$(az disk list -g "$RESOURCE_GROUP" \
        --query "[?starts_with(name, '${vm}_OsDisk') || starts_with(name, '${vm}_disk')].name" \
        -o tsv 2>/dev/null || true)
    for d in $os_disks; do
        az disk delete -g "$RESOURCE_GROUP" --name "$d" --yes --output none 2>/dev/null || true
    done

    az network nic delete -g "$RESOURCE_GROUP" --name "$nic" --output none 2>/dev/null || true
    az network public-ip delete -g "$RESOURCE_GROUP" --name "$ip" --output none 2>/dev/null || true
}

destroy_claw() {
    # Delete everything for a claw: VM + OS disk + NIC + IP + data disk + subnet
    local claw="$1"
    local data_disk subnet_name
    data_disk=$(claw_data_name "$claw")
    subnet_name=$(claw_subnet_name "$claw")

    echo "Destroying claw '$claw' (including data disk)..."
    destroy_vm_only "$claw"

    az disk delete -g "$RESOURCE_GROUP" --name "$data_disk" --yes --output none 2>/dev/null || true
    az network vnet subnet delete \
        -g "$RESOURCE_GROUP" \
        --vnet-name "$VNET_NAME" \
        --name "$subnet_name" \
        --output none 2>/dev/null || true

    echo "[OK] Claw '$claw' destroyed."
}

destroy_all() {
    echo "Destroying entire resource group ${RESOURCE_GROUP}..."
    az group delete --name "$RESOURCE_GROUP" --yes 2>/dev/null && echo "[OK] Done." || echo "Nothing to destroy."
}

# --- Helpers: listing --------------------------------------------------------

list_claws() {
    validate_prereqs
    if ! az group show --name "$RESOURCE_GROUP" &>/dev/null; then
        echo "No claws (resource group ${RESOURCE_GROUP} doesn't exist)."
        return
    fi
    local vms
    vms=$(az vm list -g "$RESOURCE_GROUP" --query "[?starts_with(name, 'claw-')].name" -o tsv 2>/dev/null)
    if [[ -z "$vms" ]]; then
        echo "No claws deployed."
        return
    fi
    printf "%-20s %-15s %-15s %s\n" "NAME" "STATUS" "IMAGE" "PUBLIC IP"
    printf "%-20s %-15s %-15s %s\n" "----" "------" "-----" "---------"
    for vm in $vms; do
        local claw_name status image ip
        claw_name=${vm#claw-}; claw_name=${claw_name%-vm}
        status=$(az vm get-instance-view -g "$RESOURCE_GROUP" --name "$vm" \
            --query "instanceView.statuses[?starts_with(code, 'PowerState/')].displayStatus" \
            -o tsv 2>/dev/null || echo "unknown")
        local image_ref
        image_ref=$(az vm show -g "$RESOURCE_GROUP" --name "$vm" \
            --query "storageProfile.imageReference.id" -o tsv 2>/dev/null || true)
        image=$(basename "$image_ref" 2>/dev/null || echo "-")
        ip=$(az vm show -g "$RESOURCE_GROUP" --name "$vm" -d \
            --query "publicIps" -o tsv 2>/dev/null || echo "-")
        printf "%-20s %-15s %-15s %s\n" "$claw_name" "$status" "$image" "$ip"
    done
}

list_images() {
    validate_prereqs
    if ! az sig image-version list \
        -g "$RESOURCE_GROUP" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEFINITION" \
        --query "[].{version:name, state:provisioningState}" \
        -o table 2>/dev/null; then
        echo "No images yet. Run './deploy.sh --bake' to create one."
    fi
}

# --- Runtime init script rendering (SSH-injected, not cloud-init) -----------
# Specialized images don't honor --custom-data (Azure skips provisioning for
# them). Instead we SCP a rendered bash script and run it over SSH after the
# VM boots.

prepare_runtime_init() {
    RDP_PASSWORD="$(openssl rand -base64 16 | tr -d '/+=' | head -c 20)Aa1!"

    RUNTIME_INIT_RENDERED="$(mktemp)"
    trap 'rm -f "$RUNTIME_INIT_RENDERED"' EXIT

    sed \
        -e "s|__XAI_API_KEY__|${XAI_API_KEY}|g" \
        -e "s|__TELEGRAM_BOT_TOKEN__|${TELEGRAM_BOT_TOKEN}|g" \
        -e "s|__TELEGRAM_DM_POLICY__|${TELEGRAM_DM_POLICY}|g" \
        -e "s|__TELEGRAM_ALLOW_FROM__|${TELEGRAM_ALLOW_FROM}|g" \
        -e "s|__RDP_PASSWORD__|${RDP_PASSWORD}|g" \
        "$RUNTIME_INIT_TEMPLATE" > "$RUNTIME_INIT_RENDERED"

    echo "[OK] Runtime init script prepared"
}

# --- VM creation from gallery image ------------------------------------------

create_vm_from_image() {
    local claw="$1" image_id="$2"
    local vm nic data_disk
    vm=$(claw_vm_name "$claw")
    nic=$(claw_nic_name "$claw")
    data_disk=$(claw_data_name "$claw")

    echo "Creating VM ${vm} from image $(basename "$image_id")..."
    # --specialized images inherit user + SSH keys from the bake VM.
    # The Azure CLI still requires an SSH key for parameter validation; pass
    # our local key (Azure ignores it when --specialized is set).
    # NO --custom-data: specialized images skip provisioning, so cloud-init
    # won't run the runtime config. We SSH-inject it after boot instead.
    az vm create \
        -g "$RESOURCE_GROUP" \
        --name "$vm" \
        --nics "$nic" \
        --image "$image_id" \
        --specialized \
        --size "$VM_SIZE" \
        --os-disk-size-gb "$OS_DISK_SIZE" \
        --storage-sku Premium_LRS \
        --attach-data-disks "$data_disk" \
        --zone 3 \
        --security-type TrustedLaunch \
        --enable-secure-boot true \
        --enable-vtpm true \
        --ssh-key-values "$SSH_KEY_FILE" \
        --output none
}

inject_runtime_init() {
    # SCP the rendered runtime-init.sh to the VM and run it as root.
    local claw="$1"
    local ip="$2"
    echo "Injecting runtime config over SSH..."

    # Copy the script
    scp $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=30 \
        "$RUNTIME_INIT_RENDERED" \
        "${ADMIN_USER}@${ip}:/tmp/openclaw-runtime-init.sh" 2>/dev/null

    # Run it as root
    ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=30 -o ServerAliveInterval=30 \
        "${ADMIN_USER}@${ip}" \
        "chmod +x /tmp/openclaw-runtime-init.sh && sudo /tmp/openclaw-runtime-init.sh && rm /tmp/openclaw-runtime-init.sh" \
        2>&1 | sed 's/^/  /'
}

wait_for_ssh() {
    local claw="$1"
    local vm ip
    vm=$(claw_vm_name "$claw")
    ip=$(az vm show -g "$RESOURCE_GROUP" --name "$vm" -d --query publicIps -o tsv)
    echo ""
    echo "VM up at ${ip}. Waiting for SSH..."

    for i in $(seq 1 60); do
        if ssh $SSH_OPTS -i "$SSH_KEY" -o ConnectTimeout=5 "${ADMIN_USER}@${ip}" "true" 2>/dev/null; then
            # Return the IP via global var for the caller
            CLAW_IP="$ip"
            return 0
        fi
        sleep 5
    done
    echo "ERROR: SSH didn't become available within 5 minutes"
    return 1
}

verify_services() {
    local claw="$1"
    echo ""
    echo "Verifying services on $(claw_vm_name "$claw")..."
    ssh $SSH_OPTS -i "$SSH_KEY" "${ADMIN_USER}@${CLAW_IP}" '
        OC=$(sudo systemctl is-active openclaw-gateway 2>/dev/null || echo inactive)
        XRDP=$(sudo systemctl is-active xrdp 2>/dev/null || echo inactive)
        XVFB=$(sudo systemctl is-active xvfb 2>/dev/null || echo inactive)
        VNC=$(sudo systemctl is-active x11vnc-xvfb 2>/dev/null || echo inactive)
        echo "  OpenClaw Gateway: $OC"
        echo "  xrdp (desktop):   $XRDP"
        echo "  Xvfb (display):   $XVFB"
        echo "  x11vnc (mirror):  $VNC"
        if mount | grep -q "/data "; then
            echo "  Data disk:        mounted"
        else
            echo "  Data disk:        NOT MOUNTED"
        fi
        if sudo iptables -C OUTPUT -d 169.254.169.254 -j DROP 2>/dev/null; then
            echo "  Azure IMDS:       blocked"
        else
            echo "  Azure IMDS:       REACHABLE (expected blocked)"
        fi
    ' 2>/dev/null || echo "(verification skipped)"
}

print_credentials() {
    local claw="$1"
    echo ""
    echo "=========================================="
    echo " Claw '${claw}' ready!"
    echo "=========================================="
    echo ""
    echo " RDP:        ${CLAW_IP}:3389"
    echo " Username:   ${ADMIN_USER}"
    echo " Password:   ${RDP_PASSWORD}"
    echo ""
    echo " Telegram:   Send any message to your bot -- it responds immediately."
    echo ""
    echo " Manage this claw:"
    echo "   ./deploy.sh ${claw} --update   (rebuild VM, keep data)"
    echo "   ./deploy.sh ${claw} --fresh    (wipe data, new VM)"
    echo "   ./deploy.sh ${claw} --destroy  (delete completely)"
    echo ""
    echo "=========================================="
}

# --- Main dispatch -----------------------------------------------------------

if [[ "$SUBCOMMAND" == "list" ]]; then
    list_claws
    exit 0
fi

if [[ "$SUBCOMMAND" == "images" ]]; then
    list_images
    exit 0
fi

if [[ "$DESTROY_ALL" == true ]]; then
    validate_prereqs
    destroy_all
    exit 0
fi

# All remaining commands need prereqs + RG + shared networking
validate_prereqs
ensure_resource_group
ensure_shared_networking

# --bake (standalone, no claw)
if [[ "$BAKE_ONLY" == true ]]; then
    validate_ssh_key
    bake_image
    exit 0
fi

# From here down, claw-scoped commands
[[ -z "$CLAW_NAME" ]] && { echo "ERROR: no claw name specified"; exit 1; }

# --destroy: delete this claw only
if [[ "$DESTROY" == true ]]; then
    destroy_claw "$CLAW_NAME"
    exit 0
fi

# Validate secrets + SSH key (needed for create/update/fresh)
validate_secrets
validate_ssh_key
prepare_runtime_init

# --update: claw must exist, keep data disk
if [[ "$UPDATE" == true ]]; then
    if ! claw_exists "$CLAW_NAME"; then
        echo "ERROR: claw '$CLAW_NAME' doesn't exist. Use './deploy.sh $CLAW_NAME' to create it."
        exit 1
    fi
    destroy_vm_only "$CLAW_NAME"

# --fresh: destroy everything, recreate with new data disk
elif [[ "$FRESH" == true ]]; then
    if claw_exists "$CLAW_NAME"; then
        destroy_claw "$CLAW_NAME"
    else
        echo "Claw '$CLAW_NAME' didn't exist. Creating fresh."
    fi

# No flag: new claw, error if exists
else
    if claw_exists "$CLAW_NAME"; then
        echo "ERROR: claw '$CLAW_NAME' already exists."
        echo "  ./deploy.sh $CLAW_NAME --update   (rebuild VM, keep data)"
        echo "  ./deploy.sh $CLAW_NAME --fresh    (wipe data, new VM)"
        echo "  ./deploy.sh $CLAW_NAME --destroy  (delete completely)"
        exit 1
    fi
fi

# Determine which image version to use
if [[ -n "$PINNED_IMAGE" ]]; then
    IMAGE_ID=$(image_id_for_version "$PINNED_IMAGE")
else
    IMAGE_ID=$(latest_image_id)
fi

if [[ -z "$IMAGE_ID" ]]; then
    echo ""
    echo "No image version exists yet. Baking initial image (~10 min)..."
    bake_image
    IMAGE_ID=$(latest_image_id)
fi

echo ""
echo "=========================================="
echo " Deploying claw '${CLAW_NAME}'"
echo "=========================================="
echo " Image:    $(basename "$IMAGE_ID")"
echo " Size:     ${VM_SIZE}"
echo " Region:   ${LOCATION} (zone 3)"
echo "=========================================="
echo ""

ensure_claw_subnet "$CLAW_NAME"
ensure_claw_public_ip "$CLAW_NAME"
ensure_claw_nic "$CLAW_NAME"
ensure_claw_data_disk "$CLAW_NAME"
create_vm_from_image "$CLAW_NAME" "$IMAGE_ID"
wait_for_ssh "$CLAW_NAME"
inject_runtime_init "$CLAW_NAME" "$CLAW_IP"
verify_services "$CLAW_NAME"
print_credentials "$CLAW_NAME"
