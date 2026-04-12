<p align="center">
  <img src="openclawps.png" alt="OpenClawps" width="400">
</p>

# OpenClawps

Ops for [OpenClaw](https://openclaw.ai) agents. One command to deploy a fully equipped, desktop-running claw on Azure. One command to upgrade it without losing state.

OpenClaw gives you the AI brain and the Gateway. OpenClawps gives you the easy button to run that brain as a reliable, desktop-equipped cloud agent.

## What this adds to OpenClaw

- **One-command Azure deploy** -- `deploy.sh scratch` goes from zero to a working agent with Telegram, Chrome, and Claude Code in ~10 min. No manual VM setup.
- **Full graphical desktop** -- Real xfce4 desktop on `:0` with Chrome and VNC. Computer-use agents need a real browser and a real screen, not a headless shell.
- **Image-based versioning** -- Bake the system into immutable images. Stamp out claws in ~2 min. Agent state lives on a separate data disk that survives image swaps.
- **Stateful upgrades** -- Swap the VM underneath without losing identity, workspace, memory, or credentials. Migration scripts run automatically.
- **Fleet-friendly** -- Same image, different `.env`, different claw. Each gets its own Telegram bot, API keys, and workspace.
- **33-point health checks** -- `verify.sh` runs after every deploy and upgrade. Catches misconfigs before they become mystery failures.

## Quick start

```bash
cp .env.template .env && vi .env    # model, API keys, Telegram bot token
./deploy.sh scratch                  # full install from stock Ubuntu, ~10 min
```

Message the Telegram bot. The agent responds.

## Image lifecycle

```bash
./deploy.sh bake 1.0.0                          # capture as versioned image
ENV_FILE=.env.alice VM_NAME=alice ./deploy.sh    # stamp out a claw, ~2 min
./deploy.sh upgrade alice --image 2.0.0          # swap image, keep state
```

**Image** = versioned system runtime (OS, packages, OpenClaw, Chrome, Claude Code, boot logic). **Data disk** = durable agent state (config, secrets, workspace, memory). Migration scripts in `updates/` run automatically on upgrade.

## Configuration

Each claw gets its own `.env`:

| Key | Required | Notes |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | Unique per claw -- one bot per token |
| `OPENCLAW_MODEL` | no | `xai/grok-4`, `openai/gpt-4o`, `anthropic/claude-4`, etc. Default: `xai/grok-4` |
| `XAI_API_KEY` | * | Required if using xai/* models |
| `OPENAI_API_KEY` | * | Required if using openai/* models |
| `ANTHROPIC_API_KEY` | * | Required if using anthropic/* models |
| `BRIGHTDATA_API_TOKEN` | no | Web research |
| `TELEGRAM_USER_ID` | no | Restricts who can DM the bot |
| `TAILSCALE_AUTHKEY` | no | Auto-joins your tailnet for remote gateway access |
| `VM_PASSWORD` | no | Auto-generated if blank. Same password for SSH and VNC. |

## Prerequisites

- Azure CLI (`az login`)
- `envsubst` (`brew install gettext`)
- `sshpass` (deploy-time automation only -- claws accept plain `ssh azureuser@ip`)

## Connect

```bash
ssh azureuser@<ip>       # password in .vm-state
open vnc://<ip>:5900     # same password
```

## Daily operations

```bash
az vm deallocate -g rg-linux-desktop -n alice   # stop billing
az vm start      -g rg-linux-desktop -n alice   # resume, services auto-start
```

## Security

Deliberately permissive inside the VM: sandbox off, full exec, passwordless sudo. The agent operates like a human at the keyboard. Containment lives at the infrastructure boundary (isolated resource group, scoped credentials), not inside the guest.

## Contributing

The project ships with a single permissive run mode on Azure. It's structured to be extended:

- **Run modes** -- restricted exec policies, network egress controls, hardened images
- **Cloud providers** -- GCP, AWS, bare metal
- **Image variants** -- headless, GPU, ARM
- **Channels** -- Slack, Discord, Matrix
- **Fleet ops** -- rollout orchestration, dashboards, auto-scaling

## License

[MIT](LICENSE)
