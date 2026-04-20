#!/usr/bin/env bash
# 015-chrome-unify-launchers-no-keyring.sh -- stop the "Unlock Keyring"
# prompt on Chrome launch, for good this time.
#
# Update 012 installed /usr/local/bin/google-chrome-stable as a wrapper
# that prepends --password-store=basic, and patched
# /usr/share/applications/google-chrome.desktop. What it missed:
#   - /usr/share/applications/com.google.Chrome.desktop (Chrome installs
#     this too; still pointed at the apt binary)
#   - /home/azureuser/Desktop/Chrome.desktop (the XFCE desktop icon the
#     operator actually clicks from a Moonlight session)
#   - gnome-keyring-daemon itself was still autostarted by XFCE. Even
#     with --password-store=basic, Chrome does libsecret probes for
#     sync/autofill/enterprise and XFCE apps poke it too, so the
#     "Unlock Keyring" dialog returned the moment anything asked.
#
# This update:
#   1. Rewrites every known Chrome .desktop launcher to route through
#      the wrapper.
#   2. Drops user-scoped autostart overrides so the three gnome-keyring
#      .desktop entries in /etc/xdg/autostart are Hidden in this session.
#   3. Kills the currently-running gnome-keyring-daemon and deletes the
#      stale Default_keyring (nothing was stored there).
#
# Idempotent. Safe on fresh data disks and existing ones.
set -euo pipefail

WRAPPER=/usr/local/bin/google-chrome-stable
APT_BIN=/usr/bin/google-chrome-stable

# 1. Patch every known Chrome launcher. sed is idempotent because once
#    the wrapper path is in the file, the pattern no longer matches.
for f in \
    /usr/share/applications/google-chrome.desktop \
    /usr/share/applications/com.google.Chrome.desktop \
    /home/azureuser/Desktop/Chrome.desktop; do
    [[ -f "$f" ]] || continue
    if grep -q "$APT_BIN" "$f"; then
        sed -i.bak "s|$APT_BIN|$WRAPPER|g" "$f"
        echo "[update-015] patched Exec paths in $f"
    else
        echo "[update-015] $f already routes via wrapper"
    fi
done

# 2. Disable gnome-keyring autostart for azureuser. XDG autostart lookup
#    prefers ~/.config/autostart over /etc/xdg/autostart when filenames
#    match; a file with Hidden=true + X-GNOME-Autostart-enabled=false
#    effectively shadows the system entry for this user.
AUTOSTART_DIR=/home/azureuser/.config/autostart
install -d -o azureuser -g azureuser -m 0755 "$AUTOSTART_DIR"
for name in pkcs11 secrets ssh; do
    override="$AUTOSTART_DIR/gnome-keyring-$name.desktop"
    cat > "$override" <<EOF
[Desktop Entry]
Type=Application
Name=gnome-keyring-$name (disabled)
Hidden=true
NoDisplay=true
X-GNOME-Autostart-enabled=false
EOF
    chown azureuser:azureuser "$override"
done
echo "[update-015] disabled gnome-keyring autostart (pkcs11/secrets/ssh)"

# 3. Kill the currently-running daemon and clear the stored keyring so
#    nothing locked is sitting around waiting for a password. (Nothing
#    of value is stored here -- Chrome is on --password-store=basic,
#    Sunshine keeps its password in /etc/sunshine state, and the
#    VM_PASSWORD source of truth lives in the data disk.)
pkill -u azureuser -f gnome-keyring-daemon 2>/dev/null || true
rm -rf /home/azureuser/.local/share/keyrings 2>/dev/null || true
install -d -o azureuser -g azureuser -m 0700 /home/azureuser/.local/share
echo "[update-015] killed gnome-keyring-daemon and cleared ~/.local/share/keyrings"

# 4. If Chrome is currently running via the old path, kill so the next
#    launch goes through the wrapper. The agent relaunches it on demand.
if pgrep -f "$APT_BIN" >/dev/null 2>&1; then
    pkill -f "$APT_BIN" || true
    echo "[update-015] killed stale Chrome processes on the apt path"
fi
