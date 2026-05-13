#!/bin/bash
# test_call_agent.sh — unit tests for skills/custom/call-agent/scripts/call_agent.sh
#
# Tests argument parsing, env-var validation, and registry lookup —
# the network call itself is covered by smoke tests.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

SCRIPT="$(git rev-parse --show-toplevel)/skills/custom/call-agent/scripts/call_agent.sh"
echo "→ call-agent unit tests"

# Fixture registry — lets us test lookup without hitting real Fly apps.
TMP=$(mktest)
cat > "$TMP/agents.yaml" <<'YAML'
agents:
  - name: alpha
    url: http://alpha.internal:9999
    api_key_env: ALPHA_KEY
    description: Test agent A
  - name: beta
    url: http://beta.internal:9999
    api_key_env: BETA_KEY
    description: Test agent B
YAML
export AGENTS_YAML="$TMP/agents.yaml"

# 1. No args → usage message
out=$(bash "$SCRIPT" 2>&1) || true
assert_contains "no args prints usage" "$out" "Usage:"
assert_contains "no args lists available agents" "$out" "alpha"

# 2. Unknown agent → clear error
out=$(bash "$SCRIPT" zeta "hi" 2>&1) || true
assert_contains "unknown agent error" "$out" "not found"

# 3. Missing bearer env var → clear error (don't set ALPHA_KEY)
unset ALPHA_KEY
out=$(bash "$SCRIPT" alpha "hi" 2>&1) || true
assert_contains "missing env var error" "$out" "ALPHA_KEY"
assert_contains "missing env var mentions auth" "$out" "empty"

# 4. Empty prompt → error
export ALPHA_KEY="fake-key-for-test"
out=$(bash "$SCRIPT" alpha "" 2>&1) || true
assert_contains "empty prompt rejected" "$out" "empty prompt"

# 5. Registry parsing handles missing yaml gracefully
AGENTS_YAML=/nonexistent/path/agents.yaml
out=$(bash "$SCRIPT" alpha "hi" 2>&1) || true
assert_contains "missing yaml errors" "$out" "not found"

# Restore the fixture for the remaining tests.
export AGENTS_YAML="$TMP/agents.yaml"
export ALPHA_KEY="fake-key-for-test"

# 6. --dry-run prints the payload and never hits the network
out=$(bash "$SCRIPT" --dry-run alpha "hello there" 2>&1)
assert_contains "--dry-run mentions URL" "$out" "alpha.internal:9999"
assert_contains "--dry-run shows prompt in payload" "$out" "hello there"

# 7. --relay wraps the prompt with protocol markers (verify via --dry-run)
out=$(bash "$SCRIPT" --relay --dry-run alpha "PR ready" 2>&1)
assert_contains "--relay adds [[RELAY]] open marker" "$out" "[[RELAY]]"
assert_contains "--relay adds [[/RELAY]] close marker" "$out" "[[/RELAY]]"
assert_contains "--relay wraps the actual prompt"     "$out" "PR ready"

# 8. Without --relay, no markers added
out=$(bash "$SCRIPT" --dry-run alpha "plain message" 2>&1)
assert_not_contains "no relay markers when --relay absent" "$out" "[[RELAY]]"

# 9. Flag ordering shouldn't matter
out=$(bash "$SCRIPT" --dry-run --relay alpha "either order" 2>&1)
assert_contains "--dry-run before --relay still wraps" "$out" "[[RELAY]]"

# 10. --async wraps with [[ASYNC task_id=... reply_to=gateway]] markers and
#     targets /v1/runs instead of /v1/chat/completions.
out=$(bash "$SCRIPT" --async --dry-run alpha "do the thing" 2>&1)
assert_contains "--async adds [[ASYNC marker"        "$out" "[[ASYNC"
assert_contains "--async adds task_id in marker"     "$out" "task_id=task-"
assert_contains "--async adds reply_to in marker"    "$out" "reply_to=gateway"
assert_contains "--async closes with [[/ASYNC]]"     "$out" "[[/ASYNC]]"
assert_contains "--async targets /v1/runs endpoint"  "$out" "/v1/runs"
assert_contains "--async preserves the prompt body"  "$out" "do the thing"

# 11. --async returns task_id summary to stdout (in dry-run)
assert_contains "--async prints task_id"             "$out" "task_id=task-"

# 12. --async + --relay is rejected (mutually exclusive)
out=$(bash "$SCRIPT" --async --relay alpha "x" 2>&1) || true
assert_contains "rejects --async + --relay together" "$out" "mutually exclusive"

# 13. Sync mode (no flags) does NOT emit ASYNC markers
out=$(bash "$SCRIPT" --dry-run alpha "sync only" 2>&1)
assert_not_contains "no ASYNC markers when sync"     "$out" "[[ASYNC"
assert_contains    "sync uses /v1/chat/completions"  "$out" "/v1/chat/completions"

t_summary
