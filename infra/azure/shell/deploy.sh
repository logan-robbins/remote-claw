#!/usr/bin/env bash
# deploy.sh -- OpenClaw VM lifecycle manager
#
# Modes:
#   ./bin/deploy.sh              Deploy a new claw from a golden image (Phase 3)
#   ./bin/deploy.sh scratch      Build a complete VM from stock Ubuntu (Phase 1)
#   ./bin/deploy.sh bake [NAME]  Capture current VM as a reusable image (Phase 2)
#   ./bin/deploy.sh upgrade VM_NAME [--image IMAGE]  Upgrade a claw to a new image
#
# Environment overrides:
#   ENV_FILE=.env.alice VM_NAME=alice ./bin/deploy.sh
#   IMAGE_NAME=claw-base-v2 ./bin/deploy.sh
#   VM_SIZE=Standard_D4s_v3 ./bin/deploy.sh scratch

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
VM_RUNTIME_DIR="${REPO_ROOT}/vm-runtime"
LIFECYCLE_DIR="${VM_RUNTIME_DIR}/lifecycle"
DEFAULTS_DIR="${VM_RUNTIME_DIR}/defaults"
UPDATES_DIR="${VM_RUNTIME_DIR}/updates"
CLOUD_INIT_DIR="${VM_RUNTIME_DIR}/cloud-init"
STATE_DIR="${REPO_ROOT}/.state/shell"
DEPLOY_CMD="${DEPLOY_CMD:-./bin/deploy.sh}"

# --- Parse mode ---------------------------------------------------------------
MODE="${1:-image}"
case "$MODE" in
    scratch)  shift ;;
    bake)     shift; BAKE_IMAGE_NAME="${1:-claw-base-v$(date +%Y%m%d)}"; shift 2>/dev/null || true ;;
    upgrade)  shift
              UPGRADE_VM="${1:?Usage: deploy.sh upgrade VM_NAME [--image IMAGE_NAME]}"
              shift
              if [[ "${1:-}" == "--image" ]]; then
                  shift; UPGRADE_IMAGE="${1:?--image requires a value}"; shift 2>/dev/null || true
              fi
              ;;
    image)    ;; # default mode, no shift needed
    -h|--help)
        echo "Usage: ${DEPLOY_CMD} [scratch|bake [IMAGE_NAME]|upgrade VM_NAME [--image IMAGE_NAME]]"
        echo ""
        echo "Modes:"
        echo "  (default)   Deploy from golden image with a fresh data disk"
        echo "  scratch     Build a full VM from stock Ubuntu 24.04"
        echo "  bake NAME   Capture the current VM as a reusable image"
        echo "  upgrade VM  Upgrade a claw to a new (or specified) image version"
        exit 0
        ;;
    *)
        echo "Unknown mode: $MODE" >&2
        echo "Usage: ${DEPLOY_CMD} [scratch|bake [IMAGE_NAME]|upgrade VM_NAME [--image IMAGE_NAME]]" >&2
        exit 1
        ;;
esac

# --- Configuration ------------------------------------------------------------
RG="${RG:-rg-linux-desktop}"
LOCATION="${LOCATION:-eastus}"
VM_NAME="${VM_NAME:-linux-desktop}"
VM_SIZE="${VM_SIZE:-Standard_D2s_v3}"
ADMIN_USER="${ADMIN_USER:-azureuser}"
VNET_NAME="${VNET_NAME:-${RG}-vnet}"
SUBNET_NAME="${SUBNET_NAME:-default}"
NSG_NAME="${NSG_NAME:-${RG}-nsg}"
DATA_DISK_SIZE="${DATA_DISK_SIZE:-32}"
DATA_DISK_SKU="${DATA_DISK_SKU:-Standard_LRS}"
IMAGE_NAME="${IMAGE_NAME:-}"
GALLERY_NAME="${GALLERY_NAME:-clawGallery}"
IMAGE_DEF="${IMAGE_DEF:-claw-base}"
DATA_LUN=0

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
CLOUD_INIT_FULL="${CLOUD_INIT_DIR}/scratch.yaml"
CLOUD_INIT_SLIM="${CLOUD_INIT_DIR}/image.yaml"
VM_STATE_FILE="${STATE_DIR}/current.env"
SOUL_FILE="${DEFAULTS_DIR}/workspace/SOUL.md"

