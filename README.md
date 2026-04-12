<p align="center">
  <img src="openclawps.png" alt="OpenClawps" width="700">
</p>

# OpenClawps

MLOps-inspired CI/CD for [OpenClaw](https://openclaw.ai) agent fleets. Prescriptive, versioned system images provide a managed runtime. Portable data disks carry agent identity, workspace, and state across VM replacements and image upgrades. Deploy a fully equipped, desktop-running claw on Azure in one command. Upgrade it without losing state in another.

Architecture diagrams and topology: [challengelogan.com/openclawps](https://challengelogan.com/openclawps)

## What this adds to OpenClaw

- **One-command Azure deploy** -- `deploy.sh scratch` goes from zero to a working agent with Telegram, Chrome, and Claude Code in ~10 min. No manual VM setup.
- **Full graphical desktop** -- Real xfce4 desktop on `:0` with Chrome and VNC. Computer-use agents need a real browser and a real screen, not a headless shell.
- **Two-layer separation** -- The system (OS, packages, OpenClaw, boot logic) and the claw (identity, workspace, memory, credentials) are on separate disks. The system layer is an immutable, versioned image. The claw layer is a portable data disk you can detach, reattach to a different VM, or move to a new image version. The claw is not the VM -- it rides on top of it.
- **Stateful upgrades** -- Delete the old VM, create a new one from a new image, reattach the same data disk. The claw picks up where it left off. Migration scripts run automatically.
- **Fleet-friendly** -- Same image, different `.env`, different claw. Each gets its own Telegram bot, API keys, and workspace.
- **33-point health checks** -- `verify.sh` runs after every deploy and upgrade. Catches misconfigs before they become mystery failures.

## Architecture

### Two-layer separation

The system and the claw are on separate disks. The system is disposable. The claw is portable.

```mermaid
graph LR
    subgraph IMAGE["OS Disk (from image — disposable)"]
        OS[Ubuntu 24.04 + xfce4]
        OC[OpenClaw + Chrome + Claude Code]
        BOOT["/opt/claw/boot.sh"]
        UNITS[systemd units]
    end

    subgraph DATA["Data Disk /mnt/claw-data (portable — survives upgrades)"]
        CONFIG["openclaw/ — config, secrets, exec-approvals"]
        WS["workspace/ — SOUL.md, agents, memory, skills"]
        STATE["sessions, transcripts, Telegram state"]
        VNC["vnc-password.txt, update-version.txt"]
    end

    BOOT -->|"symlinks"| CONFIG
    BOOT -->|"symlinks"| WS

    style IMAGE fill:#1e3a5f,stroke:#3b82f6,color:#e2e8f0
    style DATA fill:#2d1854,stroke:#a855f7,color:#e2e8f0
```

### Upgrade lifecycle

Delete the VM, keep the disk, create a new VM from a new image, reattach the disk. The claw picks up where it left off.

```mermaid
sequenceDiagram
    participant Op as Operator
    participant AZ as Azure
    participant Disk as Data Disk
    participant VM as New VM (v2)

    Op->>AZ: deploy.sh upgrade alice --image 2.0.0
    AZ->>AZ: Deallocate old VM
    AZ->>Disk: Detach data disk
    AZ->>AZ: Delete old VM
    AZ->>VM: Create VM from image v2
    AZ->>VM: Attach data disk at LUN 0
    VM->>VM: cloud-init injects secrets
    VM->>VM: boot.sh mounts disk
    VM->>VM: Symlinks restored
    VM->>VM: run-updates.sh (003 → 004...)
    VM->>VM: Gateway + Telegram start
    VM-->>Op: verify.sh — 33 checks pass
```

### Boot sequence

Every VM start runs `boot.sh`. Idempotent — safe to rerun, safe to reboot.

```mermaid
flowchart LR
    A[Mount disk<br/>LUN 0 discovery] --> B[Seed defaults<br/>first boot only]
    B --> C[Symlinks<br/>~/.openclaw<br/>~/workspace]
    C --> D[Permissions<br/>+ VNC sync]
    D --> E[Tailscale<br/>join if key set]
    E --> F[Run updates<br/>version-gated]
    F --> G[Start services<br/>lightdm, VNC,<br/>gateway, claude]

    style A fill:#2d1854,stroke:#a855f7,color:#e2e8f0
    style B fill:#0a2e1a,stroke:#22c55e,color:#e2e8f0
    style C fill:#1e3a5f,stroke:#3b82f6,color:#e2e8f0
    style D fill:#1e3a5f,stroke:#3b82f6,color:#e2e8f0
    style E fill:#0c2d3d,stroke:#06b6d4,color:#e2e8f0
    style F fill:#3d2800,stroke:#f59e0b,color:#e2e8f0
    style G fill:#0a2e1a,stroke:#22c55e,color:#e2e8f0
```

### Fleet topology

Same image, different `.env`, different claw. Each is independent.

```mermaid
graph TB
    GALLERY["Azure Compute Gallery<br/>claw-base v3.0.0"]

    GALLERY --> ALICE
    GALLERY --> BOB
    GALLERY --> CAROL

    subgraph ALICE["alice"]
        A_VM["VM (from image)"]
        A_DISK[("Data Disk<br/>alice-data")]
        A_TG["@alice_bot"]
    end

    subgraph BOB["bob"]
        B_VM["VM (from image)"]
        B_DISK[("Data Disk<br/>bob-data")]
        B_TG["@bob_bot"]
    end

    subgraph CAROL["carol"]
        C_VM["VM (from image)"]
        C_DISK[("Data Disk<br/>carol-data")]
        C_TG["@carol_bot"]
    end

    style GALLERY fill:#1e3a5f,stroke:#3b82f6,color:#e2e8f0
    style ALICE fill:#0a2e1a,stroke:#22c55e,color:#e2e8f0
    style BOB fill:#0c2d3d,stroke:#06b6d4,color:#e2e8f0
    style CAROL fill:#2d1854,stroke:#a855f7,color:#e2e8f0
```

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

## Author

Built by [Logan Robbins](https://linkedin.com/in/loganrobbins) -- AI architect and researcher with 15+ years building production systems at Disney, Intel, Apple, and IBM. Currently AI Platform Architect at Disney and author of the [Parallel Decoder Transformer](https://arxiv.org/abs/2512.10054) paper on synchronized parallel generation. Previously built enterprise AI platforms at Intel and Apple, MLOps pipelines at IBM, and designed distributed systems at scale. Opinions about how agents should run in production come from actually running them there.

## License

[MIT](LICENSE)
