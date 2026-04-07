# Remote Claw

Deploy an autonomous [OpenClaw](https://github.com/openclaw/openclaw) AI agent on an Azure VM with full desktop control. Talk to it via Telegram. It can browse the web, run commands, control the desktop, and do whatever you need.

## What you get

- Azure VM (8 vCPUs, 64 GiB RAM, Ubuntu 24.04)
- Full XFCE desktop accessible via RDP (Chrome, Telegram Desktop, OpenClaw WebChat)
- OpenClaw running with xAI Grok models -- full autonomy, no approval prompts
- Telegram integration locked to your account only
- Chrome browser (headed on Xvfb), Playwright, and desktop automation tools
- Persistent data disk that survives VM rebuilds
- All firewall ports open (the agent can host and access anything)
- Azure IMDS blocked (agent can't touch your cloud account)

## Prerequisites

You need four things before deploying:

1. **Azure account** with an active subscription
2. **xAI API key** from [console.x.ai](https://console.x.ai)
3. **Telegram bot token** from @BotFather
4. **Your Telegram user ID** from @userinfobot

## Setup (one time)

### Step 1: Install Azure CLI

If you don't have it already:

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

This opens your browser. Sign in with your Azure account.

### Step 3: Get your xAI API key

1. Go to [console.x.ai](https://console.x.ai)
2. Create an account or sign in
3. Go to API Keys and create a new key
4. Copy the key (starts with `xai-`)

### Step 4: Create a Telegram bot

1. Open Telegram on your phone or desktop
2. Search for **@BotFather** and start a chat
3. Send `/newbot`
4. Pick a display name (e.g. "My OpenClaw")
5. Pick a username (e.g. `my_openclaw_bot`)
6. BotFather gives you a token like `123456789:ABCdefGHI...` -- copy it

### Step 5: Get your Telegram user ID

1. Open Telegram and message **@userinfobot**
2. It replies with your numeric ID (e.g. `123456789`)
3. This locks the bot so only you can use it

### Step 6: Clone this repo and add your keys

```bash
git clone <this-repo-url>
cd remote-claw
```

Create three files with your keys (these are gitignored and never committed):

```bash
echo 'xai-your-api-key-here' > xai.txt
echo '123456789:ABCdefGHI-your-bot-token' > telegram.txt
echo '123456789' > telegram-userid.txt
```

## Deploy

```bash
./deploy.sh
```

That's it. The script will:

1. Validate your keys and Azure login
2. Create the VM, networking, and a persistent data disk
3. Install the full desktop environment and OpenClaw
4. Block Azure IMDS (so the agent can't touch your cloud account)
5. Wait for everything to finish
6. Print your RDP connection details

The whole process takes about 10 minutes.

## Connect

When the script finishes, it prints something like:

```
 Connect via Remote Desktop (RDP):
   Host:     20.121.201.200:3389
   Username: azureuser
   Password: NWrJVsQVIgFpWEW7Z1U8Aa1!
```

Open your RDP client and connect:

- **macOS**: Install [Microsoft Remote Desktop](https://apps.apple.com/app/microsoft-remote-desktop/id1295203466) from the App Store
- **Windows**: Built-in Remote Desktop Connection (`mstsc`)
- **Linux**: `remmina` or `xfreerdp`

## Use Telegram

Once the VM is running, open Telegram on your phone and send any message to your bot. OpenClaw responds immediately -- no pairing or approval step needed.

The bot only responds to your Telegram account. Anyone else who messages it is silently ignored.

The bot can't message you first (that's a Telegram platform rule for all bots). You always start the conversation, but after that first message it works like a normal chat.

## Use the Dashboard (inside RDP)

When you're RDP'd into the desktop, double-click the **OpenClaw Dashboard** shortcut. This launches the gateway web UI. No token needed — the gateway is bound to localhost so only processes on the VM can reach it.

## How the display works

The agent's browser (Chrome) runs on a persistent virtual display (Xvfb `:99`) that is independent of your RDP session. This means:

- **Chrome never crashes** when you disconnect RDP
- **You can close RDP any time** -- the agent keeps working
- **Telegram keeps working** whether you're connected or not

**To watch the agent's browser from RDP**, double-click the **Agent Browser Viewer** shortcut on the desktop. This opens a VNC viewer mirroring display `:99` where Chrome lives. You can see exactly what the agent sees in real time.

**To access the OpenClaw dashboard from RDP**, double-click the **OpenClaw Dashboard** shortcut. This auto-launches the web UI with authentication handled.

Your RDP desktop and the agent's Chrome run on separate X displays -- they're decoupled by design so neither can break the other.

## Managing the VM

There are three commands:

```bash
./deploy.sh              # Deploy (or redeploy if data disk exists)
./deploy.sh --update     # Rebuild VM with fresh OS, keep all data
./deploy.sh --destroy    # Delete everything including data
```

### Update vs Destroy

| | `--update` | `--destroy` |
|---|---|---|
| VM | Rebuilt fresh | Deleted |
| OS + software | Reinstalled (latest) | Deleted |
| Data disk | Preserved | Deleted |
| OpenClaw memory | Kept | Gone |
| OpenClaw conversations | Kept | Gone |
| Workspace files | Kept | Gone |
| API keys (.env) | Kept from disk | Gone (re-read from .txt) |
| Telegram pairing | Kept | Must re-pair |
| RDP password | New one generated | N/A |
| Public IP | Same | Released |

**Use `--update` when** you want to upgrade OpenClaw, change the cloud-init config, or fix a broken OS without losing agent data.

**Use `--destroy` when** you want a completely clean slate, or you're done and want to stop paying.

## How data persistence works

The VM has two disks:

```
OS Disk (256 GB)                    Data Disk (64 GB)
  ephemeral, rebuilt on update        persistent, survives updates
  ├── Ubuntu 24.04                    └── /data/
  ├── XFCE, xrdp, Node.js                ├── openclaw/    -> ~/.openclaw
  ├── OpenClaw binary                    │   ├── .env
  └── Chrome, Playwright                 │   ├── openclaw.json
                                          │   ├── exec-approvals.json
                                          │   ├── memory/
                                          │   └── conversations/
                                          └── workspace/   -> ~/workspace
```

On first deploy, the data disk is formatted and initialized with your API keys and OpenClaw config. On subsequent deploys (including `--update`), the existing data is preserved and symlinked into the new VM.

## Security model

The agent has **full control inside the VM** -- it can run any command, read any file, control the browser, and access the network. There are no approval prompts or sandboxing.

The agent **cannot touch your Azure account**:

- Azure Instance Metadata Service (IMDS) is blocked via iptables, so no process on the VM can acquire Azure tokens
- No Azure CLI is installed on the VM
- No Azure credentials exist on the VM
- The VM has no managed identity

The Telegram bot only responds to your user ID. The gateway WebChat is bound to localhost and requires a token.

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Creates, updates, and destroys the Azure VM |
| `cloud-init.yaml` | Software installation recipe (runs on first boot) |
| `xai.txt` | Your xAI API key (gitignored) |
| `telegram.txt` | Your Telegram bot token (gitignored) |
| `telegram-userid.txt` | Your Telegram numeric user ID (gitignored) |

## VM Details

| Spec | Value |
|------|-------|
| Size | Standard_E8s_v3 (8 vCPUs, 64 GiB RAM) |
| OS | Ubuntu 24.04 LTS |
| Desktop | XFCE on X11 |
| Remote access | xrdp on port 3389 |
| OS Disk | 256 GB Premium SSD |
| Data Disk | 64 GB Premium SSD (persistent) |
| Region | East US (zone 3) |
| Firewall | All ports open (inbound + outbound) |
| AI model | xAI Grok 4 |
| Agent | OpenClaw (latest, Node.js 24) |
| Browser | Google Chrome (headed on Xvfb :99) |
| Azure IMDS | Blocked (agent can't access Azure APIs) |

## Quota Note

Azure subscriptions have default vCPU quotas. If deployment fails with a quota error, you may need to request an increase in the [Azure portal](https://portal.azure.com) under **Quotas > Compute**. The VM needs 8 vCPUs in the `Standard ESv3 Family`.
