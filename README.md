# OpenClawps

Ops for Claws. Deploy, version, and roll out updates to fleets of autonomous [OpenClaw](https://openclaw.ai) agents while preserving each agent's identity, workspace, and running state.

## Why a desktop

Every claw runs a full graphical desktop (xfce4 on `:0`, exposed over VNC). This is intentional. As computer-use capabilities ship across model providers, we want agents running on a real desktop with a real browser, testing those capabilities continuously in the environment they're designed for. The desktop isn't a legacy artifact -- it's the test surface.

## Why deliberately permissive

The default run mode is wide open: sandbox off, full exec rights, passwordless sudo, all ports exposed. The agent operates as if it were a human at the keyboard. Containment is at the infrastructure boundary (isolated resource group, scoped credentials), not inside the guest.

This is the starting point, not the end state. We ship the permissive mode first because it's the one that works today and unblocks everything else. The project is structured so the community can contribute more secure run modes (restricted exec policies, network egress controls, hardened images, read-only root filesystems) without breaking the core lifecycle. If you have opinions about how agents should be sandboxed, this is the place to build it.

## How it works

**Image = versioned system runtime.** OS, packages, OpenClaw, Chrome, Claude Code, boot logic -- baked once, stamped out repeatedly.

**Data disk = durable agent state.** Config, secrets, workspace, memory, session state -- survives VM replacement on a detachable Azure managed disk.

**Boot script = late binding.** Mounts the disk, seeds defaults on first run, repairs symlinks, applies migrations, starts services.

Update the image, swap the VM underneath, the agent picks up where it left off.

## Lifecycle

### Build from scratch

```bash
cp .env.template .env && vi .env
./deploy.sh scratch
```

Full install from stock Ubuntu 24.04. ~10 min. When done, message the Telegram bot.

### Bake the image

```bash
./deploy.sh bake 1.0.0
```

Strips secrets, captures the system as a versioned image in Azure Compute Gallery.

### Stamp out claws

```bash
ENV_FILE=.env.alice VM_NAME=alice ./deploy.sh
ENV_FILE=.env.bob   VM_NAME=bob   ./deploy.sh
```

~2 min each. Fresh data disk, own credentials, own Telegram bot, fully independent.

### Roll out updates

```bash
./deploy.sh bake 2.0.0
./deploy.sh upgrade alice --image 2.0.0
```

Numbered migration scripts in `updates/` run automatically on the data disk after each upgrade.

## Credentials per claw

| Credential | Purpose |
|---|---|
| `TELEGRAM_BOT_TOKEN` | Each claw is a different bot (@BotFather) |
| `XAI_API_KEY` | Model provider (can share across claws) |
| `OPENAI_API_KEY` | Optional |
| `BRIGHTDATA_API_TOKEN` | Optional, web research |
| `TELEGRAM_USER_ID` | Optional, restricts who can DM the bot |
| `VM_PASSWORD` | Optional, auto-generated. Single password for SSH and VNC. |

## Prerequisites

- Azure CLI (`az login`)
- `envsubst` (`brew install gettext`)
- `sshpass` (deploy-time automation only -- VMs accept plain `ssh azureuser@ip` from anywhere)

## Connect

```bash
ssh azureuser@<ip>          # password printed at deploy time, saved in .vm-state
open vnc://<ip>:5900        # same password
```

## Stop / start

```bash
az vm deallocate -g rg-linux-desktop -n alice   # billing stops
az vm start      -g rg-linux-desktop -n alice   # everything resumes
```

Nothing reinstalls. Systemd services auto-start. Data disk stays attached.

## Contributing

The architecture is designed to be extended. Areas where contributions would be valuable:

- **Secure run modes** -- restricted exec policies, network egress controls, read-only root
- **Cloud providers** -- GCP, AWS, bare metal adaptations
- **Image variants** -- minimal (no desktop), GPU-enabled, ARM
- **Channels** -- Slack, Discord, Matrix adapters beyond Telegram
- **Orchestration** -- fleet-wide rollouts, health dashboards, auto-scaling

## Destroy

```bash
az vm delete -g rg-linux-desktop -n alice --yes                    # one claw
az group delete --name rg-linux-desktop --yes --no-wait            # everything
```

## License

MIT. See [LICENSE](LICENSE).
