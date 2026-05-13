#!/bin/bash
# test_audit_query.sh — unit tests for skills/custom/audit-log/scripts/audit_query.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

SCRIPT="$(git rev-parse --show-toplevel)/skills/custom/audit-log/scripts/audit_query.sh"
echo "→ audit-log/audit_query unit tests"

# Fixture: a temp log with known entries.
TMP=$(mktest)
export HERMES_HOME="$TMP"
mkdir -p "$TMP/logs"
LOG="$TMP/logs/audit.log"

cat > "$LOG" <<'JSON'
{"ts":"2026-05-01T10:00:00Z","agent":"hermes-gateway","action":"peer-call","description":"call A","outcome":"success"}
{"ts":"2026-05-02T10:00:00Z","agent":"hermes-coding-squad","action":"pr-open","description":"PR #1","outcome":"success"}
{"ts":"2026-05-03T10:00:00Z","agent":"hermes-gateway","action":"peer-call","description":"call B","outcome":"failure"}
{"ts":"2026-05-04T10:00:00Z","agent":"hermes-coding-squad","action":"task-start","description":"work begins","outcome":"pending"}
{"ts":"2026-05-05T10:00:00Z","agent":"hermes-gateway","action":"peer-call","description":"call C","outcome":"success"}
JSON

# 1. Default (no args) returns all entries (≤20)
out=$(bash "$SCRIPT" 2>&1)
count=$(echo "$out" | grep -c "peer-call\|pr-open\|task-start" || true)
assert_eq "default returns all 5 entries" "$count" "5"

# 2. -n limits output
out=$(bash "$SCRIPT" -n 2 2>&1)
count=$(echo "$out" | grep -c "peer-call\|pr-open\|task-start" || true)
assert_eq "-n 2 returns only 2 entries" "$count" "2"

# 3. --agent filter
out=$(bash "$SCRIPT" --agent hermes-gateway 2>&1)
gateway_count=$(echo "$out" | grep -c "hermes-gateway" || true)
squad_count=$(echo "$out" | grep -c "hermes-coding-squad" || true)
assert_eq "--agent returns 3 gateway entries" "$gateway_count" "3"
assert_eq "--agent excludes squad entries" "$squad_count" "0"

# 4. --action filter
out=$(bash "$SCRIPT" --action peer-call 2>&1)
peer_count=$(echo "$out" | grep -c "peer-call" || true)
pr_count=$(echo "$out" | grep -c "pr-open" || true)
assert_eq "--action peer-call returns 3 entries" "$peer_count" "3"
assert_eq "--action peer-call excludes pr-open" "$pr_count" "0"

# 5. --since cutoff
out=$(bash "$SCRIPT" --since "2026-05-04" 2>&1)
later_count=$(echo "$out" | grep -cE "2026-05-04|2026-05-05" || true)
earlier_count=$(echo "$out" | grep -cE "2026-05-01|2026-05-02|2026-05-03" || true)
assert_eq "--since includes 2 entries on/after cutoff" "$later_count" "2"
assert_eq "--since excludes 3 earlier entries" "$earlier_count" "0"

# 6. --json returns raw JSONL
out=$(bash "$SCRIPT" --json -n 1 2>&1)
if echo "$out" | python3 -c "import sys, json; [json.loads(l) for l in sys.stdin if l.strip()]" 2>/dev/null; then
    t_pass "--json produces valid JSONL"
else
    t_fail "--json output is not valid JSONL" "got: $out"
fi

# 7. Empty log handled gracefully
rm "$LOG"
touch "$LOG"
out=$(bash "$SCRIPT" 2>&1) || true
assert_contains "empty log reported" "$out" "empty"

t_summary
