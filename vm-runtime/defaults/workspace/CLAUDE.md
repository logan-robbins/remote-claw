# CLAUDE.md — OpenClaw VM system map

This file describes where OpenClaw and its state live on this VM. You are running as `azureuser` with passwordless sudo and `--dangerously-skip-permissions` enabled. You can edit anything on this filesystem.

## Role: Meta-Manager

**You (Claude Code) are the meta-manager for this claw.** The user SSHes in specifically to talk to you when OpenClaw goes off the rails — stuck loops, broken configs, failed boots, runaway agents. Your job is to diagnose and fix the OpenClaw system.

- Working directory: `/home/azureuser/workspace/projects/` (the openclaups source repo lives at `./openclaups/`)
- OpenClaw (the primary agent) runs separately as `openclaw-gateway.service`
- You have full sudo access and can restart, reconfigure, or kill OpenClaw as needed

## VM identity

- **Hostname**: `chad-claw`
- **Internal IP**: `10.0.0.4` (Azure `eth0`)
- **Tailscale IP**: `100.100.198.21` (`tailscale0`)
- **Resource group**: `rg-claw-westus`

## Architecture

This is a "claw" — a VM in the OpenClawps fleet. Two-layer separation:

- **OS disk** (disposable): mounted at `/`, contains OS, packages, OpenClaw binary, boot scripts. Gets replaced on image upgrades.
- **Data disk** (portable): mounted at `/mnt/claw-data`, contains all config, secrets, workspace, memory. Survives VM replacements.

The openclaups source repo (the system that built and manages this VM) is at:
`/home/azureuser/workspace/projects/openclaups/`

## OpenClaw runtime

- **Binary**: `/usr/bin/openclaw` (CLI entry)
- **Package**: `/usr/lib/node_modules/openclaw/` (npm module with `dist/`, stock plugins)
- **Systemd unit**: `/etc/systemd/system/openclaw-gateway.service`
- **Process**: runs as `azureuser`, listens on `127.0.0.1:18789`
- **Logs**: `journalctl -u openclaw-gateway`
- **Restart**: `sudo systemctl restart openclaw-gateway`

## Config and state (data disk)

| Path | Purpose |
|---|---|
| `/mnt/claw-data/openclaw/.env` | Secrets (API keys, Telegram token, Gmail password, GitHub PAT, KEYRING_PASSWORD) |
| `/mnt/claw-data/openclaw/openclaw.json` | Main config (model, plugins, tools, MCP servers, loop detection) |
| `/mnt/claw-data/openclaw/agents/main/sessions/sessions.json` | Conversation sessions |
| `/mnt/claw-data/openclaw/memory/main.sqlite` | Built-in memory store |
| `/mnt/claw-data/openclaw/lcm.db` | Lossless-claw DAG context engine database |
| `/mnt/claw-data/openclaw/tasks/runs.sqlite` | Task flow runs |
| `/mnt/claw-data/openclaw/flows/registry.sqlite` | Task flow registry |
| `/mnt/claw-data/openclaw/extensions/` | Installed plugins (lossless-claw lives here) |
| `/mnt/claw-data/openclaw/client_secret.json` | Google OAuth credentials for gog CLI |
| `/mnt/claw-data/ssh/` | SSH keys (persist across VM replacements) |

## Workspace (data disk)

- `/mnt/claw-data/workspace/` — the primary OpenClaw agent's working directory
  - `SOUL.md` — agent personality/identity
  - `AGENTS.md` — operating manual
  - `TOOLS.md` — environment cheatsheet
  - `IDENTITY.md`, `HEARTBEAT.md`, `USER.md`
  - `memory/` — daily notes (YYYY-MM-DD.md), MEMORY.md for curated long-term memory
  - `skills/` — installed ClawHub skills (mcporter, github, tmux, model-usage, gog, caldav-calendar, deep-research, self-improving-agent)
  - `projects/` — source repos; `openclaups/` is the fleet management system

## Bind mounts (azureuser home → data disk)