# =============================================================================
# Shared functions
# =============================================================================

# --- VM password --------------------------------------------------------------
# Password auth is used instead of SSH keys for simpler cross-machine access.
# VM_PASSWORD can be set in .env or auto-generated at deploy time.
VM_PASSWORD="${VM_PASSWORD:-}"

generate_password() {
    # 20-char alphanumeric + symbols to satisfy Azure complexity requirements
    # (must have uppercase, lowercase, digit, and special char)
    local pass
    pass="Claw-$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | cut -c1-14)!"
    echo "$pass"
}

ensure_password() {
    if [[ -z "$VM_PASSWORD" ]]; then
        VM_PASSWORD=$(generate_password)
        echo "Generated VM password: $VM_PASSWORD" >&2
    fi
    export VM_PASSWORD
}

# --- SSH key selection (CURRENTLY UNUSED) -------------------------------------
# We are currently using password auth instead of SSH keys for VM access.
# This function is preserved so we can switch back to key-based auth if needed.
# To re-enable: uncomment the select_ssh_key calls in each deploy function,
# replace --authentication-type password with --ssh-key-values "$SSH_KEY_FILE",
# and update ssh_cmd/scp_to to use -i "$PRIVATE_KEY" instead of sshpass.
#
# select_ssh_key() {
#     if [[ -n "${SSH_KEY_FILE:-}" ]]; then
#         if [[ -f "$SSH_KEY_FILE" ]]; then
#             echo "$SSH_KEY_FILE"
#             return 0
#         fi
#         echo "ERROR: SSH_KEY_FILE=$SSH_KEY_FILE does not exist" >&2
#         exit 1
#     fi
#
#     local keys=()
#     shopt -s nullglob
#     for key in "$HOME"/.ssh/*.pub; do
#         [[ -f "$key" ]] && keys+=("$key")
#     done
#     shopt -u nullglob
#
#     if [[ ${#keys[@]} -eq 0 ]]; then
#         echo "ERROR: no SSH public keys found in ~/.ssh/*.pub" >&2
#         echo "Generate one with:  ssh-keygen -t ed25519" >&2
#         exit 1
#     fi
#
#     if [[ ${#keys[@]} -eq 1 ]]; then
#         echo "Using SSH public key: ${keys[0]}" >&2
#         echo "${keys[0]}"
#         return 0
#     fi
#
#     echo "Multiple SSH public keys found in ~/.ssh/:" >&2
#     local i=1
#     for key in "${keys[@]}"; do
#         local comment
#         comment=$(awk '{for (i=3; i<=NF; i++) printf "%s%s", $i, (i<NF?" ":"")}' "$key" 2>/dev/null || echo "")
#         printf "  %d) %s" "$i" "$key" >&2
#         [[ -n "$comment" ]] && printf "  (%s)" "$comment" >&2
#         printf "\n" >&2
#         i=$((i + 1))
#     done
#     printf "\n" >&2
#     local choice
#     read -rp "Select a key [1-${#keys[@]}]: " choice </dev/tty
#     if ! [[ "$choice" =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#keys[@]} )); then
#         echo "ERROR: invalid selection '$choice'" >&2
#         exit 1
#     fi
#     echo "Using SSH public key: ${keys[$((choice - 1))]}" >&2
#     echo "${keys[$((choice - 1))]}"
# }

# --- .env loader + validation -------------------------------------------------
REQUIRED_ENV_VARS=(TELEGRAM_BOT_TOKEN)
OPTIONAL_ENV_VARS=(OPENCLAW_MODEL XAI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY MOONSHOT_API_KEY DEEPSEEK_API_KEY BRIGHTDATA_API_TOKEN TELEGRAM_USER_ID TAILSCALE_AUTHKEY)

load_env() {
    if [[ ! -f "$ENV_FILE" ]]; then
        echo "ERROR: $ENV_FILE not found." >&2
        echo "Copy .env.template to .env and fill in your keys:" >&2
        echo "  cp .env.template .env" >&2
        exit 1
    fi

    # shellcheck disable=SC1090
    set -a; source "$ENV_FILE"; set +a

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

    for var in "${OPTIONAL_ENV_VARS[@]}"; do
        export "$var=${!var:-}"
    done

    # Default model if not specified
    export OPENCLAW_MODEL="${OPENCLAW_MODEL:-xai/grok-4.20-0309-reasoning}"
}

