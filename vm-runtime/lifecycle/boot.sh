#!/usr/bin/env bash
# /opt/claw/boot.sh -- idempotent boot orchestration for image-based claw VMs
#
# Runs at every VM start via cloud-init runcmd. Handles:
#   1. Azure data disk discovery and mount
#   2. First-boot seeding of defaults onto a new disk
#   3. Symlink repair and permissions
#   4. Pending update scripts
#   5. Service startup
#
# Requires: parted, mkfs.ext4, blkid, jq, x11vnc (all baked into the image)

set -euo pipefail

ADMIN_USER="azureuser"
HOME_DIR="/home/${ADMIN_USER}"
DATA_MOUNT="/mnt/claw-data"
DEFAULTS_DIR="/opt/claw/defaults"
UPDATES_DIR="/opt/claw/updates"
MARKER_FILE="${DATA_MOUNT}/.claw-initialized"
LOG_TAG="claw-boot"

log() { echo "[${LOG_TAG}] $(date -u +%Y-%m-%dT%H:%M:%SZ) $*" | tee -a /var/log/claw-boot.log; }

# =============================================================================
# 1. Identify and mount the Azure data disk
# =============================================================================

find_data_disk() {
    # Primary: Azure symlink for LUN 0
    local azure_link="/dev/disk/azure/scsi1/lun0"
    if [[ -L "$azure_link" ]]; then
        readlink -f "$azure_link"
        return 0
    fi

    # Fallback: scan /sys for SCSI devices at LUN 0, skipping OS/resource disks
    for dev in /sys/bus/scsi/devices/*/block/*; do
        [[ -e "$dev" ]] || continue
        local hctl_dir
        hctl_dir=$(dirname "$(dirname "$dev")")
        local lun
        lun=$(basename "$hctl_dir" | cut -d: -f4)
        if [[ "$lun" == "0" ]]; then
            local blk
            blk=$(basename "$dev")
            # sda = OS disk, sdb = resource disk on most Azure families
            if [[ "$blk" != "sda" && "$blk" != "sdb" ]]; then
                echo "/dev/$blk"
                return 0
            fi
        fi
    done

    return 1
}

mount_data_disk() {
    if mountpoint -q "$DATA_MOUNT"; then
        log "Data disk already mounted at ${DATA_MOUNT}"
        return 0
    fi

    local disk_dev
    local wait_tries=0
    local max_wait=60
    while ! disk_dev=$(find_data_disk); do
        (( wait_tries++ ))
        if (( wait_tries >= max_wait )); then
            log "FATAL: No data disk found at LUN 0 after ${max_wait}s. Cannot proceed without state disk."
            exit 1
        fi
        if (( wait_tries == 1 )); then
            log "Data disk not yet available at LUN 0 -- waiting (Terraform may still be attaching)..."
        fi
        sleep 1
    done
    log "Found data disk device: ${disk_dev}"

    local part_dev="${disk_dev}1"

    # Raw disk -- partition and format
    if ! blkid "$part_dev" &>/dev/null && ! blkid "$disk_dev" &>/dev/null; then
        log "Data disk is raw -- partitioning and formatting..."
        parted -s "$disk_dev" mklabel gpt mkpart primary ext4 0% 100%
        sleep 2
        # Re-resolve partition after parted
        part_dev="${disk_dev}1"
        mkfs.ext4 -L claw-data "$part_dev"
    fi

    # Determine mount device (partition preferred, raw device fallback)
    local mount_dev="$part_dev"
    if ! blkid "$part_dev" &>/dev/null; then
        mount_dev="$disk_dev"
    fi

    mkdir -p "$DATA_MOUNT"
    mount "$mount_dev" "$DATA_MOUNT"
    log "Mounted ${mount_dev} at ${DATA_MOUNT}"

    # Persist in fstab by UUID
    local uuid
    uuid=$(blkid -s UUID -o value "$mount_dev")
    if ! grep -q "$uuid" /etc/fstab 2>/dev/null; then
        echo "UUID=${uuid}  ${DATA_MOUNT}  ext4  defaults,nofail  0  2" >> /etc/fstab
        log "Added ${DATA_MOUNT} to fstab (UUID=${uuid})"
    fi
}

# =============================================================================
# 2. First-boot seeding
# =============================================================================

seed_new_disk() {
    [[ -f "$MARKER_FILE" ]] && return 0

    log "First boot detected -- seeding defaults onto data disk..."

    mkdir -p "${DATA_MOUNT}/openclaw" "${DATA_MOUNT}/workspace"

    # Copy default configs
    if [[ -d "${DEFAULTS_DIR}/openclaw" ]]; then
        cp -a "${DEFAULTS_DIR}/openclaw/." "${DATA_MOUNT}/openclaw/"
        log "Seeded openclaw defaults"
    fi
    if [[ -d "${DEFAULTS_DIR}/workspace" ]]; then
        cp -a "${DEFAULTS_DIR}/workspace/." "${DATA_MOUNT}/workspace/"
        log "Seeded workspace defaults"
    fi

    # Move secrets placed by vm-runtime/cloud-init/image.yaml into the data disk
    local ci_env="${HOME_DIR}/.openclaw/.env"
    if [[ -f "$ci_env" ]]; then
        cp "$ci_env" "${DATA_MOUNT}/openclaw/.env"
        chmod 600 "${DATA_MOUNT}/openclaw/.env"
        log "Placed secrets on data disk"
    fi

    # Configure openclaw.json from .env values
    configure_model
    configure_telegram_policy

    # Set VNC password from VM_PASSWORD in .env (single password for SSH + VNC)
    local vnc_pass=""
    vnc_pass=$(grep -E '^VM_PASSWORD=' "${DATA_MOUNT}/openclaw/.env" 2>/dev/null | cut -d= -f2- | xargs) || true
    if [[ -z "$vnc_pass" ]]; then
        # Fallback: generate a random password if VM_PASSWORD not in .env
        vnc_pass=$(dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -dc 'A-Za-z0-9' | cut -c1-16)
        log "No VM_PASSWORD in .env -- generated random VNC password"
    fi
    echo "$vnc_pass" > "${DATA_MOUNT}/vnc-password.txt"
    chmod 600 "${DATA_MOUNT}/vnc-password.txt"
    x11vnc -storepasswd "$vnc_pass" /etc/x11vnc.pass 2>/dev/null
    chmod 600 /etc/x11vnc.pass
    log "VNC password set"

    # Set initial update version
    echo "001" > "${DATA_MOUNT}/update-version.txt"

    touch "$MARKER_FILE"
    log "First-boot seeding complete"
}

configure_model() {
    local env_file="${DATA_MOUNT}/openclaw/.env"
    local config_file="${DATA_MOUNT}/openclaw/openclaw.json"

    [[ -f "$config_file" ]] || return 0
    [[ -f "$env_file" ]] || return 0

    local model=""
    model=$(grep -E '^OPENCLAW_MODEL=' "$env_file" 2>/dev/null | cut -d= -f2- | xargs) || true

    if [[ -n "$model" ]]; then
        local tmp
        tmp=$(mktemp)
        jq --arg m "$model" '.agents.defaults.model.primary = $m' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
        log "Model set to $model"
    fi
}

configure_telegram_policy() {
    local env_file="${DATA_MOUNT}/openclaw/.env"
    local config_file="${DATA_MOUNT}/openclaw/openclaw.json"

    [[ -f "$config_file" ]] || return 0
    [[ -f "$env_file" ]] || return 0

    # Source the env file to get TELEGRAM_USER_ID
    local telegram_user_id=""
    telegram_user_id=$(grep -E '^TELEGRAM_USER_ID=' "$env_file" | cut -d= -f2- | xargs) || true

    if [[ -n "$telegram_user_id" ]]; then
        # Allowlist mode
        local tmp
        tmp=$(mktemp)
        jq --arg uid "$telegram_user_id" '
            .channels.telegram.dmPolicy = "allowlist" |
            .channels.telegram.allowFrom = [$uid]
        ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
        log "Telegram policy: allowlist for user $telegram_user_id"
    else
        # Open mode
        local tmp
        tmp=$(mktemp)
        jq '
            .channels.telegram.dmPolicy = "open" |
            .channels.telegram.allowFrom = ["*"]
        ' "$config_file" > "$tmp" && mv "$tmp" "$config_file"
        log "Telegram policy: open"
    fi
}

# =============================================================================
# 3. Every-boot tasks
# =============================================================================

setup_symlinks() {
    # Use bind mounts for .openclaw and workspace (exec tool rejects symlinks).
    # vnc-password.txt stays as a symlink (not traversed by exec).
    for pair in "openclaw:.openclaw" "workspace:workspace"; do
        local src="${DATA_MOUNT}/${pair%%:*}"
        local dst="${HOME_DIR}/${pair##*:}"
        # Unmount if already mounted, remove stale symlink/dir
        mountpoint -q "$dst" 2>/dev/null && umount "$dst"
        rm -rf "$dst"
        mkdir -p "$dst"
        mount --bind "$src" "$dst"
        # Persist in fstab
        if ! grep -q "$dst" /etc/fstab 2>/dev/null; then
            echo "$src $dst none bind 0 0" >> /etc/fstab
        fi
    done

    ln -sfn "${DATA_MOUNT}/vnc-password.txt" "${HOME_DIR}/vnc-password.txt"

    # Recreate .xsession (removed by waagent deprovision)
    echo "xfce4-session" > "${HOME_DIR}/.xsession"
    chmod 644 "${HOME_DIR}/.xsession"

    # Ensure node compile cache exists (openclaw doctor recommendation)
    mkdir -p /var/tmp/openclaw-compile-cache

    log "Symlinks and .xsession created"
}

fix_permissions() {
    chown -R "${ADMIN_USER}:${ADMIN_USER}" "${DATA_MOUNT}"
    chown -h "${ADMIN_USER}:${ADMIN_USER}" \
        "${HOME_DIR}/.openclaw" \
        "${HOME_DIR}/workspace" \
        "${HOME_DIR}/vnc-password.txt" \
        "${HOME_DIR}/.xsession" 2>/dev/null || true
    chown "${ADMIN_USER}:${ADMIN_USER}" "${HOME_DIR}"
    log "Permissions fixed"
}

sync_vnc_password() {
    # Ensure /etc/x11vnc.pass matches the data disk's VNC password
    local vnc_file="${DATA_MOUNT}/vnc-password.txt"
    if [[ -f "$vnc_file" ]]; then
        local pass
        pass=$(cat "$vnc_file")
        x11vnc -storepasswd "$pass" /etc/x11vnc.pass 2>/dev/null
        chmod 600 /etc/x11vnc.pass
        log "Synced VNC password from data disk"
    fi
}

setup_tailscale() {
    local env_file="${DATA_MOUNT}/openclaw/.env"
    local ts_key=""
    ts_key=$(grep -E '^TAILSCALE_AUTHKEY=' "$env_file" 2>/dev/null | cut -d= -f2- | xargs) || true

    if [[ -n "$ts_key" ]] && command -v tailscale >/dev/null 2>&1; then
        if ! tailscale status &>/dev/null; then
            log "Joining tailnet..."
            tailscale up --authkey "$ts_key" --hostname "$(hostname)" --accept-routes 2>/dev/null || true
            log "Tailscale joined"
        else
            log "Tailscale already connected"
        fi
    fi
}

run_updates() {
    if [[ -x /opt/claw/run-updates.sh ]]; then
        /opt/claw/run-updates.sh
    fi
}

start_services() {
    # Display stack -- lightdm should already be running from systemd
    systemctl restart lightdm 2>/dev/null || true

    # Wait for X11 socket
    local tries=0
    while [[ ! -S /tmp/.X11-unix/X0 ]] && (( tries < 60 )); do
        sleep 1
        (( tries++ ))
    done

    if [[ -S /tmp/.X11-unix/X0 ]]; then
        log "X11 display :0 ready"
    else
        log "WARNING: X11 display :0 not ready after 60s"
    fi

    # VNC
    systemctl restart x11vnc 2>/dev/null || true

    # OpenClaw gateway
    systemctl restart openclaw-gateway 2>/dev/null || true

    # PhantomTouch relay (phone automation bridge)
    if [[ -f /etc/systemd/system/phantom-relay.service ]]; then
        systemctl restart phantom-relay 2>/dev/null || true
    fi

    # Claude Code remote-control (if start-claude.sh exists)
    if [[ -x /opt/claw/start-claude.sh ]]; then
        sudo -u "${ADMIN_USER}" /opt/claw/start-claude.sh || true
    fi

    log "Services started"
}

# =============================================================================
# Main
# =============================================================================

log "=== Boot script starting ==="
mount_data_disk
seed_new_disk
setup_symlinks
fix_permissions
sync_vnc_password
setup_tailscale
run_updates
start_services
log "=== Boot script complete ==="
