---
name: relay-to-user
description: "Push a message into Rishi's Telegram chat from inside an API-server invocation. Use when a peer agent (squad, research, etc.) needs to surface a status update, PR-ready notification, or escalation to Rishi but the work was triggered via /v1/chat/completions (where responses don't otherwise land in Telegram). Fire-and-forget: this does not wait for Rishi's reply."
version: 0.1.0
author: Hakan
metadata:
  hermes:
    tags: [messaging, telegram, multi-agent, foundation]
    related_skills: [call-agent, audit-log]
---

# Relay to User — Push From API Context Into Telegram

The gateway runs two adapters simultaneously: the **Telegram adapter** (handles inbound messages from Rishi) and the **API server adapter** (handles inbound HTTP from peer agents). These are independent — a message arriving on the API server does NOT bubble up to the Telegram chat by default.

This skill closes that gap. When a peer agent calls the gateway with content that should reach Rishi, the gateway uses this skill to push a Telegram message via the Bot API.

## When To Use

You (the gateway) should invoke this skill **whenever a peer agent's API call contains content meant for Rishi**. Typical phrasings to watch for in the incoming prompt:

- "Relay to Rishi: ..."
- "Tell Rishi: ..."
- "Notify the user: ..."
- "Let Rishi know that: ..."
- Any escalation like "PR ready for review", "stuck on X, need direction", "cron completed"

If the incoming API call is *not* a relay request (it's a real chat completion the peer wants answered), respond normally — don't relay.

## How To Use

```bash
bash /opt/data/skills/custom/relay-to-user/scripts/relay_to_user.sh "Message text. Markdown formatting supported."
```

Or pipe a longer message:

```bash
echo "Multi-line\nmessage" | bash /opt/data/skills/custom/relay-to-user/scripts/relay_to_user.sh -
```

Preview without sending (useful while drafting):

```bash
bash /opt/data/skills/custom/relay-to-user/scripts/relay_to_user.sh --dry-run "preview"
```

## What It Does

1. Validates `TELEGRAM_BOT_TOKEN` and `TELEGRAM_HOME_CHANNEL` are set (gateway-only — squad won't have these).
2. POSTs to Telegram Bot API `/sendMessage` with `parse_mode=Markdown` by default.
3. Logs success or failure to `/opt/data/logs/audit.log` (action: `relay-to-user`).
4. Exits 0 on success (message landed in Rishi's chat), non-zero on failure.

## Important Limits

- **Fire-and-forget only.** Returns as soon as Telegram acknowledges the POST. Cannot wait for Rishi to reply — that's a separate, harder feature (would need persistent task correlation).
- **Gateway-only.** Other agents must NOT call this script directly. They call the gateway via `call-agent` with a relay-shaped prompt, and the gateway invokes the script on their behalf. This keeps Bot token scope minimal.
- **Markdown caveat:** Telegram's MarkdownV2 has strict escaping rules. The script uses legacy "Markdown" mode by default which is more forgiving but supports fewer features. If a message fails with a parse error, fall back to plain text by setting `TELEGRAM_PARSE_MODE=""`.

## Environment

| Variable | Required | Default | Purpose |
|----------|----------|---------|---------|
| `TELEGRAM_BOT_TOKEN` | yes | — | Bot token from BotFather |
| `TELEGRAM_HOME_CHANNEL` | yes | — | Chat ID to deliver to (Rishi's DM) |
| `TELEGRAM_API_BASE` | no | `https://api.telegram.org` | Override for testing |
| `TELEGRAM_PARSE_MODE` | no | `Markdown` | `MarkdownV2`, `HTML`, or empty for plain |

## Failure Modes

- Bot token revoked / chat ID wrong → Telegram returns `ok: false` with description. Script exits 1, audit-logs the failure.
- Telegram unreachable (proxy down, rate-limited) → curl times out at 30s. Script exits 1.
- Empty message → usage error, exits 1.
