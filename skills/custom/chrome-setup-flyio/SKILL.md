---
name: chrome-setup-flyio
description: >
  Install and configure Chrome for headless browser automation on Fly.io.
  Fixes "Chrome not found" errors from agent-browser. Covers npm global install,
  Chrome download, AGENT_BROWSER_EXECUTABLE_PATH setup, and PATH configuration.
triggers:
  - chrome not found
  - browser not working
  - agent-browser
  - install chrome
---

# Chrome Setup on Fly.io

## Problem
The Hermes browser tool uses `agent-browser` CLI which requires Chrome/Chromium.
On Fly.io, the container runs as non-root user `hermes` with no `apt-get`.

## Solution

### 1. Set npm global prefix (no sudo)
```bash
npm config set prefix /opt/data/npm-global
```

### 2. Install agent-browser
```bash
export PATH="/opt/data/npm-global/bin:$PATH"
npm install -g agent-browser
```

### 3. Download Chrome
```bash
agent-browser install
```
Chrome installs to: `~/.agent-browser/browsers/chrome-<version>/chrome`

### 4. Set environment variable
Add to `/opt/data/.env`:
```
AGENT_BROWSER_EXECUTABLE_PATH=/opt/data/home/.agent-browser/browsers/chrome-<version>/chrome
```

### 5. Add npm global to PATH in .env
```
PATH=/opt/data/npm-global/bin:$PATH
```

### 6. Create symlink for cache detection
The browser tool checks `/opt/data/.agent-browser/browsers` (HERMES_HOME-based path):
```bash
mkdir -p /opt/data/.agent-browser
ln -sf /opt/data/home/.agent-browser/browsers /opt/data/.agent-browser/browsers
```

## Pitfalls
- `npm install -g` fails without setting custom prefix (permission denied)
- `agent-browser install --with-deps` fails on Fly.io (no apt-get)
- Chrome binary is ~277MB; takes ~30s to download
- `.env` changes require agent restart to take effect
- Browser tool looks for Chrome in HERMES_HOME path, not HOME path — symlink needed
