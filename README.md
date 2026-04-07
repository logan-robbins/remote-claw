# Remote Claw

Deploy multiple independent [OpenClaw](https://github.com/openclaw/openclaw) AI agents on Azure, each with its own persistent data, all sharing a pre-baked image. Talk to them via Telegram. They can browse the web, run commands, control the desktop, and do whatever you need.

## What you get

- **Multi-claw architecture**: run many independent agents (`main`, `research`, `trading`, ...) side-by-side, each with its own data disk and public IP
- **Azure Compute Gallery** with versioned specialized images — fast deploys (~2-3 min) after initial bake
- **Azure VM** per claw (8 vCPUs, 64 GiB RAM, Ubuntu 24.04)
- **Full XFCE desktop** accessible via RDP with Chrome, Telegram Desktop, OpenClaw Dashboard, Agent Browser Viewer
- **OpenClaw** with xAI Grok — full autonomy, no approval prompts
- **Telegram** integration — optional allowlist locking
- **Persistent data disks** that survive VM rebuilds
- **AppArmor removed**, **Azure IMDS blocked** — agent has unrestricted control inside the VM but can't touch your Azure account
- Chrome runs on a persistent virtual display (`Xvfb :99`) so the agent keeps working when you disconnect RDP
- **`Agent Browser Viewer`** shortcut: watch the agent use Chrome in real time via VNC inside your RDP session

## Prerequisites

1. **Azure account** with an active subscription
2. **xAI API key** from [console.x.ai](https://console.x.ai)
3. **Telegram bot token** from @BotFather
4. *(Optional)* **Your Telegram user ID** from @userinfobot (locks the bot to your account only)

## Setup (one time)

### Step 1: Install Azure CLI

```bash
# macOS
brew install azure-cli

# Linux
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
```

### Step 2: Log into Azure

```bash
az login
```

### Step 3: Get your xAI API key

Go to [console.x.ai](https://console.x.ai), create a new API key (starts with `xai-`).

### Step 4: Create a Telegram bot

1. Open Telegram and message **@BotFather**
2. Send `/newbot`, pick a name and username
3. Copy the token (looks like `123456789:ABCdefGHI...`)

### Step 5: *(Optional)* Get your Telegram user ID

If you want to lock the bot to your account only:

1. Message **@userinfobot** on Telegram
2. Copy your numeric ID

If you skip this, the bot responds to anyone who messages it (fine if nobody else knows the bot username).

### Step 6: Clone and add your keys

```bash
git clone https://github.com/logan-robbins/remote-claw.git
cd remote-claw
```

Create the key files (gitignored, never committed):

```bash
echo 'xai-your-api-key-here' > xai.txt
echo '123456789:ABCdefGHI-your-bot-token' > telegram.txt
# Optional: lock bot to your account
echo '123456789' > telegram-userid.txt
```

## Usage

### Create your first claw

```bash
./deploy.sh main
```

- **First time ever**: takes ~15 min (bakes the image once, then deploys)
- **Subsequent runs**: ~2-3 min (reuses the baked image)

When it finishes it prints your RDP credentials. Open Microsoft Remote Desktop (macOS) or Remote Desktop Connection (Windows) and connect.

### Use Telegram

Open Telegram on your phone and send any message to your bot. OpenClaw responds immediately — no pairing or approval. If you set `telegram-userid.txt`, only you can talk to it.

### Deploy a second claw

```bash
./deploy.sh research
```

Reuses the baked image — takes ~2-3 min. Gets its own public IP, its own data disk, its own fresh OpenClaw state. Both claws run side-by-side.

```bash
./deploy.sh list
```

Shows all your claws with their status, image version, and public IP.

### Upgrade a claw to a newer image

When the bake recipe changes (new package, new version), bake a new image:

```bash
./deploy.sh --bake
```

This creates a new version (e.g. `1.0.1`). Existing claws keep running on their current version until you upgrade them:

```bash
./deploy.sh main --update
```

This destroys the VM + OS disk but **keeps the data disk**. The new VM boots from the latest image version. All your conversation history, memory, and workspace files are preserved.

### Wipe data and start clean

```bash
./deploy.sh main --fresh
```

Destroys everything including the data disk, then recreates the claw with an empty data disk. Use this if you want to start from a blank slate.

### Destroy one claw (others unaffected)

```bash
./deploy.sh main --destroy
```

### Destroy everything

```bash
./deploy.sh --destroy-all
```

Deletes the entire resource group: all claws, all data, all images, the gallery. You stop paying immediately.

### Pin to a specific image version

```bash
./deploy.sh experimental --image 1.0.1
```

Normally claws use the latest version automatically. Use `--image` to pin to a specific version for testing or rollback.

## Command reference

### Claw operations (claw name required)

| Command | What it does |
|---|---|
| `./deploy.sh <name>` | Create new claw (error if exists) |
| `./deploy.sh <name> --update` | Rebuild VM from latest image, keep data disk |
| `./deploy.sh <name> --fresh` | Rebuild VM + wipe data disk |
| `./deploy.sh <name> --destroy` | Delete claw entirely |
| `./deploy.sh <name> --image <ver>` | Pin to specific image version |

### No-claw operations

| Command | What it does |
|---|---|
| `./deploy.sh` | Show help + list existing claws (never modifies) |
| `./deploy.sh list` | List all claws with status, image, IP |
| `./deploy.sh images` | List all image versions in the gallery |
| `./deploy.sh --bake` | Bake a new image version |
| `./deploy.sh --destroy-all` | Nuclear — delete the entire resource group |

## How it works

### The image is shared

All claws deploy from the same pre-baked image in an Azure Compute Gallery. The bake happens once and takes ~10 min (install packages, Node.js, OpenClaw, Chrome, Telegram Desktop, Playwright, disable AppArmor, block IMDS). After that, every deploy is ~2-3 min because it just attaches the image + injects secrets + starts services.

### Image versioning

Images are versioned `1.0.0`, `1.0.1`, `1.0.2`, ... Each `./deploy.sh --bake` creates a new version. The gallery keeps the **latest 3 versions**, older ones are auto-deleted. You can rollback by using `--image <version>`.

### Per-claw resources

Each claw owns:
- A VM (`claw-<name>-vm`)
- A data disk (`claw-<name>-data`, 64 GB)
- A NIC, a public IP, a subnet

Shared across all claws:
- Virtual network (`vnet-openclaw`, /16)
- NSG (`nsg-openclaw`, all ports open)
- Compute Gallery + images

### Data persistence

Each claw's data disk holds its OpenClaw memory, conversations, config, and workspace files. The VM is stateless — it can be destroyed and recreated freely. Data lives at `/data/openclaw/` (symlinked to `~/.openclaw/`) on the VM.

```
VM (per-claw, ephemeral)          Data Disk (per-claw, persistent)
  ├── Ubuntu 24.04                  └── /data/
  ├── XFCE, xrdp, Chrome                ├── openclaw/    -> ~/.openclaw
  ├── OpenClaw binary                    │   ├── .env
  └── Telegram Desktop                   │   ├── openclaw.json
                                          │   ├── exec-approvals.json
                                          │   ├── memory/
                                          │   └── conversations/
                                          └── workspace/   -> ~/workspace
```

### Display decoupling

The agent's Chrome runs on a persistent virtual display (`Xvfb :99`) that is completely independent of RDP. This means:
- **Chrome never crashes** when you disconnect RDP
- **You can close RDP any time** — the agent keeps working
- **Telegram keeps working** whether you're connected or not

To **watch** the agent's browser from inside your RDP session, double-click **Agent Browser Viewer** — it opens a VNC viewer connected to `Xvfb :99` where Chrome lives.

### Security model

The agent has **full control inside the VM** — it can run any command, read any file, control the browser, and access the network. No sandboxing, no approval prompts.

The agent **cannot touch your Azure account**:
- Azure IMDS (`169.254.169.254`) is blocked via iptables, so no process can acquire Azure tokens
- No Azure CLI installed on the VM
- No Azure credentials exist on the VM
- The VM has no managed identity

The Telegram bot can be locked to your user ID via `telegram-userid.txt`. The gateway dashboard is bound to localhost.

## Connect via RDP

| Platform | Client |
|---|---|
| macOS | [Microsoft Remote Desktop](https://apps.apple.com/app/microsoft-remote-desktop/id1295203466) |
| Windows | Built-in (`mstsc`) |
| Linux | `remmina` or `xfreerdp` |

## Files

| File | Purpose |
|---|---|
| `deploy.sh` | Multi-claw CLI |
| `cloud-init-bake.yaml` | Full software install (runs once per bake) |
| `runtime-init.sh` | Runtime config template, SSH-injected per deploy with secrets |
| `xai.txt` | Your xAI API key (gitignored) |
| `telegram.txt` | Your Telegram bot token (gitignored) |
| `telegram-userid.txt` | *(optional)* Your Telegram numeric user ID (gitignored) |

## VM Details

| Spec | Value |
|---|---|
| Size | Standard_E8s_v3 (8 vCPUs, 64 GiB RAM) |
| OS | Ubuntu 24.04 LTS |
| Desktop | XFCE on X11 |
| Remote access | xrdp on port 3389 |
| OS Disk | 256 GB Premium SSD |
| Data Disk | 64 GB Premium SSD (per-claw, persistent) |
| Region | East US (zone 3) |
| Firewall | All ports open (inbound + outbound) |
| AI model | xAI Grok 4 |
| Agent | OpenClaw (latest, Node.js 24) |
| Browser | Google Chrome (headed on Xvfb :99) |
| Azure IMDS | Blocked |

## Quota Note

Azure subscriptions have default vCPU quotas. The default is 10 cores in the `Standard ESv3 Family` — enough for one claw. If you want to run multiple claws simultaneously, request a quota increase in the [Azure portal](https://portal.azure.com) under **Quotas > Compute**.

## SSH key caveat

The baked image **embeds the SSH public key** from the machine where `./deploy.sh --bake` was run. All claws deployed from that image inherit the same key. If you rotate your local SSH keypair, you'll need to `./deploy.sh --bake` a new image and then `./deploy.sh <claw> --update` each existing claw to pick up the new key.
