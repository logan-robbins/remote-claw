# OpenClawps

Ops for [OpenClaw](https://openclaw.ai) agents. Deploy, version, and roll out updates to autonomous claws on Azure while preserving agent identity, workspace, and state.

Each claw is an always-on VM with a full graphical desktop, OpenClaw gateway, Telegram bot, Chrome, and Claude Code. The desktop is the point -- as computer-use capabilities ship across model providers, claws should be running on a real desktop with a real browser, continuously exercising those capabilities in the environment they're designed for.

The default run mode is deliberately permissive: sandbox off, full exec, passwordless sudo. The agent operates like a human at the keyboard. Containment lives at the infrastructure boundary, not inside the guest. More restrictive run modes are a natural next contribution.

## Quick start

```bash
cp .env.template .env && vi .env    # API keys + Telegram bot token
./deploy.sh scratch                  # full install from stock Ubuntu, ~10 min
```

Message the Telegram bot. The agent responds.

## Image lifecycle

```bash
./deploy.sh bake 1.0.0                          # capture as versioned image
ENV_FILE=.env.alice VM_NAME=alice ./deploy.sh    # stamp out a claw, ~2 min
./deploy.sh upgrade alice --image 2.0.0          # swap image, keep state
```

**Image** = versioned system runtime (OS, packages, OpenClaw, Chrome, Claude Code, boot logic). **Data disk** = durable agent state (config, secrets, workspace, memory). Update the image, swap the VM, the agent picks up where it left off. Migration scripts in `updates/` run automatically on upgrade.

## Credentials

Each claw gets its own `.env`:

| Key | Required | Notes |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | Unique per claw -- one bot per token |
| `XAI_API_KEY` | yes | Can share across claws if desired |
| `OPENAI_API_KEY` | no | For OpenAI-model agents |
| `BRIGHTDATA_API_TOKEN` | no | Web research |
| `TELEGRAM_USER_ID` | no | Restricts who can DM the bot |
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

## Verification

`deploy.sh` runs a health check after every deploy and upgrade. Run it manually:

```bash
ssh azureuser@<ip> 'sudo /opt/claw/verify.sh'
```

## Contributing

The project ships with a single permissive run mode on Azure. It's structured to be extended:

- **Run modes** -- restricted exec policies, network egress controls, hardened images
- **Cloud providers** -- GCP, AWS, bare metal
- **Image variants** -- headless, GPU, ARM
- **Channels** -- Slack, Discord, Matrix
- **Fleet ops** -- rollout orchestration, dashboards, auto-scaling

## License

[MIT](LICENSE)
