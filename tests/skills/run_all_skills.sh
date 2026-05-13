#!/bin/bash
# run_all_skills.sh — run every Layer 2 skill unit test.
#
# Usage:
#   bash tests/skills/run_all_skills.sh
#
# Exit code: number of failed assertions across all tests.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TESTS=(
    "test_call_agent.sh"
    "test_log_action.sh"
    "test_audit_query.sh"
    "test_bootstrap_new_agent.sh"
    "test_relay_to_user.sh"
)

TOTAL_FAIL=0
START=$(date +%s)

echo "===== Hakan skill unit tests ====="
echo

for test in "${TESTS[@]}"; do
    if bash "$DIR/$test"; then
        :
    else
        # Each test exits with its fail count; accumulate.
        TOTAL_FAIL=$((TOTAL_FAIL + $?))
    fi
    echo
done

ELAPSED=$(( $(date +%s) - START ))
if [ "$TOTAL_FAIL" -eq 0 ]; then
    echo "================================="
    echo "✓ All skill unit tests passed (${ELAPSED}s)"
else
    echo "================================="
    echo "✗ $TOTAL_FAIL test(s) failed (${ELAPSED}s)" >&2
fi

exit "$TOTAL_FAIL"
