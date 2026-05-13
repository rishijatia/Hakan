#!/bin/bash
# test_relay_protocol.sh — verify the [[RELAY]]...[[/RELAY]] protocol works
# end-to-end: peer agent calls gateway with --relay, gateway extracts the
# content, pushes to Telegram, audit-logs the action.
#
# Pairs with test_relay_to_user.sh (which exercises the gateway-only path).
# This one validates the cross-agent protocol: squad → gateway → Telegram.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="relay-protocol"

MARKER="protocol-smoke-$(date +%s)"
MESSAGE="[SMOKE] cross-agent relay protocol test ${MARKER} - please ignore."

# 1. Squad calls gateway with --relay flag. This should:
#    a) Cause the gateway to invoke relay_to_user.sh
#    b) Push the message to Rishi's Telegram
#    c) Audit-log the relay
out=$(flyssh "$SQUAD_APP" "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh --relay gateway '$MESSAGE'" || true)

# Gateway should respond with something that indicates the relay happened.
# Don't gate on exact phrasing — check by audit log instead (the source of truth).
sleep 2

# 2. Gateway audit log should now have a relay-to-user entry with our marker.
log_out=$(flyssh "$GATEWAY_APP" "tail -30 /opt/data/logs/audit.log" || true)
if echo "$log_out" | grep -F "$MARKER" | grep -q "relay-to-user"; then
    pass "$TEST: gateway invoked relay_to_user.sh for the marker prompt"
else
    fail "$TEST: gateway did NOT relay; audit log shows no relay-to-user entry with marker" "marker: $MARKER"
    fail "$TEST: gateway response preview" "${out:0:300}..."
    FAILED=$((FAILED+1))
fi

# 3. The relay must have succeeded (outcome=success in audit).
if echo "$log_out" | grep -F "$MARKER" | grep -F 'relay-to-user' | grep -q '"outcome":"success"'; then
    pass "$TEST: relay audit entry shows outcome=success"
else
    # If outcome failed, the audit entry exists but with outcome=failure.
    # Still treats it as a separate issue from "didn't relay at all."
    if echo "$log_out" | grep -F "$MARKER" | grep -q '"outcome":"failure"'; then
        fail "$TEST: relay was attempted but Telegram API returned failure" "see audit"
        FAILED=$((FAILED+1))
    fi
    # If no marker entry at all, the previous check already failed.
fi

# 4. Squad's own audit log should record the peer-call.
squad_log=$(flyssh "$SQUAD_APP" "tail -10 /opt/data/logs/audit.log" || true)
if echo "$squad_log" | grep -F "$MARKER" | grep -q "peer-call"; then
    pass "$TEST: squad audit recorded the outbound peer-call"
else
    fail "$TEST: squad audit missing peer-call entry for marker" "marker: $MARKER"
    FAILED=$((FAILED+1))
fi

exit "$FAILED"
