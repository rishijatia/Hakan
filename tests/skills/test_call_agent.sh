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

t_summary
