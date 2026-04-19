# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

OpenClawps: MLOps-style CI/CD for OpenClaw agent fleets on Azure. The repo builds a versioned baseline image, deploys VMs from it, and upgrades those VMs without losing per-agent state. Two deployment paths coexist: **Terraform (preferred, declarative fleet state)** and **shell (`bin/deploy.sh`, used for scratch installs and legacy image baking)**.

The canonical fleet manifest is `fleet/claws.yaml`. Today the fleet is a single claw (`chad-claw`) in resource group `rg-claw-westus` on AMD V710 GPU VMs in westus. Both Terraform roots read `claws.yaml` as the source of truth.

## The three-layer model (critical to internalize)

Every change must land in exactly **one** layer. Confusing the layers is the #1 source of breakage. In particular, **do not reach for Packer** when the change belongs in cloud-init — a bake is expensive (~30 min, fresh VM) and the baseline is deliberately kept small and stable.

1. **Immutable baseline image** — `claw-desktop-gpu` in gallery `clawGalleryWest`, baked by Packer from the AMD V710 marketplace Ubuntu base. Contents: XFCE + LightDM + dummy Xorg + xrdp + Sunshine. That's it. Re-bake **only** when the OS, GPU driver, or remote-desktop/streaming stack changes. Source: `infra/azure/packer/desktop/claw-desktop.pkr.hcl` + `vm-runtime/install/desktop/*.sh`.
2. **App install layer** — runs at `terraform apply` time on every fleet deploy via the cloud-init template. Installs Node.js + OpenClaw, Chrome, Claude Code, Tailscale, system setup, and OpenClaw services. Also stages the `vm-runtime/` payload into `/opt/claw/`. This is where iteration happens: edit scripts, `terraform apply`, get a new VM in ~2 min, no re-bake. Source: `vm-runtime/install/os/NN-*.sh` invoked from the fleet cloud-init template.
3. **Data disk** — `/mnt/claw-data`, attached at LUN 0, `prevent_destroy = true`. Holds per-claw identity: secrets (`.env`), workspace, memory (`~/.openclaw` including `lcm.db`), Telegram state, SSH/VNC/RDP/Sunshine password, and `update-version.txt`. `~/.openclaw` and `~/workspace` are bind mounts onto this disk. Survives every VM replacement.

Upgrades destroy the VM, create a new one from the current image + re-run cloud-init, and reattach the same data disk. Anything the first two layers provide must be reconstructable on every boot; anything that must persist lives on the data disk.

**Decision rule**: new package or service → app install layer (cloud-init). Touch the Packer baseline only when the OS, kernel, GPU driver, or desktop/remote-protocol stack changes.

**Baseline bake workflow**: the `infra/azure/terraform/baseline/` root is a separate single-VM root that stands up a `baseline-desktop` VM in `rg-linux-gpu-westus` to validate Packer inputs and develop the desktop layer interactively. It is **not** part of the fleet deploy path and is not referenced by `claws.yaml`. Use `shared/` for the gallery and `fleet/` for claws.

## Boot and upgrade lifecycle

Every VM start runs `/opt/claw/boot.sh` (staged from `vm-runtime/lifecycle/boot.sh`). It must stay idempotent. Order:

1. Discover and mount the data disk at LUN 0 (`/dev/disk/azure/scsi1/lun0`), waiting up to 60s for Terraform attachment.
2. First-boot seed from `/opt/claw/defaults/` onto the empty disk.
3. Restore bind mounts (`~/.openclaw`, `~/workspace`), fix permissions, sync VNC password.
4. Join Tailscale if `TAILSCALE_AUTHKEY` is set.
5. `run-updates.sh` applies any `vm-runtime/updates/NNN-*.sh` script whose number exceeds `/mnt/claw-data/update-version.txt`, then advances the marker.
6. Start services (lightdm, x11vnc, gateway, Claude Code).

**Adding a migration**: create `vm-runtime/updates/NNN-short-name.sh` with the next number. Must be idempotent (boot.sh may rerun it in rare retry paths) and safe on both fresh and long-lived disks — users on every prior version will eventually run it. Scripts run as **root** under `run-updates.sh`; use `sudo -u azureuser` for user-scoped tooling (e.g. `openclaw` CLI) and `chown azureuser:azureuser` on any files you create under the user's home or on the data disk.