# --- Telegram policy derivation -----------------------------------------------
compute_telegram_policy() {
    if [[ -n "${TELEGRAM_USER_ID:-}" ]]; then
        export TELEGRAM_DM_POLICY="allowlist"
        export TELEGRAM_ALLOW_FROM="\"${TELEGRAM_USER_ID}\""
    else
        export TELEGRAM_DM_POLICY="open"
        export TELEGRAM_ALLOW_FROM="\"*\""
    fi
}

# --- SOUL.md base64 encoding --------------------------------------------------
load_soul_md() {
    if [[ -f "$SOUL_FILE" ]]; then
        echo "Including SOUL.md from $SOUL_FILE" >&2
        export SOUL_MD_BASE64="$(base64 < "$SOUL_FILE" | tr -d '\n')"
    else
        echo "No SOUL.md found at $SOUL_FILE -- using minimal placeholder" >&2
        export SOUL_MD_BASE64="$(printf '# Agent soul not provided\n' | base64 | tr -d '\n')"
    fi
}

# --- Render cloud-init templates ----------------------------------------------
render_cloud_init() {
    local template="$1"
    local rendered
    rendered="$(mktemp -t openclaw-cloud-init.XXXXXX)"
    envsubst '
        ${OPENCLAW_MODEL}
        ${XAI_API_KEY}
        ${OPENAI_API_KEY}
        ${ANTHROPIC_API_KEY}
        ${MOONSHOT_API_KEY}
        ${DEEPSEEK_API_KEY}
        ${BRIGHTDATA_API_TOKEN}
        ${TELEGRAM_BOT_TOKEN}
        ${TELEGRAM_USER_ID}
        ${TELEGRAM_DM_POLICY}
        ${TELEGRAM_ALLOW_FROM}
        ${SOUL_MD_BASE64}
        ${VM_PASSWORD}
        ${TAILSCALE_AUTHKEY}
    ' < "$template" > "$rendered"
    echo "$rendered"
}

# --- Shell state --------------------------------------------------------------
write_vm_state() {
    local ip="$1" vnc_pass="$2" extra_vm="${3:-$VM_NAME}"
    mkdir -p "$STATE_DIR"
    cat > "$VM_STATE_FILE" <<EOF
# Runtime state for the current shell-managed VM. Gitignored. Overwritten by deploy.sh.
IP=${ip}
VM_PASSWORD=${VM_PASSWORD}
VNC_URL=vnc://${ip}:5900
VNC_PASSWORD=${vnc_pass}
SSH="sshpass -p '${VM_PASSWORD}' ssh ${ADMIN_USER}@${ip}"
RG=${RG}
VM_NAME=${extra_vm}
LOCATION=${LOCATION}
VM_SIZE=${VM_SIZE}
DEPLOYED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    echo "Wrote $VM_STATE_FILE" >&2
}

load_vm_state() {
    if [[ ! -f "$VM_STATE_FILE" ]]; then
        echo "ERROR: $VM_STATE_FILE not found. Deploy a VM first." >&2
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$VM_STATE_FILE"
}

# --- Shared infrastructure (idempotent) ---------------------------------------
ensure_shared_infra() {
    echo "Ensuring resource group $RG in $LOCATION..."
    az group create --name "$RG" --location "$LOCATION" --output none

    if ! az network vnet show -g "$RG" -n "$VNET_NAME" &>/dev/null; then
        echo "Creating virtual network $VNET_NAME..."
        az network vnet create -g "$RG" -n "$VNET_NAME" \
            --address-prefix 10.0.0.0/16 \
            --subnet-name "$SUBNET_NAME" \
            --subnet-prefix 10.0.0.0/24 \
            --output none
    else
        echo "Virtual network $VNET_NAME already exists."
    fi

    if ! az network nsg show -g "$RG" -n "$NSG_NAME" &>/dev/null; then
        echo "Creating NSG $NSG_NAME (wide open)..."
        az network nsg create -g "$RG" -n "$NSG_NAME" --output none
        az network nsg rule create -g "$RG" --nsg-name "$NSG_NAME" \
            -n AllowAll --priority 100 \
            --access Allow --direction Inbound \
            --protocol '*' --source-address-prefixes '*' \
            --source-port-ranges '*' --destination-port-ranges '*' \
            --destination-address-prefixes '*' \
            --output none
    else
        echo "NSG $NSG_NAME already exists."
    fi
}

