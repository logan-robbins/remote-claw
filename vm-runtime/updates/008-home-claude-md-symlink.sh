#!/usr/bin/env bash
# 008-home-claude-md-symlink.sh -- move ~/CLAUDE.md onto the data disk and
# symlink ~/CLAUDE.md to it, so it survives VM replacements (image upgrades).
#
# Canonical location: /mnt/claw-data/workspace/CLAUDE.md (accessible via
# ~/workspace/CLAUDE.md through the existing bind mount).
#
# Idempotent: safe to run on fresh claws (target seeded via defaults), existing
# claws (regular file at ~/CLAUDE.md), and claws where the link already exists.

HOME_DIR="/home/azureuser"
HOME_FILE="$HOME_DIR/CLAUDE.md"
TARGET="$HOME_DIR/workspace/CLAUDE.md"
DEFAULT_SRC="/opt/claw/defaults/workspace/CLAUDE.md"

# Workspace bind mount must be in place (boot.sh sets this up before run-updates.sh)
if ! mountpoint -q "$HOME_DIR/workspace"; then
    echo "[update-011] ~/workspace is not a mountpoint yet -- skipping"
    exit 0
fi

# Already the right symlink? Done.
if [[ -L "$HOME_FILE" && "$(readlink "$HOME_FILE")" == "$TARGET" ]]; then
    echo "[update-011] $HOME_FILE already linked to $TARGET"
    exit 0
fi

# Ensure the data-disk target exists, preferring (in order):
#   1. existing target on disk
#   2. existing home regular file (migration)
#   3. default shipped with the image
if [[ ! -f "$TARGET" ]]; then
    if [[ -f "$HOME_FILE" && ! -L "$HOME_FILE" ]]; then
        cp -a "$HOME_FILE" "$TARGET"
        echo "[update-011] Migrated $HOME_FILE -> $TARGET"
    elif [[ -f "$DEFAULT_SRC" ]]; then
        cp -a "$DEFAULT_SRC" "$TARGET"
        echo "[update-011] Seeded $TARGET from defaults"
    else
        echo "[update-011] No source file found -- nothing to link"
        exit 0
    fi
    chown azureuser:azureuser "$TARGET"
fi

# If home still has a regular file, reconcile with the data-disk copy
if [[ -f "$HOME_FILE" && ! -L "$HOME_FILE" ]]; then
    if cmp -s "$HOME_FILE" "$TARGET"; then
        rm -f "$HOME_FILE"
    else
        backup="$HOME_FILE.pre-symlink.$(date -u +%Y%m%d%H%M%S).bak"
        mv "$HOME_FILE" "$backup"
        chown azureuser:azureuser "$backup"
        echo "[update-011] Home copy differed -- backed up to $backup; data-disk copy wins"
    fi
fi

# Remove any stale symlink (pointing somewhere wrong) before recreating
[[ -L "$HOME_FILE" ]] && rm -f "$HOME_FILE"

ln -s "$TARGET" "$HOME_FILE"
chown -h azureuser:azureuser "$HOME_FILE"
echo "[update-011] Linked $HOME_FILE -> $TARGET"