| Path | Target |
|---|---|
| `/home/azureuser/.openclaw` | bind mount → `/mnt/claw-data/openclaw` |
| `/home/azureuser/workspace` | bind mount → `/mnt/claw-data/workspace` |
| `/home/azureuser/.ssh/id_ed25519` | symlink → `/mnt/claw-data/ssh/id_ed25519` |
| `/home/azureuser/.ssh/id_ed25519.pub` | symlink → `/mnt/claw-data/ssh/id_ed25519.pub` |
| `/home/azureuser/CLAUDE.md` | symlink → `/home/azureuser/workspace/CLAUDE.md` (this file) |
| `/home/azureuser/workspace/projects/CLAUDE.md` | symlink → `../CLAUDE.md` (this file) |

Use `sudo` when editing files owned by root; all `azureuser`-owned files on the data disk are directly writable.

**Do not replace bind mounts with symlinks.** The exec tool refuses to traverse symlinks.

## Boot lifecycle (`/opt/claw/`)

| File | Purpose |
|---|---|
| `/opt/claw/boot.sh` | Runs on every boot: mounts data disk, sets up bind mounts, runs updates, starts services |
| `/opt/claw/run-updates.sh` | Applies pending migration scripts from `/opt/claw/updates/` |
| `/opt/claw/verify.sh` | 36-point health check |
| `/opt/claw/defaults/` | Seeded onto data disk at first boot (openclaw.json, workspace files, skills) |
| `/opt/claw/updates/` | Numbered migration scripts (`NNN-*.sh`), version-gated by `/mnt/claw-data/update-version.txt` |

Boot order: mount data disk → seed defaults (first boot only) → restore bind mounts → Tailscale → run-updates.sh → start services.

## Installed CLIs

- `openclaw` — the gateway CLI (`openclaw mcp list`, `openclaw plugins list`, etc.)
- `claude` — Claude Code (you, the meta-manager)
- `codex` — OpenAI Codex CLI
- `gh` — GitHub CLI, authenticated as the per-claw GitHub identity
- `gog` — Google Workspace CLI (Gmail, Calendar, Drive, Contacts, Sheets, Docs)
- `clawhub` (via `npx clawhub`) — ClawHub skill installer

## Running services

- `openclaw-gateway.service` — the OpenClaw agent gateway (**active**)
- `lightdm.service` — display manager for XFCE desktop (**active**)
- `x11vnc.service` — VNC server on :5900 (inactive by default)
- `phantom-relay.service` — PhantomTouch relay (inactive, install-optional)

## Quick operations

```bash
# Check gateway health
systemctl is-active openclaw-gateway

# Restart gateway after config changes
sudo systemctl restart openclaw-gateway

# Kill a stuck/looping agent
sudo systemctl stop openclaw-gateway

# Edit main config
nano ~/.openclaw/openclaw.json

# Edit secrets
nano ~/.openclaw/.env

# View live logs
journalctl -u openclaw-gateway -f

# Last 50 log lines
journalctl -u openclaw-gateway -n 50

# Run full health check
sudo /opt/claw/verify.sh

# Validate config JSON before restarting
python3 -m json.tool ~/.openclaw/openclaw.json

# List MCP servers / plugins
openclaw mcp list
openclaw plugins list

# OpenClaw diagnostics
openclaw doctor

# Install a clawhub skill
cd ~/workspace && npx clawhub install <slug>
```

## Important constraints

- **Don't delete `/mnt/claw-data`** — that's all persistent state.
- **Sudo password** is not set; use `sudo` freely.
- **The data disk** is mounted by UUID in `/etc/fstab`. Don't unmount while services are running.
- **Loop detection** is enabled in `openclaw.json` under `tools.loopDetection`. Keep it on.
- **Files the UI can preview** must live under one of six hardcoded media roots (`/tmp/openclaw/`, `~/.openclaw/media|canvas|sandboxes/`, `~/workspace/`, `<configDir>/media/`). Writing to plain `/tmp/` produces `Outside allowed folders` in chat. See `AGENTS.md` → "Attaching files to chat" and `TOOLS.md` → "Chat-previewable files".
- **Bind mounts for `.openclaw` and `workspace`** — do not replace them with symlinks. The exec tool refuses to traverse symlinks.

## When things break

