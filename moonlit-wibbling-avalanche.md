# Plan: Image-based deploys with detachable data disks

## Context

We have a fully configured OpenClaw VM (deallocated) with all plugins and skills installed. The user wants to turn this into a reusable deployment system where:

1. The VM image is the **system layer** — OS, desktop, OpenClaw, Chrome, Claude Code, tools
2. Each claw's identity/state lives on a **detachable Azure managed disk** that survives VM upgrades
3. New claws deploy by: image + new data disk + .env secrets
4. Upgrades work by: detach data disk → deploy new VM from new image → reattach data disk → run update scripts
5. Two interaction channels: **Telegram** (OpenClaw gateway) and **Claude Code** (SSH remote)

---

## Architecture

### IMAGE (OS disk, baked, versioned) — "the system"

Everything that's the same across all claws:

- Ubuntu 24.04 + xfce4 + lightdm + x11vnc + dummy Xorg
- Node.js 24 + npm, OpenClaw (global), Google Chrome, tmux
- Claude Code CLI (`npm install -g @anthropic-ai/claude-code`), start-claude.sh helper
- System tools (xdotool, wmctrl, scrot, xclip, jq, git, build-essential)
- Systemd units: lightdm, x11vnc, openclaw-gateway
- System config: autologin, viewonly VNC, passwordless sudo, screen blanking disabled, ufw disabled
- Boot script at `/opt/claw/boot.sh` — runs on every boot, handles data disk mount + service start
- Default config templates at `/opt/claw/defaults/` — used for first-time claw initialization
- Update scripts at `/opt/claw/updates/NNN-description.sh` — versioned migrations

### DATA DISK (per-claw, persistent, detachable) — "the claw"

Everything unique to a specific claw instance. Mounted at `/mnt/claw-data`:

```
/mnt/claw-data/
  openclaw/            → symlinked to ~/.openclaw
    openclaw.json        (full config with plugins, memory, channels)
    exec-approvals.json
    SOUL.md
    extensions/          (lossless-claw, ClawNet — per-claw plugin installs)
    memory/              (main.sqlite)
    lcm.db               (lossless-claw context DB)
    telegram/            (bot session state)
    ...
  workspace/           → symlinked to ~/workspace
    skills/              (clawsec-suite, qmd-memory)
    AGENTS.md, SOUL.md, TOOLS.md, etc.
    state/
  env                  → symlinked to ~/.env (API keys, bot token)
  vnc-password.txt     → symlinked to ~/vnc-password.txt
  update-version.txt   → last applied update number (e.g. "003")
```

### Boot script (`/opt/claw/boot.sh`) — runs at every VM start

```
1. Find Azure data disk (by LUN or label)
2. Mount to /mnt/claw-data (create filesystem if raw/new disk)
3. If /mnt/claw-data is empty (new claw):
   a. Copy /opt/claw/defaults/ into /mnt/claw-data/ (includes pre-configured
      openclaw.json, exec-approvals.json, SOUL.md, pre-installed plugins
      [ClawNet, lossless-claw] and skills [clawsec-suite, qmd-memory])
   b. Write .env from cloud-init custom-data vars (/opt/claw/env-inject)
   c. Generate VNC password
   d. Render openclaw.json telegram section from .env vars (bot token, user ID)
   e. Write update-version.txt = latest
4. Create symlinks: ~/.openclaw → /mnt/claw-data/openclaw, etc.
5. Fix ownership: chown -R azureuser:azureuser /mnt/claw-data
6. Generate x11vnc password file from data disk's vnc-password.txt
7. Start/restart services: lightdm, x11vnc, openclaw-gateway
```

### Slim cloud-init (`cloud-init-slim.yaml`) — for image-based deploys

Only writes secrets and triggers boot script. No packages, no installs:

```yaml
#cloud-config
write_files:
  - path: /opt/claw/env-inject
    permissions: "0600"
    content: |
      XAI_API_KEY=${XAI_API_KEY}
      OPENAI_API_KEY=${OPENAI_API_KEY}
      ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}
      BRIGHTDATA_API_TOKEN=${BRIGHTDATA_API_TOKEN}
      TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN}
      TELEGRAM_USER_ID=${TELEGRAM_USER_ID}

runcmd:
  - chown azureuser:azureuser /home/azureuser
  - /opt/claw/boot.sh
```

---

## deploy.sh modes

### `./deploy.sh` (default — from image)

The primary deploy path once an image exists:

```
IMAGE=${IMAGE:-claw-base-v1} VM_NAME=alice ./deploy.sh
```

1. Load .env, select SSH key
2. `ensure_shared_infra()` (RG, VNet, NSG — idempotent)
3. Create data disk `${VM_NAME}-data` if it doesn't exist (or use existing `DATA_DISK=name`)
4. Create VM from `$IMAGE` with slim cloud-init
5. Attach data disk
6. Wait for SSH + VNC password
7. Write .vm-state