## Common commands

Shell deploy path (from repo root):

```bash
./bin/deploy.sh                       # deploy from golden image (default mode)
./bin/deploy.sh scratch               # stock Ubuntu → full install
./bin/deploy.sh bake 4.0.0            # capture running VM into the gallery
./bin/deploy.sh upgrade alice --image 4.0.0
```

Terraform (three separate roots, three separate states — `baseline/` for bake-dev, `shared/` for RG+gallery, `fleet/` for the claws):

```bash
# Shared (run once): RG, VNet, NSG, Compute Gallery, image definition
cd infra/azure/terraform/shared
terraform init -reconfigure -backend-config=backend.tfbackend
terraform apply -var-file=terraform.tfvars

# Fleet (day-to-day): per-claw VM, NIC, public IP, data disk
cd infra/azure/terraform/fleet
terraform init -reconfigure -backend-config=backend.tfbackend
terraform plan  -var-file=terraform.tfvars -var-file=secrets.auto.tfvars
terraform apply -var-file=terraform.tfvars -var-file=secrets.auto.tfvars
```

Validate without a backend (what CI runs):

```bash
terraform fmt -check -recursive                                    # from infra/azure/terraform
cd infra/azure/terraform/shared && terraform init -backend=false && terraform validate
cd infra/azure/terraform/fleet  && terraform init -backend=false && terraform validate
cd infra/azure/packer && packer init . && packer validate .
```

Packer image build (bakes the **baseline** only — desktop layer on top of the AMD V710 marketplace base):

```bash
cd infra/azure/packer/desktop
packer init .
packer build -var subscription_id=$(az account show --query id -o tsv) -var image_version=1.1.0 .
```

On a running VM (either via SSH or the deploy/upgrade tail): `/opt/claw/verify.sh` runs the 33+ point health check.

Topology site (isolated Vite/React app, unrelated to VM runtime):

```bash
cd apps/topology
npm run dev        # vite
npm run build
```

## Fast state check (az cli)

When you walk into a new session and need to know what's running **before** touching any code or Terraform, run these first. Resource group is always `rg-claw-westus` for the fleet.

```bash
# All claws + power state in one table (running / deallocated / stopped)
az vm list -g rg-claw-westus -d -o table

# One claw (use this before SSH / before any az vm start|deallocate)
az vm get-instance-view -g rg-claw-westus -n chad-claw \
  --query "instanceView.statuses[?starts_with(code,'PowerState/')].code | [0]" -o tsv

# Public IP (static — survives deallocate)
az vm list-ip-addresses -g rg-claw-westus -n chad-claw -o table

# Data disks (verify prevent_destroy state, confirm nothing is orphaned)
az disk list -g rg-claw-westus -o table

# Gallery image versions (what's available to deploy from)
az sig image-version list -g rg-claw-westus \
  --gallery-name clawGalleryWest --gallery-image-definition claw-desktop-gpu -o table
```

Stop / resume compute billing without losing state:

```bash
az vm deallocate -g rg-claw-westus -n chad-claw   # stop billing (keeps disks, IP, identity)
az vm start      -g rg-claw-westus -n chad-claw   # resume; boot.sh replays idempotently
```

**`deallocate` vs `stop`**: always use `deallocate` to pause billing. `az vm stop` shuts down the guest OS but the compute is still reserved and billed. A deallocated VM is what the user wants when they say "turn it off for the night."

After `az vm start`, allow ~30–60 s for the chat UI to come back: cloud-init does not re-run (it ran once at creation), but `boot.sh` + `run-updates.sh` replay on every start, then the gateway needs its ~11–12 s startup grace.

## Passwords, keys, and access modes

All access credentials for a claw live in **one** authoritative place: Terraform state on the operator's machine. Per-VM the same password is used for SSH, RDP, and the Sunshine web UI admin.

```bash
# Get the password for a claw (from the fleet root)
cd infra/azure/terraform/fleet
terraform output -json claw_vm_passwords | jq -r '.["chad-claw"]'

# Map of { claw_name: ip }
terraform output -json claw_public_ips
```

