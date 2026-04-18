#!/usr/bin/env bash
# 001-skills-dirs.sh -- create skills directories on existing data disks
mkdir -p /mnt/claw-data/openclaw/skills /mnt/claw-data/workspace/skills
chown azureuser:azureuser /mnt/claw-data/openclaw/skills /mnt/claw-data/workspace/skills
echo "[update-003] Created skills directories"
