#!/bin/bash
# test_async_dispatch.sh — verify the async dispatch pipeline end-to-end:
#
#   gateway-side dispatch (--async)
#     → squad's /v1/runs accepts (HTTP 202 + run_id)
#     → squad agent recognizes [[ASYNC]] markers
#     → squad emits "started" relay (must arrive in audit log)
#     → squad emits "done" relay (must arrive in audit log)
#     → both relays carry the [task_id=...] prefix for correlation
#
# Squad's actual coding work is intentionally trivial here (a one-liner
# response) so the test stays under 60s. This test isn't measuring task
# quality — it's measuring the dispatch protocol.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="async-dispatch"

# Trivial task — just echo a short ack. Async overhead dominates the timing
# so we keep the payload tiny.
TASK_PROMPT="ASYNC SMOKE: respond with the single word OK as your completion message. This is a synthetic test of the async protocol."

# Squad calls itself via --async (uses the same flow gateway would use).
# We POST from the gateway machine because that's where audit-log lives and
# where the smoke harness can SSH.
out=$(flyssh "$GATEWAY_APP" "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh --async squad '$TASK_PROMPT'" || true)

# 1. Dispatch returns task_id immediately (no waiting for completion).
if echo "$out" | grep -q '^task_id=task-'; then
    pass "$TEST: dispatch returned task_id immediately"
    TASK_ID=$(echo "$out" | grep '^task_id=' | head -1 | sed 's/task_id=//')
else
    fail "$TEST: dispatch did not return task_id" "got: ${out:0:200}..."
    FAILED=$((FAILED+1))
    TASK_ID="" # avoid undefined later
fi

# 2. Gateway audit log records the async dispatch with our task_id.
log_out=$(flyssh "$GATEWAY_APP" "tail -20 /opt/data/logs/audit.log" || true)
if [ -n "$TASK_ID" ] && echo "$log_out" | grep -F "$TASK_ID" | grep -q "async-dispatch"; then
    pass "$TEST: audit recorded async-dispatch with task_id ($TASK_ID)"
else
    fail "$TEST: no async-dispatch audit entry for $TASK_ID" "look at: $log_out"
    FAILED=$((FAILED+1))
fi

# 3. Wait up to 60s for the "started" relay to land in the gateway's audit log.
#    The squad must emit this within its first iteration per the protocol rule.
deadline=$(( $(date +%s) + 60 ))
STARTED_SEEN=false
DONE_SEEN=false
while [ "$(date +%s)" -lt "$deadline" ]; do
    log_out=$(flyssh "$GATEWAY_APP" "tail -30 /opt/data/logs/audit.log" 2>/dev/null || echo "")
    if [ -n "$TASK_ID" ] && echo "$log_out" | grep -F "$TASK_ID" | grep -F "started" | grep -q "relay-to-user"; then
        STARTED_SEEN=true
    fi
    if [ -n "$TASK_ID" ] && echo "$log_out" | grep -F "$TASK_ID" | grep -E "done|failed|refused" | grep -q "relay-to-user"; then
        DONE_SEEN=true
        break
    fi
    sleep 5
done

if [ "$STARTED_SEEN" = true ]; then
    pass "$TEST: squad emitted 'started' relay tagged with $TASK_ID"
else
    fail "$TEST: no 'started' relay observed within 60s for $TASK_ID" ""
    FAILED=$((FAILED+1))
fi

if [ "$DONE_SEEN" = true ]; then
    pass "$TEST: squad emitted terminal relay (done/failed/refused) tagged with $TASK_ID"
else
    fail "$TEST: no terminal relay within 60s for $TASK_ID" "squad may have stalled or skipped the closing relay"
    FAILED=$((FAILED+1))
fi

exit "$FAILED"
