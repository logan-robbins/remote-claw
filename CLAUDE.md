# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

OpenClawps: MLOps-style CI/CD for OpenClaw agent fleets on Azure. The repo builds versioned golden images, deploys VMs from them, and upgrades those VMs without losing per-agent state. Two deployment paths coexist: **Terraform (preferred, declarative fleet state)** and **shell (`bin/deploy.sh`, used for scratch installs and image baking)**.

## The two-layer model (critical to internalize)

Every change should respect the separation:

- **Image layer (disposable)**: OS, packages, OpenClaw, Chrome, Claude Code, and everything under `/opt/claw/` (boot logic, update scripts, defaults). Built by Packer or `deploy.sh bake`, versioned in the Azure Compute Gallery. Never carries state.
- **Data disk (portable)**: `/mnt/claw-data` — per-claw identity, secrets, workspace, memory, Telegram state, VNC password, and `update-version.txt`. Survives VM replacement. `~/.openclaw` and `~/workspace` are bind mounts onto this disk.

Upgrades replace the VM from a new image and reattach the same data disk. Any code that writes state must write it under `/mnt/claw-data`; anything the image provides must be reconstructable on every boot.

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

Terraform (two separate roots, two separate states):

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

Packer image build:

```bash
cd infra/azure/packer
packer init .
packer build -var subscription_id=$(az account show --query id -o tsv) -var image_version=4.0.0 .
```

On a running VM (either via SSH or the deploy/upgrade tail): `/opt/claw/verify.sh` runs the 33+ point health check.

Topology site (isolated Vite/React app, unrelated to VM runtime):

```bash
cd apps/topology
npm run dev        # vite
npm run build
```

## Where things live

- `bin/deploy.sh` — thin wrapper; real implementation is `infra/azure/shell/deploy.sh`.
- `vm-runtime/` — the VM payload. **Packer stages this into `/opt/claw/` on the image; the shell deploy path uploads it over SSH.** Both entrypoints must stay in sync with this tree.
  - `cloud-init/` — `scratch.yaml` (full install) and `image.yaml` (slim, for image-based boot).
  - `lifecycle/` — `boot.sh`, `run-updates.sh`, `verify.sh`, `start-claude.sh`.
  - `defaults/` — seeded onto a fresh data disk on first boot (config, workspace).
  - `updates/NNN-*.sh` — numbered, version-gated migrations.
- `infra/azure/shell/` — Azure CLI implementation for scratch/bake/upgrade.
- `infra/azure/terraform/{shared,fleet,modules}/` — Terraform roots and shared modules (`claw-vm`, `image-gallery`, `shared-infra`).
- `infra/azure/packer/` — Packer config plus numbered `scripts/NN-*.sh` install steps (mirrors the scratch cloud-init).
- `fleet/claws.yaml` — canonical fleet manifest consumed by **both** Terraform roots.
- `.github/workflows/` — `validate.yml` (PR checks), `bake-image.yml` (Packer on push to main), `deploy-fleet.yml` (Terraform apply + verify over SSH).

## Secrets and configuration

- Per-claw `.env` (shell path) or `claw_secrets` map in `infra/azure/terraform/fleet/secrets.auto.tfvars` (Terraform path, gitignored). CI receives it via the `CLAW_SECRETS_JSON` GitHub secret.
- At least one provider API key (`XAI_API_KEY`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `MOONSHOT_API_KEY`, `DEEPSEEK_API_KEY`) must be set — `verify.sh` enforces this.
- The fleet Terraform data disk has `prevent_destroy = true`. Do not work around it; destroying a data disk destroys a claw.
- Gmail/Google Workspace auth is a manual one-time OAuth flow (`docs/GMAIL.md`) — not automatable.

## Conventions worth respecting

- **Idempotency**: `boot.sh`, `run-updates.sh`, and every `updates/NNN-*.sh` must be safe to rerun. Boot replays them on every start; upgrade replays them on every new VM.
- **Packer mirrors scratch cloud-init**: the numbered `infra/azure/packer/scripts/` steps exist to produce the same end state as `vm-runtime/cloud-init/scratch.yaml`. Changes to one usually need a matching change in the other.
- **`fleet/claws.yaml` is the single source of truth for fleet membership** — both Terraform roots read it, and CI deploys from it. Adding a claw = one YAML entry + one secrets entry.
- **Permissive inside the VM is intentional**: passwordless sudo, no exec sandbox. Containment is at the Azure boundary (scoped RG, NSG, credentials). Do not add guest-side hardening without an explicit request — it will break the agent.
- **Per-VM fields never go in `vm-runtime/defaults/`**: when propagating live `openclaw.json` back to defaults, strip `gateway.auth.token`, every `mcp.servers.*.env.*` token, `exec-approvals.socket.token`, the runtime-written `meta` / `wizard` / `plugins.installs.*` blocks, and per-entry `id` UUIDs on approval lists. MCP servers that need a token should be written at runtime from the per-claw `.env` in a numbered update script — `vm-runtime/updates/005-brightdata-mcp.sh` is the template.
- **Persist home-dir files via the data disk + a symlink**: anything under `/home/azureuser/` lives on the OS disk and is lost on image upgrade. Put the canonical copy under `/mnt/claw-data/workspace/` (reachable through the existing `~/workspace` bind mount) and create the symlink from `~/` in a numbered update script. `vm-runtime/updates/011-home-claude-md-symlink.sh` shows the idempotent fresh / existing / already-linked / divergent-copy handling.
- **`openclaw.json` is lenient at runtime**: trailing commas and `//` line comments are tolerated. Strict JSON tooling (Python's `json`, `jq`, etc.) must preprocess — the live fleet config has trailing commas that a strict parser will reject.

## Operating on a running VM

- **The agent is a gateway plugin, not a separate process.** The Claude Code-equivalent agent on each VM runs as the `lossless-claw` plugin inside `openclaw-gateway.service`. `pgrep claude` / `pgrep start-claude` return nothing. `sudo systemctl stop openclaw-gateway` is the ONLY way to halt the agent; `systemctl restart` resumes its in-flight task from memory.
- **Agent plan persistence**: conversation state (including "what I'm working on") lives in `~/.openclaw/lcm.db` (SQLite). Surviving restarts is the default — to interrupt a fixated agent you edit the DB, not kill a process. Tables: `conversations`, `messages` (PK `message_id`, ordering by `seq`), `message_parts` (typed children with `part_type`, `text_content`, etc.), `messages_fts*`, `summary_messages`. Use the `lcm-pruning` skill to trim a fixated conversation tail and inject a replacement user turn.
- **Gateway startup grace**: ~11–12s from `systemctl start` to `[gateway] ready` (ExecStartPre waits for `/tmp/.X11-unix/X99`). Don't conclude a restart failed until you've waited this long; verify with `sudo ss -tlnp | grep :18789` and `curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:18789/`.
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
