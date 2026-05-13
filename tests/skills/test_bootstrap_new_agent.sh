#!/bin/bash
# test_bootstrap_new_agent.sh — unit tests for scripts/bootstrap_new_agent.sh
#
# Runs the script in an ephemeral git worktree so the live repo isn't touched.
# Asserts: scaffold files exist, placeholders are substituted, registry +
# peer_rules.md + smoke test stub are updated, generated shell + YAML pass
# the same lint we run in CI.
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
echo "→ bootstrap_new_agent unit tests"

WORKTREE=$(mktest)/worktree
trap 'cd "$REPO_ROOT" 2>/dev/null; git worktree remove --force "$WORKTREE" 2>/dev/null || true' EXIT

# Make a worktree from HEAD so we can mutate without affecting the live tree.
git worktree add --detach "$WORKTREE" HEAD --quiet 2>/dev/null

cd "$WORKTREE" || exit 1

AGENT="bootstraptest"
AGENT_TITLE="Bootstrap Test Agent"
AGENT_DESC="Synthetic agent used by the test suite to verify the bootstrap script. Not deployed."

# 1. Script refuses bad input.
out=$(bash scripts/bootstrap_new_agent.sh 2>&1) || true
assert_contains "no-args prints usage" "$out" "Usage:"

out=$(bash scripts/bootstrap_new_agent.sh "BadName" 2>&1) || true
assert_contains "rejects uppercase agent name" "$out" "lowercase"

out=$(bash scripts/bootstrap_new_agent.sh "1-leading-digit" 2>&1) || true
assert_contains "rejects digit-leading name" "$out" "lowercase"

# 2. Happy path: scaffold a real agent.
bash scripts/bootstrap_new_agent.sh "$AGENT" "$AGENT_TITLE" "$AGENT_DESC" >/dev/null

# 3. Directory + 4 expected files exist.
for f in fly.toml Dockerfile start.sh SOUL.md; do
    if [ -f "flyio-$AGENT/$f" ]; then
        t_pass "scaffolded flyio-$AGENT/$f"
    else
        t_fail "missing flyio-$AGENT/$f"
    fi
done

# 4. No unsubstituted placeholders.
if grep -r '{{AGENT_' "flyio-$AGENT/" >/dev/null 2>&1; then
    t_fail "placeholders remain in scaffolded files" "$(grep -rn '{{AGENT_' "flyio-$AGENT/" | head -3)"
else
    t_pass "all template placeholders substituted"
fi

# 5. Generated start.sh is executable.
if [ -x "flyio-$AGENT/start.sh" ]; then
    t_pass "scaffolded start.sh is executable"
else
    t_fail "scaffolded start.sh not executable"
fi

# 6. fly.toml has the right app name.
if grep -q "^app = 'hermes-$AGENT'" "flyio-$AGENT/fly.toml"; then
    t_pass "fly.toml app name = hermes-$AGENT"
else
    t_fail "fly.toml app name wrong"
fi

# 7. fly.toml volume name uses underscores (not hyphens).
if grep -q "source = \"${AGENT}_data\"" "flyio-$AGENT/fly.toml"; then
    t_pass "fly.toml volume source uses underscore form"
else
    t_fail "fly.toml volume name wrong" "expected: ${AGENT}_data"
fi

# 8. agents.yaml updated with new entry.
if grep -q "name: $AGENT$" "skills/custom/call-agent/references/agents.yaml"; then
    t_pass "agents.yaml has entry for $AGENT"
else
    t_fail "agents.yaml not updated"
fi

# 9. peer_rules.md has stub section for the new agent.
if grep -q "^### \`$AGENT\` " "shared/peer_rules.md"; then
    t_pass "peer_rules.md has section for $AGENT"
else
    t_fail "peer_rules.md not updated"
fi

# 10. Smoke test stub created.
if [ -x "tests/smoke/test_${AGENT}_health.sh" ]; then
    t_pass "smoke test stub created and executable"
else
    t_fail "smoke test stub missing or not executable"
fi

# 11. Idempotent guard: re-running refuses to overwrite.
out=$(bash scripts/bootstrap_new_agent.sh "$AGENT" 2>&1) || true
assert_contains "refuses to overwrite existing dir" "$out" "already exists"

# 12. Generated shell scripts pass our own lint.
# (Use the worktree's own copy of the lint runner.)
if bash tests/lint/check_shell.sh "flyio-$AGENT/start.sh" >/dev/null 2>&1; then
    t_pass "generated start.sh passes shellcheck"
else
    t_fail "generated start.sh fails shellcheck"
fi

# 13. Generated YAML parses.
if bash tests/lint/check_yaml.sh "skills/custom/call-agent/references/agents.yaml" >/dev/null 2>&1; then
    t_pass "agents.yaml still parses after append"
else
    t_fail "agents.yaml broken after append"
fi

# 14. Generated SOUL.md frontmatter — note: it's a template (no frontmatter),
#     so this isn't required. We only check it exists with the title.
if grep -q "$AGENT_TITLE" "flyio-$AGENT/SOUL.md"; then
    t_pass "SOUL.md contains agent title"
else
    t_fail "SOUL.md missing title"
fi

cd "$REPO_ROOT" || exit 1
t_summary