### `./deploy.sh scratch`

Full from-scratch deploy on stock Ubuntu (current behavior). Keeps working as the reproducibility fallback. Uses `cloud-init.yaml` (the full one). Also installs boot.sh and defaults so the VM can be baked afterward.

### `./deploy.sh bake [IMAGE_NAME]`

Captures the current VM as a reusable image:

1. SSH in → wipe runtime state (memory DBs, sessions, logs, telegram state)
2. SSH in → `sudo waagent -deprovision+user -force`
3. `az vm deallocate`
4. `az vm generalize`
5. `az image create --name ${IMAGE_NAME:-claw-base-v$(date +%Y%m%d)}`

### `./deploy.sh upgrade VM_NAME [--image IMAGE_NAME]`

Upgrade a claw to a new system image while preserving its data:

1. Deallocate VM
2. Detach data disk (record disk name)
3. Delete VM (keeps data disk and public IP)
4. Deploy new VM from new image
5. Attach data disk
6. Print: "Run update scripts if needed"

---

## New files

| File | Purpose |
|---|---|
| `cloud-init-slim.yaml` | Minimal cloud-init for image deploys (just secrets + boot trigger) |
| `boot.sh` | Boot-time script baked into image at `/opt/claw/boot.sh` |
| `defaults/` | Full pre-configured claw data: openclaw.json (with plugins, memory, QMD, lossless-claw), exec-approvals.json, SOUL.md, extensions/ (ClawNet, lossless-claw pre-installed), workspace/skills/ (clawsec-suite, qmd-memory). Copied to data disk on first boot. Telegram section rendered from .env at init time. |
| `updates/001-initial.sh` | First update script (no-op, establishes baseline) |

## Modified files

| File | Changes |
|---|---|
| `deploy.sh` | Add `scratch`, `bake`, `upgrade` subcommands; default mode uses image |
| `cloud-init.yaml` | Add Claude Code install, boot.sh install, defaults copy |
| `.env.template` | Add `ANTHROPIC_API_KEY` (note: only for Claude Code SDK/headless use; remote-control uses OAuth) |

---

## Claude Code integration

**`claude remote-control`** (v2.1.51+) is how this works. It makes outbound HTTPS calls to Anthropic's API and polls for work — zero inbound ports needed. The claude.ai/code web UI, iOS app, and Android app can all connect to a running remote-control session.

**Constraints:**
- Requires **OAuth auth** (Claude Pro/Max/Team/Enterprise), not API keys
- Requires a **TTY** — cannot be daemonized as a systemd service (GitHub #30447 requests this)
- Workaround: **tmux** session

**What we bake into the image:**
- `npm install -g @anthropic-ai/claude-code`
- `tmux` package
- Helper script `/opt/claw/start-claude.sh`:
  ```bash
  #!/bin/bash
  tmux new-session -d -s claude "claude remote-control --name '$(hostname)'"
  ```

**First-time setup (one-time, per claw):**
1. SSH into the VM
2. Run `claude auth login` (interactive OAuth flow)
3. Run `/opt/claw/start-claude.sh`
4. Claude Code session appears in claude.ai/code with green dot

**On subsequent boots:**
- boot.sh starts the tmux/claude session automatically (after data disk mount)
- User opens claude.ai/code or the mobile app to connect

Has full filesystem + root access (passwordless sudo already configured). Can update OpenClaw config, run update scripts, modify SOUL.md — anything.

---

## Upgrade flow (concrete example)

```
# You updated the image (added Codex, updated Chrome, etc.)
# Claw "alice" is running on claw-base-v1, needs to move to claw-base-v2

./deploy.sh upgrade alice --image claw-base-v2

# Behind the scenes:
# 1. az vm deallocate -g rg-linux-desktop -n alice
# 2. az vm disk detach -g rg-linux-desktop --vm-name alice --name alice-data
# 3. az vm delete -g rg-linux-desktop -n alice --yes
# 4. az vm create ... --image claw-base-v2 (slim cloud-init, same VNet/NSG)
# 5. az vm disk attach -g rg-linux-desktop --vm-name alice --name alice-data --lun 0
# 6. Boot script mounts data disk, symlinks, starts services
# 7. User tells claw or claude code: "run updates" → executes pending update scripts
```

---

## Verification

1. `./deploy.sh bake claw-base-v1` — creates image from current deallocated VM
2. `VM_NAME=test-claw ./deploy.sh` — deploys from image with new data disk
3. Verify: SSH in, services active, send Telegram message, Claude Code works
4. `./deploy.sh upgrade test-claw --image claw-base-v1` — test upgrade cycle
5. Verify: data preserved, services active, same claw identity