# --- SSH helper (password auth via sshpass) ------------------------------------
ssh_cmd() {
    local ip="$1"; shift
    sshpass -p "$VM_PASSWORD" ssh \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no \
        -o ConnectTimeout=10 \
        "${ADMIN_USER}@${ip}" "$@" 2>/dev/null
}

scp_to() {
    local ip="$1" src="$2" dst="$3"
    sshpass -p "$VM_PASSWORD" scp \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o PubkeyAuthentication=no \
        -r "$src" "${ADMIN_USER}@${ip}:${dst}" 2>/dev/null
}

# --- Run post-deploy verification on the VM -----------------------------------
run_verify() {
    local ip="$1"
    echo ""
    echo "Running health checks..."
    # verify.sh is staged at /opt/claw/verify.sh on the VM
    if ssh_cmd "$ip" "sudo /opt/claw/verify.sh" 2>/dev/null; then
        echo ""
        echo "All health checks passed."
    else
        echo ""
        echo "WARNING: Some health checks failed. Review output above." >&2
    fi
}

# --- Wait for SSH to be reachable --------------------------------------------
wait_for_ssh() {
    local ip="$1" max_wait="${2:-120}"
    echo "Waiting for SSH on ${ip}..."
    local elapsed=0
    while (( elapsed < max_wait )); do
        if ssh_cmd "$ip" "true" 2>/dev/null; then
            echo "SSH ready."
            return 0
        fi
        sleep 5
        (( elapsed += 5 ))
    done
    echo "WARNING: SSH not ready after ${max_wait}s" >&2
    return 1
}

