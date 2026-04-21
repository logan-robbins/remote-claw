# TOOLS.md - Environment Notes

This file documents what is specific to this claw VM. Skills define how tools work; this file records your local setup.

## Desktop

- Display: X11 on `:0`, xfce4 session
- VNC: port 5900, password in `~/vnc-password.txt`
- Browser: Chrome at `/usr/bin/google-chrome-stable` (no sandbox, not headless)

## Workspace Paths

- `~/workspace` → `/mnt/claw-data/workspace` (this directory, persists on data disk)
- `~/.openclaw` → `/mnt/claw-data/openclaw` (config, secrets, skills)
- `/mnt/claw-data/workspace/tmp/` — bind mount of `/tmp/` (any file at `/tmp/foo` is simultaneously reachable at `/mnt/claw-data/workspace/tmp/foo`, which IS an allowed preview path). Bind mount, not symlink, so the server's `realpath()` check also passes.

## Chat-previewable files (allowed media roots)

The control UI will only preview a local file whose absolute path starts with one of these six roots (hardcoded in `buildMediaLocalRoots`, `local-roots-BrPriMlc.js`). Writing to any other path yields `Unavailable — Outside allowed folders` in chat.

1. `/tmp/openclaw/` — the "preferred OpenClaw tmp dir" (resolved by `resolvePreferredOpenClawTmpDir`, already exists `0700`). Use for ephemeral captures you want to show the user.
2. `/home/azureuser/.openclaw/media/` — long-lived media store, served by `assistant-media`.
3. `/home/azureuser/.openclaw/canvas/`
4. `/home/azureuser/.openclaw/sandboxes/`
5. `/mnt/claw-data/workspace/` (= `~/workspace/`) — this directory. Use for durable, version-controllable artifacts.
6. `<configDir>/media/` — rarely relevant on this VM.

There is no config knob to extend this list (GitHub issue openclaw#22237, closed "not planned"). But because `/tmp/` is bind-mounted at `/mnt/claw-data/workspace/tmp/`, any file written anywhere in `/tmp/<name>.png` can be attached as `/mnt/claw-data/workspace/tmp/<name>.png` — same bytes, allowed path, no copy needed.

**When an attachment renders `unavailable`:** do not describe the image. State that the preview failed, move or copy the file into `/tmp/openclaw/` or `~/workspace/`, and reattach.

## Models

- **Primary:** Grok 4.20 reasoning (`xai/grok-4.20-0309-reasoning`)
- **Fallback:** Grok 4 (`xai/grok-4`)
- **Additional:** Kimi K2.5 (`moonshot/kimi-k2.5`), DeepSeek V3 (`deepseek/deepseek-chat`), DeepSeek R1 (`deepseek/deepseek-reasoner`)

## Networking

- Gateway: port 18789, loopback only
- Tailscale: joins tailnet if `TAILSCALE_AUTHKEY` is set in `.env`

## Channel

- Telegram DM only (group policy disabled, streaming partial)

## Exec

- Security: full, no approval prompts
- Timeout: 1800s per command
- Background: commands background after 10s

## Web

- Search: enabled
- Fetch: enabled
- **Bright Data MCP**: web scraping, search engines, structured data extraction
  - Tools: `search_engine`, `scrape_as_markdown`, `scrape_as_html`, `scrape_batch`, `search_engine_batch`
  - Structured endpoints: `web_data_reuter_news`, `web_data_github_repository_file`, `web_data_yahoo_finance_business`
  - Token is sourced from `BRIGHTDATA_API_TOKEN` in `.env`

## PhantomTouch (if RELAY_TOKEN set)

- **Relay HTTP:** port 9090 (localhost only — MCP server talks here)
- **Relay WS:** port 9091 (phone connects here from the internet)
- **MCP tools:** `phantom_screenshot`, `phantom_tap`, `phantom_tap_and_type`, `phantom_swipe`, `phantom_open_url`, `phantom_launch_app`, `phantom_find_and_tap`, `phantom_find_element`, `phantom_press_back`, `phantom_press_home`, `phantom_wait_for_element`, `phantom_chrome_action`, `phantom_batch`
- **Test:** `curl -s http://localhost:9090/health | jq .`
- **Screenshot test:** `curl -s -X POST http://localhost:9090/execute -d '{"action":"screenshot","scale":0.5}' | jq '.result.image' | wc -c`
- **Phone status:** check relay health endpoint — `phone_connected: true` means the phone's WS is live

## Skills (workspace/skills/)

- **mcporter** — MCP server porter, configure and manage MCP servers
- **github** — GitHub CLI integration (issues, PRs, repos)
- **tmux** — tmux session management
- **model-usage** — track and report model token usage
- **gog** — Google search via CLI
- **caldav-calendar** — CalDAV calendar integration (read/write events)
- **deep-research** — rigorous multi-source web research with progress tracking

---

Add whatever helps you do your job. This is your cheat sheet.
