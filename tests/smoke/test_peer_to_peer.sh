#!/bin/bash
# test_peer_to_peer.sh — verify gateway ↔ squad reachability + auth over 6PN.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="peer-to-peer"

# 1. Gateway → Squad /health
out=$(flyssh "$GATEWAY_APP" "curl -sS -o /dev/null -w '%{http_code}' http://${SQUAD_APP}.internal:8642/health" || true)
if [ "$(echo "$out" | tail -n1)" = "200" ]; then
    pass "$TEST: gateway → squad /health (HTTP 200)"
else
    fail "$TEST: gateway → squad /health" "got: $out"
    FAILED=$((FAILED+1))
fi

# 2. Squad → Gateway /health
out=$(flyssh "$SQUAD_APP" "curl -sS -o /dev/null -w '%{http_code}' http://${GATEWAY_APP}.internal:8642/health" || true)
if [ "$(echo "$out" | tail -n1)" = "200" ]; then
    pass "$TEST: squad → gateway /health (HTTP 200)"
else
    fail "$TEST: squad → gateway /health" "got: $out"
    FAILED=$((FAILED+1))
fi

# 3. Gateway → Squad authenticated chat completion (real LLM round-trip).
out=$(flyssh "$GATEWAY_APP" \
    "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh squad 'smoke: reply with one word OK'" \
    || true)
if assert_contains "$out" "OK" "$TEST: gateway → squad auth+LLM"; then
    pass "$TEST: gateway → squad chat completion (auth + LLM round-trip)"
else
    FAILED=$((FAILED+1))
fi

# 4. Squad → Gateway authenticated chat completion.
out=$(flyssh "$SQUAD_APP" \
    "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh gateway 'smoke: reply with one word OK'" \
    || true)
if assert_contains "$out" "OK" "$TEST: squad → gateway auth+LLM"; then
    pass "$TEST: squad → gateway chat completion (auth + LLM round-trip)"
else
    FAILED=$((FAILED+1))
fi

exit "$FAILED"
