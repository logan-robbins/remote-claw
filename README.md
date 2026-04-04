# Remote Claw

Deploy an autonomous [OpenClaw](https://github.com/openclaw/openclaw) AI agent on an Azure VM with full desktop control. Talk to it via Telegram. It can browse the web, run commands, control the desktop, and do whatever you need.

## What you get

- Azure VM (8 vCPUs, 64 GiB RAM, Ubuntu 24.04)
- Full XFCE desktop accessible via RDP
- OpenClaw running with xAI Grok models
- Telegram integration for remote communication
- Chromium browser, Playwright, and desktop automation tools
- All firewall ports open (the agent can host and access anything)

## Prerequisites

You need three things before deploying:

1. **Azure account** with an active subscription
2. **xAI API key** from [console.x.ai](https://console.x.ai)
3. **Telegram bot token** from @BotFather

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

### Step 5: Clone this repo and add your keys

```bash
git clone <this-repo-url>
cd remote-claw
```

Create two files with your keys (these are gitignored and never committed):

```bash
echo 'xai-your-api-key-here' > xai.txt
echo '123456789:ABCdefGHI-your-bot-token' > telegram.txt
```

## Deploy

```bash
./deploy.sh
```

That's it. The script will:

1. Validate your keys and Azure login
2. Create the VM and all networking
3. Install the full desktop environment and OpenClaw
4. Wait for everything to finish
5. Print your RDP connection details

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

## Pair Telegram

After you RDP in:

1. Open a terminal on the desktop
2. Run: `sudo journalctl -u openclaw-gateway -f`
3. On your phone, send any message to your bot in Telegram
4. A pairing code appears in the terminal -- approve it
5. You can now talk to OpenClaw from anywhere via Telegram

## Destroy

When you're done, tear it all down:

```bash
./deploy.sh --destroy
```

This deletes the VM and everything associated with it. You stop paying immediately.

## Redeploy

Want a fresh VM? Just run `./deploy.sh` again. The keys in `xai.txt` and `telegram.txt` are reused automatically. A new RDP password is generated each time.

## Files

| File | Purpose |
|------|---------|
| `deploy.sh` | Creates and destroys the Azure VM |
| `cloud-init.yaml` | Software installation recipe (runs on first boot) |
| `xai.txt` | Your xAI API key (gitignored) |
| `telegram.txt` | Your Telegram bot token (gitignored) |

## VM Details

| Spec | Value |
|------|-------|
| Size | Standard_E8s_v3 (8 vCPUs, 64 GiB RAM) |
| OS | Ubuntu 24.04 LTS |
| Desktop | XFCE on X11 |
| Remote access | xrdp on port 3389 |
| Disk | 256 GB Premium SSD |
| Region | East US (zone 3) |
| Firewall | All ports open (inbound + outbound) |
| AI model | xAI Grok 4 |
| Agent | OpenClaw (latest) |

## Quota Note

Azure subscriptions have default vCPU quotas. If deployment fails with a quota error, you may need to request an increase in the [Azure portal](https://portal.azure.com) under **Quotas > Compute**. The VM needs 8 vCPUs in the `Standard ESv3 Family`.
