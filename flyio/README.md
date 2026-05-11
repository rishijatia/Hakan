# 🚀 Hermes Gateway on Fly.io — Setup Guide

Run your Hermes agent 24/7 on Fly.io so it responds to Telegram even when your Mac is off.

## Prerequisites

1. **Fly.io account** — sign up at https://fly.io (free, needs credit card for verification)
2. **flyctl CLI** — install on your Mac:
   ```bash
   brew install flyctl
   ```
   Or: `curl -L https://fly.io/install.sh | sh`

3. **Telegram Bot Token** — from @BotFather on Telegram
4. **Your Telegram User ID** — from @userinfobot
5. **OpenRouter API Key** — from https://openrouter.ai/settings/keys

## Step-by-Step Setup

### 1. Login to Fly.io
```bash
fly auth login
```

### 2. Create the app
```bash
cd ~/Hakan/flyio
fly launch --copy-config --no-deploy
```
- Choose app name (or accept `hermes-gateway`)
- Choose region (default `iad` US-East is fine)
- Say **No** to postgres/redis

### 3. Set secrets (API keys)
```bash
fly secrets set \
  TELEGRAM_BOT_TOKEN="your-bot-token-here" \
  TELEGRAM_ALLOWED_USERS="your-user-id" \
  TELEGRAM_HOME_CHANNEL="your-chat-id" \
  OPENROUTER_API_KEY="your-openrouter-key" \
  GITHUB_TOKEN="ghp_xxx"
```

### 4. Deploy!
```bash
fly deploy
```

### 5. Verify it's running
```bash
fly status
fly logs
```

Send a message to your Telegram bot — it should respond!

## Managing the Gateway

```bash
# View logs
fly logs

# Check status
fly status

# Restart
fly machines restart

# SSH into the container
fly ssh console

# Scale down (stop billing)
fly scale count 0

# Scale back up
fly scale count 1
```

## Cost

Fly.io free tier includes:
- 3 shared-cpu-1x VMs (256MB) — we use 1
- 160GB outbound data transfer
- **$0/month** if within free limits

## Troubleshooting

**Bot not responding?**
1. Check `fly logs` for errors
2. Verify secrets: `fly secrets list`
3. SSH in: `fly ssh console` then `hermes gateway status`

**Want to update config?**
Edit files locally, then `fly deploy`

**Want to bring it back to Mac later?**
Just run `hermes gateway run` on your Mac — the Fly.io instance will still be there as backup.

---
*Part of the Hakan project — Rishi's custom Hermes setup*

