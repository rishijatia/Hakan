#!/bin/bash
# test_relay_to_user.sh — unit tests for skills/custom/relay-to-user/scripts/relay_to_user.sh
#
# Network call (Telegram Bot API) is exercised only in --dry-run mode here;
# the real POST is covered by the Layer 3 smoke test against the live bot.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

SCRIPT="$(git rev-parse --show-toplevel)/skills/custom/relay-to-user/scripts/relay_to_user.sh"
echo "→ relay-to-user unit tests"

# 1. No args → usage
out=$(bash "$SCRIPT" 2>&1) || true
assert_contains "no-args prints usage" "$out" "Usage:"

# 2. Missing TELEGRAM_BOT_TOKEN → clear error
unset TELEGRAM_BOT_TOKEN TELEGRAM_HOME_CHANNEL TELEGRAM_API_BASE TELEGRAM_PARSE_MODE
out=$(bash "$SCRIPT" "hello" 2>&1) || true
assert_contains "missing bot token error" "$out" "TELEGRAM_BOT_TOKEN"

# 3. Missing TELEGRAM_HOME_CHANNEL → clear error
export TELEGRAM_BOT_TOKEN="fake:token"
out=$(bash "$SCRIPT" "hello" 2>&1) || true
assert_contains "missing chat-id error" "$out" "TELEGRAM_HOME_CHANNEL"

# 4. --dry-run with both env vars set: prints what would be sent, never hits network
export TELEGRAM_HOME_CHANNEL="12345"
out=$(bash "$SCRIPT" --dry-run "hello world" 2>&1)
assert_contains "dry-run mentions API endpoint" "$out" "sendMessage"
assert_contains "dry-run shows chat_id"        "$out" "chat_id=12345"
assert_contains "dry-run shows message text"   "$out" "hello world"

# 5. Long message truncated in preview (>200 chars shown with ellipsis)
LONG=$(printf 'x%.0s' {1..250})
out=$(bash "$SCRIPT" --dry-run "$LONG" 2>&1)
assert_contains "long message truncated with ellipsis" "$out" "..."

# 6. Message with special chars (quotes, backslashes, newlines) doesn't crash dry-run
out=$(bash "$SCRIPT" --dry-run 'msg with "quotes" \backslash and $vars' 2>&1)
assert_contains "special chars survive dry-run" "$out" "quotes"

# 7. stdin mode: -
out=$(echo "piped message" | bash "$SCRIPT" --dry-run - 2>&1)
assert_contains "stdin mode reads from pipe" "$out" "piped message"

# 8. Empty stdin → error
out=$(echo "" | bash "$SCRIPT" --dry-run - 2>&1) || true
assert_contains "empty stdin rejected" "$out" "Usage:"

t_summary
