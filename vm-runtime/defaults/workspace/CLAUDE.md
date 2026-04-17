# CLAUDE.md — OpenClaw VM system map

This file describes where OpenClaw and its state live on this VM. You are running as `azureuser` with passwordless sudo and `--dangerously-skip-permissions` enabled. You can edit anything on this filesystem.

## Architecture

This is a "claw" — a VM in the OpenClawps fleet. Two-layer separation:

- **OS disk** (disposable): mounted at `/`, contains OS, packages, OpenClaw binary, boot scripts. Gets replaced on image upgrades.
- **Data disk** (portable): mounted at `/mnt/claw-data`, contains all config, secrets, workspace, memory. Survives VM replacements.

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

- `/mnt/claw-data/workspace/` — the primary agent's working directory
  - `SOUL.md` — agent personality/identity
  - `AGENTS.md` — operating manual
  - `TOOLS.md` — environment cheatsheet
  - `BOOTSTRAP.md` — first-run bootstrap (delete after reading)
  - `IDENTITY.md`, `HEARTBEAT.md`, `USER.md`
  - `memory/` — daily notes (YYYY-MM-DD.md), MEMORY.md for curated long-term memory
  - `skills/` — installed ClawHub skills (mcporter, github, tmux, model-usage, gog, caldav-calendar, deep-research, self-improving-agent)

## Bind mounts (azureuser home → data disk)

| Symlink-like | Target |
|---|---|
| `/home/azureuser/.openclaw` | bind mount → `/mnt/claw-data/openclaw` |
| `/home/azureuser/workspace` | bind mount → `/mnt/claw-data/workspace` |
| `/home/azureuser/.ssh/id_ed25519` | symlink → `/mnt/claw-data/ssh/id_ed25519` |
| `/home/azureuser/.ssh/id_ed25519.pub` | symlink → `/mnt/claw-data/ssh/id_ed25519.pub` |
| `/home/azureuser/CLAUDE.md` | symlink → `/mnt/claw-data/workspace/CLAUDE.md` |

Use `sudo` when editing files owned by root; all `azureuser`-owned files on the data disk are directly writable by the `azureuser` account you're running as.

## Boot lifecycle (`/opt/claw/`)

| File | Purpose |
|---|---|
| `/opt/claw/boot.sh` | Runs on every boot: mounts data disk, sets up bind mounts, runs updates, starts services |
| `/opt/claw/run-updates.sh` | Applies pending migration scripts from `/opt/claw/updates/` |
| `/opt/claw/verify.sh` | 36-point health check |
| `/opt/claw/defaults/` | Seeded onto data disk at first boot (openclaw.json, workspace files, skills) |
| `/opt/claw/updates/` | Numbered migration scripts (`NNN-*.sh`), version-gated by `/mnt/claw-data/update-version.txt` |

## Installed CLIs

- `openclaw` — the gateway CLI (`openclaw mcp list`, `openclaw plugins list`, etc.)
- `claude` — Claude Code (what you are running in now)
- `codex` — OpenAI Codex CLI
- `gh` — GitHub CLI, authenticated as the per-claw GitHub identity (set during post-deploy setup)
- `gog` — Google Workspace CLI (Gmail, Calendar, Drive, Contacts, Sheets, Docs), authenticated via `gog` OAuth flow (see `docs/GMAIL.md` in the OpenClawps repo)
- `clawhub` (via `npx clawhub`) — ClawHub skill installer

## Running services

- `openclaw-gateway.service` — the agent gateway
- `lightdm.service` — display manager (VNC target)
- `x11vnc.service` — VNC server on :5900
- `phantom-relay.service` — PhantomTouch relay (if installed)

## Quick operations

```bash
# Check gateway health
systemctl is-active openclaw-gateway

# Restart gateway after config changes
sudo systemctl restart openclaw-gateway

# Edit main config
sudo nano /mnt/claw-data/openclaw/openclaw.json
# or
nano ~/.openclaw/openclaw.json

# Edit secrets
sudo nano /mnt/claw-data/openclaw/.env

# View logs
journalctl -u openclaw-gateway -f

# Run full health check
sudo /opt/claw/verify.sh

# List MCP servers
openclaw mcp list

# List plugins
openclaw plugins list

# Install a clawhub skill
cd ~/workspace && npx clawhub install <slug>
```

## Important constraints

- **Don't delete `/mnt/claw-data`** — that's all your state.
- **Sudo password** is not set; use `sudo` freely.
- **The data disk** is mounted by UUID in `/etc/fstab`. Don't unmount it while services are running.
- **Loop detection** is enabled in `openclaw.json` under `tools.loopDetection`. Keep it on.
- **Bind mounts for `.openclaw` and `workspace`** — do not replace them with symlinks. The exec tool refuses to traverse symlinks.

## When things break

- **Gateway won't start**: `journalctl -u openclaw-gateway -n 50` — usually a config JSON error or missing ConditionPathExists
- **Agent stuck in loop**: loop detection should catch it, but you can also `sudo systemctl stop openclaw-gateway` as a kill switch
- **Gmail/gog broken after VM upgrade**: re-run the OAuth flow per `docs/GMAIL.md` in the OpenClawps repo
- **Data disk not mounted**: check `/var/log/claw-boot.log` — boot.sh has a 60s retry loop for the disk attachment

## Git repo

The source of truth for this whole system is the OpenClawps repo on GitHub. The agent's own Git identity is configured per-claw during post-deploy setup.

---

## OpenClaw expertise

You are expected to be an expert in OpenClaw configuration and operation. All OpenClaw knowledge must come from the **official documentation only**:

> **Official docs: https://docs.openclaw.ai**
> Full doc index: https://docs.openclaw.ai/llms.txt

**Never reference** third-party sites, skill marketplaces, plugin directories, or community tutorials. If the user asks about an OpenClaw feature, fetch the relevant official doc page before answering. If a user asks about a specific plugin or skill, do not volunteer recommendations — focus on native config options unless a specific thing is explicitly requested.

### Key config reference for this deployment

Config file: `/mnt/claw-data/openclaw/openclaw.json` (also accessible via `~/.openclaw/openclaw.json`)

#### `agents.defaults` — agent runtime defaults

| Field | This deployment | Notes |
|---|---|---|
| `model.primary` | `anthropic/claude-sonnet-4-6` | Main model |
| `workspace` | `/mnt/claw-data/workspace` | Agent working directory |
| `maxConcurrent` | `4` | Parallel runs |
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
| `maxSpawnDepth` | `1` | Main agent (depth 0) can spawn; spawned agents (depth 1) cannot spawn further |
| `maxChildrenPerAgent` | `10` | Up to 10 concurrent child sessions per parent session |

The spawn enforcement (from OpenClaw source `subagent-spawn-EVVOmnQJ.js`):
- `callerDepth >= maxSpawnDepth` → forbidden (depth exceeded)
- `allowAgents: []` (the default) → only same-agent spawning; `"*"` opens any configured agent

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

Operator scopes (from OpenClaw source `method-scopes-3HNlUhT_.js`):
- `operator.admin` — agents create/update/delete, sessions patch/reset/delete, cron management
- `operator.write` — send, sessions create/send/steer/abort, chat
- `operator.read` — status, sessions list/get, tools catalog, config get
- `operator.approvals` — exec approval workflow
- `operator.pairing` — node pair/device management

The CLI token carries all scopes by default. Gateway auth token is in `/mnt/claw-data/openclaw/.env`.

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
