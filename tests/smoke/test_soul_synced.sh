#!/bin/bash
# test_soul_synced.sh — verify each app's on-volume SOUL.md is assembled
# correctly from the role-specific base + shared/guardrails.md + shared/peer_rules.md.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAILED=0
TEST="soul-synced"

# Picks one stable marker line from each of the three source files. The
# assembled SOUL.md on the volume must contain all three.
# Use short markers so heading-text tweaks don't break this test.
GUARDRAILS_MARKER="Shared Guardrails"
PEER_RULES_MARKER="Peer Rules"

check_soul() {
    local app="$1" repo_base_path="$2" base_marker="$3"
    local remote
    remote=$(flyssh "$app" "cat /opt/data/SOUL.md" 2>/dev/null)

    if [ ! -f "$REPO_ROOT/$repo_base_path" ]; then
        fail "$TEST: $repo_base_path missing locally"
        return 1
    fi

    # 1. role-specific base content present
    if echo "$remote" | grep -qF "$base_marker"; then
        pass "$TEST: $app SOUL.md includes role-specific base ($repo_base_path)"
    else
        fail "$TEST: $app missing role-specific marker" "expected: $base_marker"
        FAILED=$((FAILED+1))
    fi

    # 2. shared/guardrails.md content present
    if echo "$remote" | grep -qF "$GUARDRAILS_MARKER"; then
        pass "$TEST: $app SOUL.md includes shared/guardrails.md"
    else
        fail "$TEST: $app missing shared/guardrails.md content"
        FAILED=$((FAILED+1))
    fi

    # 3. shared/peer_rules.md content present
    if echo "$remote" | grep -qF "$PEER_RULES_MARKER"; then
        pass "$TEST: $app SOUL.md includes shared/peer_rules.md"
    else
        fail "$TEST: $app missing shared/peer_rules.md content"
        FAILED=$((FAILED+1))
    fi
}

# Gateway and squad use different base SOULs; the marker lines are stable.
check_soul "$GATEWAY_APP" "flyio/SOUL.md"        "Gateway-Specific Rules"
check_soul "$SQUAD_APP"   "flyio-squad/SOUL.md"  "Coding Squad's Tech Lead"

exit "$FAILED"
