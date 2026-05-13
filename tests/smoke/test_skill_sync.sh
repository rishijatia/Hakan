#!/bin/bash
# test_skill_sync.sh — verify GitHub→volume skill sync put files at expected paths.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="skill-sync"

# Skills that should exist on BOTH apps (call-agent, audit-log are shared).
SHARED_SKILLS=(
    "call-agent/SKILL.md"
    "call-agent/scripts/call_agent.sh"
    "call-agent/references/agents.yaml"
    "audit-log/SKILL.md"
    "audit-log/scripts/log_action.sh"
    "audit-log/scripts/audit_query.sh"
)

# Skills that should exist on the SQUAD only.
SQUAD_ONLY_SKILLS=(
    "tech-lead/SKILL.md"
    "tech-lead/references/repo_whitelist.yaml"
)

check_app_skills() {
    local app="$1"; shift
    local skills=("$@")
    for skill in "${skills[@]}"; do
        local path="/opt/data/skills/custom/$skill"
        if flyssh "$app" "test -f $path" >/dev/null 2>&1; then
            # If it's a .sh file, also verify executable.
            if [[ "$skill" == *.sh ]]; then
                if flyssh "$app" "test -x $path" >/dev/null 2>&1; then
                    pass "$TEST: $app has $skill (executable)"
                else
                    fail "$TEST: $app has $skill but not executable" ""
                    FAILED=$((FAILED+1))
                fi
            else
                pass "$TEST: $app has $skill"
            fi
        else
            fail "$TEST: $app missing $skill" "expected at $path"
            FAILED=$((FAILED+1))
        fi
    done
}

check_app_skills "$GATEWAY_APP" "${SHARED_SKILLS[@]}"
check_app_skills "$SQUAD_APP" "${SHARED_SKILLS[@]}"
check_app_skills "$SQUAD_APP" "${SQUAD_ONLY_SKILLS[@]}"

exit "$FAILED"
