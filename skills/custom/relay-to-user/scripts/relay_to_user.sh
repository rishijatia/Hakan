#!/bin/bash
# relay_to_user.sh — push a message into Rishi's Telegram chat via Bot API.
#
# Lives on the gateway app (squad and other agents do NOT call this directly;
# they call gateway via call-agent and the gateway uses this skill).
#
# Required env (Fly secrets on hermes-gateway):
#   TELEGRAM_BOT_TOKEN     — bot token from BotFather
#   TELEGRAM_HOME_CHANNEL  — chat ID to deliver to (Rishi's DM channel)
#
# Optional env:
#   TELEGRAM_API_BASE      — defaults to https://api.telegram.org (override for tests)
#   TELEGRAM_PARSE_MODE    — defaults to "Markdown" (set to "" for plain text)
#
# Usage:
#   relay_to_user.sh "your message"
#   echo "long message" | relay_to_user.sh -
#   relay_to_user.sh --dry-run "preview without sending"
set -euo pipefail

DRY_RUN=false
if [ "${1:-}" = "--dry-run" ]; then
    DRY_RUN=true
    shift
fi

MESSAGE="${1:-}"
if [ "$MESSAGE" = "-" ]; then
    MESSAGE=$(cat)
fi
if [ -z "$MESSAGE" ]; then
    echo "Usage: $0 [--dry-run] \"message text\"  or  echo \"msg\" | $0 -" >&2
    exit 1
fi

if [ -z "${TELEGRAM_BOT_TOKEN:-}" ]; then
    echo "Error: TELEGRAM_BOT_TOKEN not set (this skill must run on the gateway)" >&2
    exit 1
fi

CHAT_ID="${TELEGRAM_HOME_CHANNEL:-}"
if [ -z "$CHAT_ID" ]; then
    echo "Error: TELEGRAM_HOME_CHANNEL not set" >&2
    exit 1
fi

API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"
PARSE_MODE="${TELEGRAM_PARSE_MODE:-Markdown}"

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would POST to ${API_BASE}/bot<TOKEN>/sendMessage"
    echo "[dry-run]   chat_id=$CHAT_ID"
    echo "[dry-run]   parse_mode=$PARSE_MODE"
    echo "[dry-run]   text=${MESSAGE:0:200}$([ ${#MESSAGE} -gt 200 ] && echo '...')"
    exit 0
fi

# Send via Telegram Bot API. proxychains is intentionally NOT bypassed here —
# Telegram traffic is the reason proxychains exists on the gateway.
RESPONSE=$(curl -sS -X POST "${API_BASE}/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    --max-time 30 \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="$PARSE_MODE" \
    --data-urlencode "text=$MESSAGE")

AUDIT="/opt/data/skills/custom/audit-log/scripts/log_action.sh"
PREVIEW="${MESSAGE:0:120}"
[ ${#MESSAGE} -gt 120 ] && PREVIEW="${PREVIEW}..."

if echo "$RESPONSE" | jq -e '.ok == true' >/dev/null 2>&1; then
    MSG_ID=$(echo "$RESPONSE" | jq -r '.result.message_id')
    echo "Relayed to Telegram (message_id=$MSG_ID)"
    [ -x "$AUDIT" ] && bash "$AUDIT" relay-to-user "$PREVIEW" success 2>/dev/null || true
    exit 0
else
    ERR=$(echo "$RESPONSE" | jq -r '.description // .error // "unknown error"' 2>/dev/null || echo "$RESPONSE")
    echo "Relay failed: $ERR" >&2
    [ -x "$AUDIT" ] && bash "$AUDIT" relay-to-user "$PREVIEW" failure 2>/dev/null || true
    exit 1
fi
