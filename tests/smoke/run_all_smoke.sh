#!/bin/bash
# run_all_smoke.sh — run every smoke test against the live Fly apps.
#
# Usage:
#   bash tests/smoke/run_all_smoke.sh
#   GATEWAY_APP=foo SQUAD_APP=bar bash tests/smoke/run_all_smoke.sh
#
# Exit code: number of tests that failed (0 = all pass).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Tests in a sensible order: cheap → expensive.
# (cheap = SSH/health, expensive = real LLM call).
TESTS=(
    "test_soul_synced.sh"
    "test_config_synced.sh"
    "test_skill_sync.sh"
    "test_peer_to_peer.sh"
    "test_audit_log.sh"
    "test_tech_lead_refusal.sh"
    "test_agent_refusal.sh"
    "test_relay_to_user.sh"
    "test_relay_protocol.sh"
    "test_async_dispatch.sh"
)

PASS=0
FAIL=0
TOTAL_START=$(date +%s)

echo "===== Hakan smoke tests ====="
echo "  gateway: ${GATEWAY_APP:-hermes-gateway}"
echo "  squad:   ${SQUAD_APP:-hermes-coding-squad}"
echo

for test in "${TESTS[@]}"; do
    echo "── $test ──"
    start=$(date +%s)
    if bash "$DIR/$test"; then
        elapsed=$(( $(date +%s) - start ))
        echo "  └─ ${elapsed}s"
        PASS=$((PASS+1))
    else
        elapsed=$(( $(date +%s) - start ))
        echo "  └─ FAILED (${elapsed}s)"
        FAIL=$((FAIL+1))
    fi
    echo
done

TOTAL_ELAPSED=$(( $(date +%s) - TOTAL_START ))
echo "============================="
echo "Result: $PASS passed, $FAIL failed (${TOTAL_ELAPSED}s total)"

exit "$FAIL"
