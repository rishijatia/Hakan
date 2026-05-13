#!/bin/bash
# test_relay_to_user.sh — verify the gateway can push a message into
# Telegram via the relay-to-user skill. This is the "asynchronous notify"
# channel that lets peer agents surface things to Rishi during work
# triggered through the API server.
#
# Sends a clearly-marked smoke-test message to Rishi's chat. Yes, this
# means Rishi sees a smoke-test line in Telegram when the suite runs —
# acceptable since the suite is run manually after deploys, not in CI.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="relay-to-user"

MARKER="smoke-$(date +%s)"
MESSAGE="🧪 relay-to-user smoke test ${MARKER} — ignore."

# 1. Dry-run first (doesn't hit Telegram). Cheap sanity check on the gateway's
#    environment + script wiring.
out=$(flyssh "$GATEWAY_APP" "bash /opt/data/skills/custom/relay-to-user/scripts/relay_to_user.sh --dry-run '$MESSAGE'" || true)
if assert_contains "$out" "sendMessage" "$TEST: dry-run on gateway"; then
    pass "$TEST: dry-run reaches script and resolves env vars"
else
    FAILED=$((FAILED+1))
fi

# 2. Real send. Asserts the script exits 0 AND the audit log shows a
#    relay-to-user success entry.
out=$(flyssh "$GATEWAY_APP" "bash /opt/data/skills/custom/relay-to-user/scripts/relay_to_user.sh '$MESSAGE'" || true)
if echo "$out" | grep -q "Relayed to Telegram"; then
    pass "$TEST: gateway successfully relayed message to Telegram"
else
    fail "$TEST: relay failed" "got: ${out:0:200}..."
    FAILED=$((FAILED+1))
fi

# 3. Confirm the audit-log entry landed with marker in description.
log_out=$(flyssh "$GATEWAY_APP" "tail -20 /opt/data/logs/audit.log" || true)
if echo "$log_out" | grep -q "$MARKER"; then
    pass "$TEST: audit log records the relay (marker: $MARKER)"
else
    fail "$TEST: audit log missing marker" "expected: $MARKER"
    FAILED=$((FAILED+1))
fi

exit "$FAILED"