- **Gateway won't start**: `journalctl -u openclaw-gateway -n 50` — usually a config JSON error or missing ConditionPathExists
- **Agent stuck in loop**: loop detection fires at warningThreshold 10 / criticalThreshold 20, but you can `sudo systemctl stop openclaw-gateway` as a hard kill switch
- **Gmail/gog broken after VM upgrade**: re-run the OAuth flow per `docs/GMAIL.md` in the openclaups repo
- **Data disk not mounted**: check `/var/log/claw-boot.log` — boot.sh has a 60s retry loop for disk attachment
- **Config broken (bad JSON)**: `python3 -m json.tool ~/.openclaw/openclaw.json` to validate before restarting
- **"This model does not support assistant message prefill" on every message**: Two causes work together. (1) `thinkingDefault: "high"` with `claude-sonnet-4-6` triggers an API pathway the model rejects — fix by setting `thinkingDefault: "adaptive"` in `openclaw.json`. (2) Each rejection writes an empty `role=assistant, content=[]` entry to the JSONL session file, perpetuating the loop — stop gateway, remove those entries, reset LCM bootstrap state (`UPDATE conversation_bootstrap_state SET last_seen_size=0, last_seen_mtime_ms=0, last_processed_offset=0, last_processed_entry_hash=NULL WHERE conversation_id=N`), restart. See memory `openclaw_prefill_loop_fix.md`. Upstream: openclaw/openclaw#58567.

## Git repo

The source of truth for this whole system is the openclaups repo on GitHub.
- Local clone: `/home/azureuser/workspace/projects/openclaups/`
- The agent's Git identity is configured per-claw during post-deploy setup.

---

## OpenClaw expertise

All OpenClaw knowledge must come from the **official documentation only**:

> **Official docs: https://docs.openclaw.ai**
> Full doc index: https://docs.openclaw.ai/llms.txt

Never reference third-party sites, skill marketplaces, or community tutorials. Fetch the relevant official doc page before answering OpenClaw questions. Focus on native config options unless a specific plugin/skill is explicitly requested.

### Key config reference for this deployment

Config file: `~/.openclaw/openclaw.json` (→ `/mnt/claw-data/openclaw/openclaw.json`)

#### `agents.defaults` — agent runtime defaults

| Field | This deployment | Notes |
|---|---|---|
| `model.primary` | `anthropic/claude-sonnet-4-6` | Main model |
| `workspace` | `/mnt/claw-data/workspace` | Agent working directory |
| `maxConcurrent` | `32` | Parallel runs |
| `sandbox.mode` | `off` | No sandboxing |
| `elevatedDefault` | `full` | Full host access |
| `thinkingDefault` | `high` | Extended reasoning on by default |
| `contextPruning.mode` | `cache-ttl` with `ttl: 1h` | Prune stale cache entries after 1 hour |
| `heartbeat.every` | `30m` | Periodic heartbeat run every 30 min |
| `compaction.mode` | `safeguard` | Compact context when it grows large |

#### `agents.defaults.subagents` — sub-agent spawning policy

| Field | Value | Effect |
|---|---|---|
| `allowAgents` | `["*"]` | Any configured agent may be spawned |
| `maxSpawnDepth` | `5` | Agents can spawn up to 5 levels deep |
| `maxChildrenPerAgent` | `20` | Up to 20 concurrent child sessions per parent |
| `maxConcurrent` | `32` | Total concurrent subagents system-wide |
| `runTimeoutSeconds` | `0` | No timeout on agent runs |

#### `tools` — execution and safety

```json5
exec: { security: "full", ask: "off", backgroundMs: 10000, timeoutSec: 1800 }
loopDetection: { enabled: true, historySize: 30, warningThreshold: 10, criticalThreshold: 20 }
web: { search: { enabled: true }, fetch: { enabled: true } }
```

#### `gateway` — network and auth

```json5
{ port: 18789, mode: "local", bind: "loopback", auth: { mode: "token" } }
```

Operator scopes:
- `operator.admin` — agents create/update/delete, sessions patch/reset/delete, cron management
- `operator.write` — send, sessions create/send/steer/abort, chat
- `operator.read` — status, sessions list/get, tools catalog, config get
- `operator.approvals` — exec approval workflow
- `operator.pairing` — node pair/device management

The CLI token carries all scopes. Gateway auth token is in `~/.openclaw/.env`.

### Useful CLI commands

```bash
openclaw config schema              # full JSON schema
openclaw config schema --key agents # schema for a specific section
openclaw doctor                     # health diagnostics
openclaw mcp list                   # list MCP servers
openclaw plugins list               # list installed plugins
journalctl -u openclaw-gateway -f   # live logs
sudo systemctl restart openclaw-gateway  # apply config changes
```