On the VM, the password also lives on the data disk at `/mnt/claw-data/vnc-password.txt` (mode 0600, symlinked to `~/vnc-password.txt`). Sunshine's admin password is seeded from this file by `vm-runtime/updates/010-sunshine-config.sh`. Regenerating the password means updating that file **and** re-running the Sunshine seed, not just changing Terraform state.

API keys and the Tailscale auth key come from `infra/azure/terraform/fleet/secrets.auto.tfvars` (gitignored), flow into the VM via cloud-init, and land in `/mnt/claw-data/openclaw/.env`. CI reads the same secrets from the `CLAW_SECRETS_JSON` GitHub secret.

Access modes (in rough order of preference):

| Mode | Port | Notes |
|---|---|---|
| **Tailscale Serve → chat UI** | 443 (tailnet) | `https://<magicdns-name>/` — primary way to talk to the agent. Requires Tailscale Serve enabled once at tailnet level (see below). |
| **SSH tunnel → chat UI** | local 18789 | `ssh -L 18789:127.0.0.1:18789 azureuser@<ip>` → `http://localhost:18789/`. Zero-config fallback when Serve isn't available. |
| **SSH** | 22/tcp | `ssh azureuser@<ip>` (key auth if your pubkey matches `admin_ssh_public_key`; password also accepted). |
| **RDP** | 3389/tcp | Microsoft Remote Desktop / FreeRDP. Spawns a **new** per-connection X session (`:10+`) — you don't see the agent's desktop. Use Moonlight to share the agent's session. |
| **Sunshine / Moonlight** | 47984/47989/47990/48010 tcp + 47998-48002 udp | Low-latency GPU-accelerated streaming. Admin UI: `https://<ip>:47990`. Captures `:0` — the **same** display the agent runs on, so you see the agent's Chrome and share its browser profile. This is the intended "observe and assist" path. |

**Fleet NSG inbound rules** (`rg-claw-westus-nsg`, set by `shared-infra` module): SSH 22, RDP 3389, Sunshine TCP `47984/47989/47990/48010`, Sunshine UDP `47998-48002`, Tailscale direct UDP `41641`. Azure's implicit `DenyAll` at priority 65500 closes everything else. **VNC port 5900 is not open** — the data disk still carries a `vnc-password.txt` because Sunshine's admin password is seeded from it, but x11vnc itself isn't running. Add an explicit rule + start `x11vnc` if you need it.

## Where things live

- `bin/deploy.sh` — thin wrapper over `infra/azure/shell/deploy.sh` (legacy scratch/bake/upgrade flow).
- `vm-runtime/` — the VM payload. Fleet cloud-init runs `install/os/*.sh` at deploy time and stages this tree into `/opt/claw/`; Packer runs `install/desktop/*.sh` at bake time. All three entrypoints (Packer, fleet cloud-init, legacy shell) read from this tree, so keep them consistent.
  - `install/desktop/` — **baseline image only.** Baked once by Packer: `01-system-packages`, `03-display-config`, `04-xrdp`, `05-sunshine`.
  - `install/os/` — **every fleet deploy.** Run by cloud-init on each new VM: `01-nodejs-openclaw`, `02-chrome`, `03-claude-code`, `04-tailscale`, `05-system-setup`, `06-openclaw-services`.
  - `cloud-init/` — cloud-init templates (legacy `scratch.yaml`, slim `image.yaml`). The fleet Terraform module has its own cloud-init template that orchestrates the `install/os/` scripts.
  - `lifecycle/` — `boot.sh`, `run-updates.sh`, `verify.sh`, `start-claude.sh`. Staged into `/opt/claw/` and invoked on every VM start.
  - `defaults/` — seeded onto a fresh data disk on first boot (config, workspace).
  - `updates/NNN-*.sh` — numbered, version-gated migrations replayed on every start; advance `update-version.txt` on success.
- `infra/azure/shell/` — Azure CLI implementation for scratch/bake/upgrade (legacy).
- `infra/azure/terraform/` — three Terraform roots, three separate states:
  - `baseline/` — standalone single-VM root (`baseline-desktop` in `rg-linux-gpu-westus`) used for developing the desktop layer interactively before baking. Not part of the fleet path.
  - `shared/` — run once: RG `rg-claw-westus`, VNet, NSG, Compute Gallery `clawGalleryWest`, image definition `claw-desktop-gpu`.
  - `fleet/` — day-to-day: per-claw VM, NIC, public IP, data disk, cloud-init app install.
  - `modules/` — `claw-vm`, `image-gallery`, `shared-infra`.
