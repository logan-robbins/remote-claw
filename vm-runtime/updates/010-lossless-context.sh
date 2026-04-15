#!/usr/bin/env bash
# 010-lossless-context.sh -- install lossless-claw context engine plugin

if ! sudo -u azureuser openclaw plugins list 2>/dev/null | grep -q "lossless-claw"; then
    sudo -u azureuser openclaw plugins install @martian-engineering/lossless-claw 2>/dev/null || true
    echo "[update-010] Installed lossless-claw context engine"
else
    echo "[update-010] lossless-claw already installed"
fi