# --- Image resolution (Azure Compute Gallery) --------------------------------
# Returns the full resource ID of the gallery image version to use.
resolve_image() {
    # If IMAGE_NAME looks like a version number (e.g. "1.0.0"), use it directly
    if [[ -n "$IMAGE_NAME" ]]; then
        local version_id
        version_id=$(az sig image-version show \
            -g "$RG" --gallery-name "$GALLERY_NAME" \
            --gallery-image-definition "$IMAGE_DEF" \
            --gallery-image-version "$IMAGE_NAME" \
            --query id -o tsv 2>/dev/null) || true
        if [[ -z "$version_id" ]]; then
            echo "ERROR: Image version '$IMAGE_NAME' not found in gallery '$GALLERY_NAME/$IMAGE_DEF'" >&2
            exit 1
        fi
        echo "$version_id"
        return 0
    fi

    # Find the latest version in the gallery
    local latest_id
    latest_id=$(az sig image-version list \
        -g "$RG" --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEF" \
        --query "sort_by([],&name)[-1].id" -o tsv 2>/dev/null) || true
    if [[ -z "$latest_id" ]]; then
        echo "ERROR: No image versions found in gallery '$GALLERY_NAME/$IMAGE_DEF'." >&2
        echo "Run '${DEPLOY_CMD} scratch' first, then '${DEPLOY_CMD} bake' to create an image." >&2
        exit 1
    fi
    echo "$latest_id"
}

# --- Data disk management -----------------------------------------------------
ensure_data_disk() {
    local disk_name="${1:-${VM_NAME}-data}"

    if az disk show -g "$RG" -n "$disk_name" &>/dev/null; then
        echo "Data disk '$disk_name' already exists." >&2
    else
        echo "Creating data disk '$disk_name' (${DATA_DISK_SIZE}GB, ${DATA_DISK_SKU})..." >&2
        az disk create -g "$RG" -n "$disk_name" \
            --size-gb "$DATA_DISK_SIZE" \
            --sku "$DATA_DISK_SKU" \
            --output none
    fi
    echo "$disk_name"
}

# --- Stage boot files to a VM via SCP ----------------------------------------
stage_boot_files() {
    local ip="$1"
    echo "Staging boot files to /opt/claw/..."

    # Create directory structure
    ssh_cmd "$ip" "sudo mkdir -p /opt/claw/defaults /opt/claw/updates"

    # Upload files to a temp location, then sudo mv to /opt/claw
    local tmpdir="/tmp/claw-stage-$$"
    ssh_cmd "$ip" "mkdir -p $tmpdir"

    scp_to "$ip" "${LIFECYCLE_DIR}/boot.sh" "$tmpdir/boot.sh"
    scp_to "$ip" "${LIFECYCLE_DIR}/run-updates.sh" "$tmpdir/run-updates.sh"
    scp_to "$ip" "${LIFECYCLE_DIR}/start-claude.sh" "$tmpdir/start-claude.sh"
    scp_to "$ip" "${LIFECYCLE_DIR}/verify.sh" "$tmpdir/verify.sh"
    scp_to "$ip" "${DEFAULTS_DIR}/" "$tmpdir/defaults"
    scp_to "$ip" "${UPDATES_DIR}/" "$tmpdir/updates"

    ssh_cmd "$ip" "
        sudo cp $tmpdir/boot.sh /opt/claw/boot.sh
        sudo cp $tmpdir/run-updates.sh /opt/claw/run-updates.sh
        sudo cp $tmpdir/start-claude.sh /opt/claw/start-claude.sh
        sudo cp $tmpdir/verify.sh /opt/claw/verify.sh
        sudo cp -a $tmpdir/defaults/. /opt/claw/defaults/
        sudo cp -a $tmpdir/updates/. /opt/claw/updates/
        sudo chmod +x /opt/claw/boot.sh /opt/claw/run-updates.sh /opt/claw/start-claude.sh /opt/claw/verify.sh
        sudo chmod +x /opt/claw/updates/*.sh 2>/dev/null || true
        rm -rf $tmpdir
    "
    echo "Boot files staged."
}

# =============================================================================
# Phase 1: scratch -- build from stock Ubuntu
# =============================================================================

deploy_scratch() {
    if [[ ! -f "$CLOUD_INIT_FULL" ]]; then
        echo "ERROR: scratch cloud-init not found at $CLOUD_INIT_FULL" >&2
        exit 1
    fi

    load_env
    ensure_password
    compute_telegram_policy
    load_soul_md

    local rendered
    rendered=$(render_cloud_init "$CLOUD_INIT_FULL")
    trap 'rm -f "$rendered"' EXIT

    ensure_shared_infra

    echo "Creating VM $VM_NAME ($VM_SIZE) from stock Ubuntu..."
    az vm create \
        --resource-group "$RG" \
        --name "$VM_NAME" \
        --image Canonical:ubuntu-24_04-lts:server:latest \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --authentication-type password \
        --admin-password "$VM_PASSWORD" \
        --custom-data "$rendered" \
        --vnet-name "$VNET_NAME" \
        --subnet "$SUBNET_NAME" \
        --nsg "$NSG_NAME" \
        --public-ip-sku Standard \
        --output none

    local ip
    ip=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)
    echo "VM created at $ip. Waiting for cloud-init to complete..."

    # Wait for cloud-init to finish (full install takes ~10 min)
    local ci_done=false
    for i in $(seq 1 120); do
        local status
        status=$(ssh_cmd "$ip" "sudo cloud-init status 2>/dev/null | grep -oE 'done|running|error'" 2>/dev/null || echo "")
        if [[ "$status" == "done" ]]; then
            ci_done=true
            break
        elif [[ "$status" == "error" ]]; then
            echo "WARNING: cloud-init reported errors. Continuing..." >&2
            ci_done=true
            break
        fi
        sleep 10
    done

    if [[ "$ci_done" != "true" ]]; then
        echo "WARNING: cloud-init did not complete within 20 min. Continuing anyway..." >&2
    fi

    # Stage boot files via SCP
    stage_boot_files "$ip"

    # Get VNC password
    local vnc_pass=""
    vnc_pass=$(ssh_cmd "$ip" "cat ~/vnc-password.txt" 2>/dev/null || echo "")
    if [[ -z "$vnc_pass" ]]; then
        vnc_pass="<not-ready:  ssh ${ADMIN_USER}@${ip} 'cat ~/vnc-password.txt'>"
    fi

    write_vm_state "$ip" "$vnc_pass"

    cat <<EOF

[OK] Scratch VM deployed at $ip

cloud-init has completed. OpenClaw gateway should be active.
Boot files staged at /opt/claw/ -- ready to bake.

Connection info (also in ${VM_STATE_FILE}):
  VNC:  vnc://${ip}:5900
  VNC password:  ${vnc_pass}
  SSH:  ssh ${ADMIN_USER}@${ip}  (password: ${VM_PASSWORD})

Next steps:
  1. Verify: message your Telegram bot
  2. Bake:   ${DEPLOY_CMD} bake claw-base-v1
EOF
}

# =============================================================================
# Phase 2: bake -- capture VM as reusable image
# =============================================================================

do_bake() {
    local image_name="${BAKE_IMAGE_NAME}"

    # Load VM state to get current VM info (includes VM_PASSWORD)
    load_vm_state

    local ip="$IP"
    local vm="$VM_NAME"
    echo "Baking VM '$vm' at $ip into image '$image_name'..."

    # Ensure boot files are up to date
    stage_boot_files "$ip"

    # Run cleanup on the VM
    echo "Cleaning up VM for image capture..."
    ssh_cmd "$ip" "
        set -e

        # Stop runtime services
        sudo systemctl stop openclaw-gateway 2>/dev/null || true
        sudo systemctl stop x11vnc 2>/dev/null || true

        # Remove secrets from OS disk
        rm -f ~/.env
        rm -f ~/.openclaw/.env 2>/dev/null || true

        # Clear transient state
        sudo rm -rf /tmp/* /var/tmp/* 2>/dev/null || true
        rm -f ~/.bash_history
        sudo rm -f /var/log/claw-boot.log 2>/dev/null || true

        # Update systemd unit to read secrets from data-disk path
        sudo sed -i 's|EnvironmentFile=/home/azureuser/.env|EnvironmentFile=/home/azureuser/.openclaw/.env|' \
            /etc/systemd/system/openclaw-gateway.service
        sudo sed -i 's|ConditionPathExists=/home/azureuser/.env|ConditionPathExists=/home/azureuser/.openclaw/.env|' \
            /etc/systemd/system/openclaw-gateway.service
        sudo systemctl daemon-reload

        # Deprovision (removes user, SSH keys, DHCP leases -- standard for Azure image generalization)
        sudo waagent -deprovision+user -force
    "

    echo "Deallocating VM..."
    az vm deallocate -g "$RG" -n "$vm" --output none

    echo "Generalizing VM..."
    az vm generalize -g "$RG" -n "$vm" --output none

    # Ensure gallery and image definition exist
    if ! az sig show -g "$RG" --gallery-name "$GALLERY_NAME" &>/dev/null; then
        echo "Creating compute gallery '$GALLERY_NAME'..."
        az sig create -g "$RG" --gallery-name "$GALLERY_NAME" --output none
    fi
    if ! az sig image-definition show -g "$RG" --gallery-name "$GALLERY_NAME" \
            --gallery-image-definition "$IMAGE_DEF" &>/dev/null; then
        echo "Creating image definition '$IMAGE_DEF'..."
        az sig image-definition create \
            -g "$RG" --gallery-name "$GALLERY_NAME" \
            --gallery-image-definition "$IMAGE_DEF" \
            --publisher claw --offer claw-vm --sku base \
            --os-type Linux --os-state Generalized \
            --hyper-v-generation V2 \
            --features "SecurityType=TrustedLaunch" \
            --output none
    fi

    local vm_id
    vm_id=$(az vm show -g "$RG" -n "$vm" --query id -o tsv)

    echo "Creating image version '$image_name' in gallery..."
    az sig image-version create \
        -g "$RG" \
        --gallery-name "$GALLERY_NAME" \
        --gallery-image-definition "$IMAGE_DEF" \
        --gallery-image-version "$image_name" \
        --virtual-machine "$vm_id" \
        --output none

    echo ""
    echo "[OK] Image version '$image_name' created in gallery '$GALLERY_NAME/$IMAGE_DEF'"
    echo ""
    echo "The source VM '$vm' has been generalized and can no longer be started."
    echo ""
    echo "Next steps:"
    echo "  Deploy a new VM:         VM_NAME=my-vm ${DEPLOY_CMD}"
    echo "  Deploy with custom env:  ENV_FILE=.env.alice VM_NAME=alice ${DEPLOY_CMD}"
}

# =============================================================================
# Phase 3: image -- deploy from golden image (default mode)
# =============================================================================

deploy_from_image() {
    if [[ ! -f "$CLOUD_INIT_SLIM" ]]; then
        echo "ERROR: image cloud-init not found at $CLOUD_INIT_SLIM" >&2
        exit 1
    fi

    load_env
    ensure_password

    local image_id
    image_id=$(resolve_image)
    local image_label
    image_label=$(basename "$image_id")
    echo "Using image: $image_label"

    ensure_shared_infra

    local disk_name
    disk_name=$(ensure_data_disk "${VM_NAME}-data")

    # Render slim cloud-init
    local rendered
    rendered=$(render_cloud_init "$CLOUD_INIT_SLIM")
    trap 'rm -f "${rendered:-}"' EXIT

    # Get data disk resource ID for attach-at-create
    local disk_id
    disk_id=$(az disk show -g "$RG" -n "$disk_name" --query id -o tsv)

    echo "Creating VM $VM_NAME ($VM_SIZE) from gallery image with data disk..."
    az vm create \
        --resource-group "$RG" \
        --name "$VM_NAME" \
        --image "$image_id" \
        --size "$VM_SIZE" \
        --admin-username "$ADMIN_USER" \
        --authentication-type password \
        --admin-password "$VM_PASSWORD" \
        --custom-data "$rendered" \
        --attach-data-disks "$disk_id" \
        --vnet-name "$VNET_NAME" \
        --subnet "$SUBNET_NAME" \
        --nsg "$NSG_NAME" \
        --public-ip-sku Standard \
        --security-type TrustedLaunch \
        --output none

    # Set delete behavior: keep data disk on VM delete
    az vm update -g "$RG" -n "$VM_NAME" \
        --set "storageProfile.dataDisks[0].deleteOption=Detach" \
        --output none 2>/dev/null || true

    local ip
    ip=$(az vm show -d -g "$RG" -n "$VM_NAME" --query publicIps -o tsv)
    echo "VM created at $ip. Waiting for boot.sh to complete..."

    # Wait for SSH
    wait_for_ssh "$ip" 180

    # Trigger boot.sh if cloud-init hasn't run it yet
    # (cloud-init runcmd calls it, but in case of race we ensure it ran)
    ssh_cmd "$ip" "
        if [[ ! -f /var/log/claw-boot.log ]] || ! grep -q 'Boot script complete' /var/log/claw-boot.log 2>/dev/null; then
            echo 'boot.sh has not completed yet -- waiting...'
            for i in \$(seq 1 60); do
                if grep -q 'Boot script complete' /var/log/claw-boot.log 2>/dev/null; then
                    break
                fi
                sleep 5
            done
        fi
    " || true

    # Wait a bit more for services to stabilize
    sleep 10

    # VNC password = VM_PASSWORD (single password for everything)
    write_vm_state "$ip" "$VM_PASSWORD"

    run_verify "$ip"

    cat <<EOF

[OK] Claw '$VM_NAME' deployed from image '$image_label' at $ip

Connection info (also in ${VM_STATE_FILE}):
  Password:  ${VM_PASSWORD}  (same for SSH and VNC)
  VNC:  vnc://${ip}:5900
  SSH:  ssh ${ADMIN_USER}@${ip}

Data disk: ${disk_name} mounted at /mnt/claw-data
Symlinks:
  ~/.openclaw -> /mnt/claw-data/openclaw
  ~/workspace -> /mnt/claw-data/workspace

Daily lifecycle:
  Stop:   az vm deallocate -g $RG -n $VM_NAME
  Start:  az vm start      -g $RG -n $VM_NAME
EOF
}

# =============================================================================
# Phase 4: upgrade -- new image, same data disk
# =============================================================================

do_upgrade() {
    local vm="${UPGRADE_VM}"
    local target_image="${UPGRADE_IMAGE:-}"

    # Load password from shell state or .env
    if [[ -f "$VM_STATE_FILE" ]]; then
        load_vm_state
    fi
    if [[ -z "$VM_PASSWORD" ]]; then
        load_env
        ensure_password
    fi

    # Resolve gallery image version
    if [[ -n "$target_image" ]]; then
        IMAGE_NAME="$target_image"
    fi
    local image_id
    image_id=$(resolve_image)
    local image_label
    image_label=$(basename "$image_id")
    echo "Upgrading '$vm' to image '$image_label'..."

    local disk_name="${vm}-data"

    # Verify data disk exists
    if ! az disk show -g "$RG" -n "$disk_name" &>/dev/null; then
        echo "ERROR: Data disk '$disk_name' not found. Cannot upgrade without a data disk." >&2
        exit 1
    fi

    # Get the NIC name before we delete the VM
    local nic_id
    nic_id=$(az vm show -g "$RG" -n "$vm" --query "networkProfile.networkInterfaces[0].id" -o tsv 2>/dev/null || echo "")

    # Deallocate
    echo "Deallocating VM '$vm'..."
    az vm deallocate -g "$RG" -n "$vm" --output none 2>/dev/null || true

    # Detach data disk
    echo "Detaching data disk '$disk_name'..."
    az vm disk detach -g "$RG" --vm-name "$vm" --name "$disk_name" --output none 2>/dev/null || true

    # Set NIC and public IP to not be deleted with the VM
    if [[ -n "$nic_id" ]]; then
        az vm update -g "$RG" -n "$vm" \
            --set "networkProfile.networkInterfaces[0].deleteOption=Detach" \
            --output none 2>/dev/null || true
    fi

    # Delete old VM (keeps NIC, public IP, data disk)
    echo "Deleting old VM '$vm'..."
    az vm delete -g "$RG" -n "$vm" --yes --output none

    # Get the NIC name for reuse
    local nic_name=""
    if [[ -n "$nic_id" ]]; then
        nic_name=$(basename "$nic_id")
    fi

    # Load env for cloud-init secrets
    load_env

    # Render slim cloud-init
    local rendered
    rendered=$(render_cloud_init "$CLOUD_INIT_SLIM")

    # Get data disk resource ID for attach-at-create
    local disk_id
    disk_id=$(az disk show -g "$RG" -n "$disk_name" --query id -o tsv)

    echo "Creating new VM '$vm' from image '$image_label' with data disk..."
    local create_args=(
        --resource-group "$RG"
        --name "$vm"
        --image "$image_id"
        --size "$VM_SIZE"
        --admin-username "$ADMIN_USER"
        --authentication-type password
        --admin-password "$VM_PASSWORD"
        --custom-data "$rendered"
        --attach-data-disks "$disk_id"
        --public-ip-sku Standard
        --security-type TrustedLaunch
        --output none
    )

    # Reuse NIC if available, otherwise use VNet/subnet/NSG
    if [[ -n "$nic_name" ]]; then
        create_args+=(--nics "$nic_name")
    else
        create_args+=(
            --vnet-name "$VNET_NAME"
            --subnet "$SUBNET_NAME"
            --nsg "$NSG_NAME"
        )
    fi

    az vm create "${create_args[@]}"

    az vm update -g "$RG" -n "$vm" \
        --set "storageProfile.dataDisks[0].deleteOption=Detach" \
        --output none 2>/dev/null || true

    local ip
    ip=$(az vm show -d -g "$RG" -n "$vm" --query publicIps -o tsv)
    echo "VM recreated at $ip. Waiting for boot.sh..."

    wait_for_ssh "$ip" 180

    # Wait for boot.sh to complete
    ssh_cmd "$ip" "
        for i in \$(seq 1 60); do
            if grep -q 'Boot script complete' /var/log/claw-boot.log 2>/dev/null; then
                break
            fi
            sleep 5
        done
    " || true

    sleep 10

    rm -f "$rendered"
    write_vm_state "$ip" "$VM_PASSWORD" "$vm"

    run_verify "$ip"

    cat <<EOF

[OK] Claw '$vm' upgraded to image '$image_label' at $ip

Data disk '$disk_name' reattached -- claw identity and state preserved.

Connection info (also in ${VM_STATE_FILE}):
  Password:  ${VM_PASSWORD}  (same for SSH and VNC)
  VNC:  vnc://${ip}:5900
  SSH:  ssh ${ADMIN_USER}@${ip}
EOF
}

# =============================================================================
# Preflight + dispatch
# =============================================================================

if ! command -v envsubst >/dev/null 2>&1; then
    echo "ERROR: envsubst not found. Install with:  brew install gettext" >&2
    exit 1
fi
if ! command -v sshpass >/dev/null 2>&1; then
    echo "ERROR: sshpass not found (used by ${DEPLOY_CMD} only -- VMs accept normal password SSH)." >&2
    echo "Install: curl -L https://sourceforge.net/projects/sshpass/files/sshpass/1.10/sshpass-1.10.tar.gz | tar xz && cd sshpass-1.10 && ./configure && make && cp sshpass ~/.local/bin/" >&2
    exit 1
fi

case "$MODE" in
    scratch)  deploy_scratch ;;
    bake)     do_bake ;;
    image)    deploy_from_image ;;
    upgrade)  do_upgrade ;;
esac
