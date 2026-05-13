#!/bin/bash
# test_log_action.sh — unit tests for skills/custom/audit-log/scripts/log_action.sh
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

SCRIPT="$(git rev-parse --show-toplevel)/skills/custom/audit-log/scripts/log_action.sh"
echo "→ audit-log/log_action unit tests"

# Use a temp HERMES_HOME so we don't touch real logs.
TMP=$(mktest)
export HERMES_HOME="$TMP"
export FLY_APP_NAME="test-app"

LOG_FILE="$TMP/logs/audit.log"

# 1. Missing args → error
out=$(bash "$SCRIPT" 2>&1) || true
assert_contains "no-args prints usage" "$out" "Usage:"

out=$(bash "$SCRIPT" only-action 2>&1) || true
assert_contains "one-arg prints usage" "$out" "Usage:"

# 2. Valid call writes a single JSON line
bash "$SCRIPT" peer-call "test call A" success >/dev/null
[ -f "$LOG_FILE" ] && t_pass "log file created" || t_fail "log file missing"

# 3. The line is valid JSON with expected fields
line=$(tail -n1 "$LOG_FILE")
if echo "$line" | python3 -c "
import sys, json
e = json.loads(sys.stdin.read())
assert e['agent'] == 'test-app', f'wrong agent: {e[\"agent\"]}'
assert e['action'] == 'peer-call', f'wrong action: {e[\"action\"]}'
assert e['description'] == 'test call A', f'wrong description: {e[\"description\"]}'
assert e['outcome'] == 'success', f'wrong outcome: {e[\"outcome\"]}'
assert 'ts' in e and 'T' in e['ts'] and 'Z' in e['ts'], f'bad ts: {e.get(\"ts\")}'
" 2>/dev/null; then
    t_pass "JSON shape correct (agent, action, description, outcome, ts)"
else
    t_fail "JSON shape wrong" "got: $line"
fi

# 4. Outcome is omitted when empty
bash "$SCRIPT" task-start "no outcome" >/dev/null
line=$(tail -n1 "$LOG_FILE")
if echo "$line" | python3 -c "
import sys, json
e = json.loads(sys.stdin.read())
assert 'outcome' not in e, f'outcome should be omitted, got: {e.get(\"outcome\")}'
" 2>/dev/null; then
    t_pass "outcome field omitted when not provided"
else
    t_fail "outcome field handled wrong" "got: $line"
fi

# 5. Multiple calls append (don't overwrite)
before=$(wc -l < "$LOG_FILE")
bash "$SCRIPT" peer-call "third entry" >/dev/null
bash "$SCRIPT" peer-call "fourth entry" >/dev/null
after=$(wc -l < "$LOG_FILE")
assert_eq "appends entries" "$((after - before))" "2"

# 6. Description with special chars (quotes, JSON-breaking) is safely escaped
bash "$SCRIPT" peer-call 'tricky "quotes" and \backslashes' >/dev/null
line=$(tail -n1 "$LOG_FILE")
if echo "$line" | python3 -c "import sys, json; json.loads(sys.stdin.read())" 2>/dev/null; then
    t_pass "special chars escaped properly"
else
    t_fail "special chars broke JSON" "got: $line"
fi

t_summary
