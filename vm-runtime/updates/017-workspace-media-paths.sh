#!/usr/bin/env bash
# 017-workspace-media-paths.sh -- teach the OpenClaw/Claude Code agent about
# the hardcoded media-root allowlist (source: openclaw dist/local-roots-*.js
# buildMediaLocalRoots). Writing to plain /tmp/ yields "Outside allowed
# folders" in the chat UI.
#
# Fix: refresh the three workspace docs, and bind-mount /tmp onto
# /mnt/claw-data/workspace/tmp so any /tmp/* path is simultaneously
# addressable via an allowed root. Bind mount (not symlink) so the server's
# fs.realpath() check also passes.
#
# Boot.sh calls setup_tmp_passthrough() every boot; this update handles the
# one-time swap on already-running VMs (including replacing the earlier
# symlink prototype).
#
# Runs as root via run-updates.sh.
set -euo pipefail

DEFAULTS="/opt/claw/defaults/workspace"
WS="/mnt/claw-data/workspace"
TMP_BIND="$WS/tmp"
TAG="[update-017]"

# 1. Refresh workspace docs.
for f in AGENTS.md TOOLS.md CLAUDE.md; do
    if [ -f "$DEFAULTS/$f" ]; then
        cp "$DEFAULTS/$f" "$WS/$f"
        chown azureuser:azureuser "$WS/$f"
        echo "$TAG refreshed $WS/$f"
    fi
done

# 2. Swap symlink -> bind mount for /tmp passthrough.
if [ -L "$TMP_BIND" ]; then
    rm -f "$TMP_BIND"
    echo "$TAG removed legacy symlink at $TMP_BIND"
fi
if [ -d "$TMP_BIND" ] && ! mountpoint -q "$TMP_BIND"; then
    # Only rmdir if empty; don't clobber user data.
    rmdir "$TMP_BIND" 2>/dev/null || echo "$TAG WARNING: $TMP_BIND is non-empty; leaving contents in place"
fi
if [ ! -d "$TMP_BIND" ]; then
    mkdir -p "$TMP_BIND"
    chown azureuser:azureuser "$TMP_BIND"
fi
if ! mountpoint -q "$TMP_BIND"; then
    mount --bind /tmp "$TMP_BIND"
    echo "$TAG bind-mounted /tmp at $TMP_BIND"
else
    echo "$TAG $TMP_BIND already bind-mounted"
fi

# 3. Persist in fstab so reboots replay automatically.
if ! grep -qE "^/tmp[[:space:]]+$TMP_BIND[[:space:]]" /etc/fstab 2>/dev/null; then
    echo "/tmp $TMP_BIND none bind 0 0" >> /etc/fstab
    echo "$TAG added fstab entry for $TMP_BIND"
fi

# 4. Ensure /tmp/openclaw (preferred tmp dir) exists with correct perms.
if [ ! -d /tmp/openclaw ]; then
    install -d -m 0700 -o azureuser -g azureuser /tmp/openclaw
    echo "$TAG created /tmp/openclaw (0700 azureuser)"
fi