- `infra/azure/packer/desktop/` — Packer config for the immutable `claw-desktop-gpu` baseline image.
- `fleet/claws.yaml` — canonical fleet manifest consumed by both `shared/` and `fleet/` Terraform roots (and by CI).
- `.github/workflows/` — `validate.yml` (PR checks), `bake-image.yml` (Packer on push to main), `deploy-fleet.yml` (Terraform apply + verify over SSH).

## Secrets and configuration

- Per-claw `.env` (shell path) or `claw_secrets` map in `infra/azure/terraform/fleet/secrets.auto.tfvars` (Terraform path, gitignored). CI receives it via the `CLAW_SECRETS_JSON` GitHub secret.
- At least one provider API key (`XAI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`) must be set — `verify.sh` enforces this.
- The fleet Terraform data disk has `prevent_destroy = true`. Do not work around it; destroying a data disk destroys a claw.
- Gmail/Google Workspace auth is a manual one-time OAuth flow (`docs/GMAIL.md`) — not automatable.

## Conventions worth respecting

- **Idempotency**: `boot.sh`, `run-updates.sh`, and every `updates/NNN-*.sh` must be safe to rerun. Boot replays them on every start; upgrade replays them on every new VM.
- **Packer bakes the desktop layer only; cloud-init installs the app layer**: `vm-runtime/install/desktop/*.sh` → Packer (baseline image). `vm-runtime/install/os/*.sh` → cloud-init (every fleet deploy). Do not move installation steps between these directories without thinking about which layer owns them. The legacy `vm-runtime/cloud-init/scratch.yaml` is the historical monolithic path — the fleet path does not use it.
- **`fleet/claws.yaml` is the single source of truth for fleet membership** — both `shared/` and `fleet/` Terraform roots read it, and CI deploys from it. Adding a claw = one YAML entry + one secrets entry.
- **Permissive inside the VM is intentional**: passwordless sudo, no exec sandbox. Containment is at the Azure boundary (scoped RG, NSG, credentials). Do not add guest-side hardening without an explicit request — it will break the agent.
- **Per-VM fields never go in `vm-runtime/defaults/`**: when propagating live `openclaw.json` back to defaults, strip `gateway.auth.token`, every `mcp.servers.*.env.*` token, `exec-approvals.socket.token`, the runtime-written `meta` / `wizard` / `plugins.installs.*` blocks, and per-entry `id` UUIDs on approval lists. MCP servers that need a token should be written at runtime from the per-claw `.env` in a numbered update script — `vm-runtime/updates/005-brightdata-mcp.sh` is the template.
- **Persist home-dir files via the data disk + a symlink**: anything under `/home/azureuser/` lives on the OS disk and is lost on image upgrade. Put the canonical copy under `/mnt/claw-data/workspace/` (reachable through the existing `~/workspace` bind mount) and create the symlink from `~/` in a numbered update script. `vm-runtime/updates/011-home-claude-md-symlink.sh` shows the idempotent fresh / existing / already-linked / divergent-copy handling.
- **`openclaw.json` is lenient at runtime**: trailing commas and `//` line comments are tolerated. Strict JSON tooling (Python's `json`, `jq`, etc.) must preprocess — the live fleet config has trailing commas that a strict parser will reject.

## Operating on a running VM

- **The agent is a gateway plugin, not a separate process.** The Claude Code-equivalent agent on each VM runs as the `lossless-claw` plugin inside `openclaw-gateway.service`. `pgrep claude` / `pgrep start-claude` return nothing. `sudo systemctl stop openclaw-gateway` is the ONLY way to halt the agent; `systemctl restart` resumes its in-flight task from memory.
- **Agent plan persistence**: conversation state (including "what I'm working on") lives in `~/.openclaw/lcm.db` (SQLite). Surviving restarts is the default — to interrupt a fixated agent you edit the DB, not kill a process. Tables: `conversations`, `messages` (PK `message_id`, ordering by `seq`), `message_parts` (typed children with `part_type`, `text_content`, etc.), `messages_fts*`, `summary_messages`. Use the `lcm-pruning` skill to trim a fixated conversation tail and inject a replacement user turn.
- **Gateway startup grace**: the gateway's `ExecStartPre` waits for `xfce4-session` on `:0` (up to 120s, typical 15–20s on a warm boot). Don't conclude a restart failed until you've waited this long; verify with `sudo ss -tlnp | grep :18789` and `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18789/`.
- **Agent display is `:0`, shared with the operator.** The gateway service sets `DISPLAY=:0`, `XAUTHORITY=/home/azureuser/.Xauthority`, `XDG_RUNTIME_DIR=/run/user/1000` — same as the LightDM autologin XFCE session. When you Moonlight in, you see the agent's Chrome and share its `~/.config/google-chrome` profile (GitHub / Google logins the operator performs flow to the agent and vice versa). There used to be a dedicated Xvfb `:99` for the agent; it was retired in update `013-agent-on-display-zero.sh`. Don't reintroduce it — the profile-sharing is the point.
- **Chrome launches via `/usr/local/bin/google-chrome-stable`** — a PATH-first wrapper installed by update `012-chrome-disable-keyring.sh` that prepends `--password-store=basic`. Stops the gnome-keyring unlock dialog from freezing headless XFCE. `openclaw.json`'s `browser.executablePath` points here; the apt-installed `/usr/bin/google-chrome-stable` is the underlying binary.
- **Config-write forensics**: every write to `openclaw.json` is logged at `~/.openclaw/logs/config-audit.jsonl` with pid/ppid/argv/hashes before and after. When the agent or anyone else has been editing config, read this first.
- **Gateway self-defense**: on detecting a clobbered config (missing `gateway.mode`, etc.) the gateway stashes the bad file at `~/.openclaw/openclaw.json.clobbered.<ISO>` before refusing to start.
- **Tooling on the VM**: `sqlite3` CLI is NOT installed. Use `python3 -c 'import sqlite3; ...'` for any DB work — the stdlib module is the only option.

### Gateway config validator rules

Violating any of these prevents the service from starting (`status=78/CONFIG`, crash-loop every ~15s):

- `gateway.mode` MUST be present (`"local"` for this project). Missing → `existing config is missing gateway.mode. Treat this as suspicious or clobbered`.
- When `gateway.auth.mode="none"`, `gateway.bind` MUST be `"loopback"` (no-auth requires loopback per the guard).
- When `gateway.tailscale.mode="serve"`, `gateway.bind` MUST resolve to loopback (`"loopback"`, or `"custom"` with `gateway.customBindHost="127.0.0.1"`).
- **Do not** change `gateway.bind` to `"tailnet"` or `"lan"` to try to expose the UI — that fights the validator. Tailnet access comes from `gateway.tailscale.mode="serve"`, which drives the gateway to run `tailscale serve --bg --yes 18789` on every start (idempotent).

### Tailscale Serve for chat-UI access

- Tailscale Serve must be enabled once at the **tailnet** level via the Tailscale admin console (`https://login.tailscale.com/f/serve?node=<NODE_ID>`). Until that click-through happens, the gateway's startup `tailscale serve --bg --yes 18789` fails silently in the journal with `Command failed:` and `tailscale serve status` shows `No serve config`.
- To see the real error, run `sudo tailscale serve --bg --yes 18789` manually — it prints `Serve is not enabled on your tailnet. To enable, visit: ...`.
- Once Serve is enabled, the gateway's auto-setup succeeds on every boot and the chat UI is reachable at `https://<magicdns-name>/` (tailnet-only, e.g. `https://chad-claw.tailaef983.ts.net/`). The operator's machine must also have the Tailscale client installed and logged into the same tailnet.
- Zero-config alternative for quick UI access without Serve: `ssh -L 18789:127.0.0.1:18789 azureuser@<ip>` → `http://localhost:18789/` on the operator's side.

### SCP and the blocked-keyword rule

CrowdStrike on the operator's machine blocks SSH command strings containing `claw`/`openclaw`. Same rule applies to `scp` — pulling `azureuser@<ip>:/mnt/cl*aw-data/...` fails because scp builds a remote SSH command that includes the source path. Two-step pull: (1) an on-VM script first copies the file to `/tmp/<neutral-name>`, (2) `scp azureuser@<ip>:/tmp/<neutral-name>` to the local box. The `deploy.sh` `stage_boot_files()` helper handles the push direction the same way.
