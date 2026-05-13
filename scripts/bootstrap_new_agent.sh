#!/bin/bash
# bootstrap_new_agent.sh — scaffold a new Hermes agent for the Hakan system.
#
# Usage:
#   bash scripts/bootstrap_new_agent.sh <agent-name> [agent-title] [agent-description]
#
# Example:
#   bash scripts/bootstrap_new_agent.sh research "Research Agent" \
#     "Deep research on technical topics, market questions, etc."
#
# What it does:
#   1. Creates flyio-<agent-name>/ from templates/agent/ (fly.toml,
#      Dockerfile, start.sh, SOUL.md).
#   2. Adds the agent to skills/custom/call-agent/references/agents.yaml.
#   3. Adds a stub Per-Agent Rules entry to shared/peer_rules.md.
#   4. Adds a stub Layer 3 smoke test at tests/smoke/test_<agent>_health.sh.
#   5. Prints the manual Fly.io commands you still need to run.
#
# Idempotent guard: refuses to overwrite an existing flyio-<agent-name>/ dir.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

AGENT_NAME="${1:-}"
AGENT_TITLE="${2:-}"
AGENT_DESCRIPTION="${3:-}"

if [ -z "$AGENT_NAME" ]; then
    cat >&2 <<USAGE
Usage: $0 <agent-name> [agent-title] [agent-description]

  agent-name      lowercase, hyphenated (e.g., "research", "designer", "monitor")
  agent-title     human-readable title (default: derived from agent-name)
  agent-description  one-line role description (default: a placeholder)

Examples:
  $0 research "Research Agent" "Deep research on technical topics."
  $0 designer
USAGE
    exit 1
fi

# Validate agent name.
if ! [[ "$AGENT_NAME" =~ ^[a-z][a-z0-9-]*$ ]]; then
    echo "✗ agent name must be lowercase letters/digits/hyphens, starting with a letter." >&2
    exit 1
fi

# Default title/description.
AGENT_TITLE="${AGENT_TITLE:-$(echo "$AGENT_NAME" | sed -e 's/-/ /g' -e 's/\b./\U&/g') Agent}"
AGENT_DESCRIPTION="${AGENT_DESCRIPTION:-Specialized Hermes agent. Replace this description with what this agent specifically does.}"

# Underscore form for volume names (Fly volumes don't allow hyphens).
AGENT_NAME_UNDERSCORE="$(echo "$AGENT_NAME" | tr - _)"
AGENT_KEY_ENV="$(echo "$AGENT_NAME_UNDERSCORE" | tr a-z A-Z)_API_KEY"

DEST_DIR="flyio-$AGENT_NAME"
if [ -e "$DEST_DIR" ]; then
    echo "✗ $DEST_DIR/ already exists. Refusing to overwrite." >&2
    exit 1
fi

echo "===== Bootstrapping agent: $AGENT_NAME ====="
echo "  Title:       $AGENT_TITLE"
echo "  Description: $AGENT_DESCRIPTION"
echo "  Directory:   $DEST_DIR/"
echo

# --- 1. Scaffold flyio-<name>/ from templates/agent/ ---
echo "→ Scaffolding $DEST_DIR/ from templates/agent/..."
mkdir -p "$DEST_DIR"
for src in templates/agent/*; do
    fname=$(basename "$src")
    dst="$DEST_DIR/$fname"
    sed -e "s|{{AGENT_NAME}}|$AGENT_NAME|g" \
        -e "s|{{AGENT_TITLE}}|$AGENT_TITLE|g" \
        -e "s|{{AGENT_DESCRIPTION}}|$AGENT_DESCRIPTION|g" \
        -e "s|{{AGENT_NAME_UNDERSCORE}}|$AGENT_NAME_UNDERSCORE|g" \
        "$src" > "$dst"
    case "$fname" in *.sh) chmod +x "$dst" ;; esac
    echo "  ✓ $dst"
done

# --- 2. Register agent in call-agent registry ---
REGISTRY="skills/custom/call-agent/references/agents.yaml"
if grep -q "name: $AGENT_NAME$" "$REGISTRY"; then
    echo "→ $REGISTRY already lists '$AGENT_NAME' — skipping registry update."
else
    echo "→ Adding '$AGENT_NAME' to $REGISTRY..."
    cat >> "$REGISTRY" <<YAML

  - name: $AGENT_NAME
    url: http://hermes-$AGENT_NAME.internal:8642
    api_key_env: $AGENT_KEY_ENV
    description: |
      $AGENT_TITLE. $AGENT_DESCRIPTION
YAML
    echo "  ✓ $REGISTRY"
fi

# --- 3. Add stub entry to shared/peer_rules.md ---
PEER_RULES="shared/peer_rules.md"
if grep -q "^### \`$AGENT_NAME\` " "$PEER_RULES"; then
    echo "→ $PEER_RULES already has section for '$AGENT_NAME' — skipping."
else
    echo "→ Adding Per-Agent Rules stub for '$AGENT_NAME' to $PEER_RULES..."
    cat >> "$PEER_RULES" <<MD

### \`$AGENT_NAME\` ($AGENT_TITLE)

Specific rules (replace this stub):
- TODO: list what this agent will refuse on guardrail grounds.
- TODO: list anything peers must not ask this agent to do.
MD
    echo "  ✓ $PEER_RULES (TODO entries — flesh out before deploy)"
fi

# --- 4. Stub Layer 3 smoke test ---
SMOKE_TEST="tests/smoke/test_${AGENT_NAME}_health.sh"
if [ -f "$SMOKE_TEST" ]; then
    echo "→ $SMOKE_TEST already exists — skipping."
else
    echo "→ Creating stub smoke test $SMOKE_TEST..."
    cat > "$SMOKE_TEST" <<BASH
#!/bin/bash
# test_${AGENT_NAME}_health.sh — basic reachability + identity check for the
# $AGENT_TITLE on hermes-$AGENT_NAME.internal:8642.
set -euo pipefail
DIR="\$(cd "\$(dirname "\${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "\$DIR/_lib.sh"

FAILED=0
TEST="$AGENT_NAME-health"
APP="hermes-$AGENT_NAME"

# 1. Gateway can reach this agent's /health endpoint over 6PN.
out=\$(flyssh "\$GATEWAY_APP" "curl -sS -o /dev/null -w '%{http_code}' http://\$APP.internal:8642/health" || true)
if [ "\$(echo "\$out" | tail -n1)" = "200" ]; then
    pass "\$TEST: gateway → \$APP /health (HTTP 200)"
else
    fail "\$TEST: gateway → \$APP /health" "got: \$out"
    FAILED=\$((FAILED+1))
fi

# 2. Identity check — agent should know who it is when called.
out=\$(flyssh "\$GATEWAY_APP" "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh $AGENT_NAME 'Reply with one short sentence: who are you?'" || true)
if assert_contains "\$out" "$AGENT_TITLE" "\$TEST: identity mentions \$AGENT_TITLE"; then
    pass "\$TEST: chat completion succeeded and identity confirmed"
else
    FAILED=\$((FAILED+1))
fi

exit "\$FAILED"
BASH
    chmod +x "$SMOKE_TEST"
    echo "  ✓ $SMOKE_TEST"
fi

# --- 5. Print next manual steps ---
cat <<NEXT

===== Local scaffolding complete =====

Files created:
  • $DEST_DIR/                            (fly.toml, Dockerfile, start.sh, SOUL.md)
  • Updated $REGISTRY
  • Updated $PEER_RULES (TODO stub — flesh out before deploy)
  • $SMOKE_TEST                                  (stub)

────────────────────────────────────────────────────────────
Manual steps (Fly.io side — needs your auth):
────────────────────────────────────────────────────────────

1) Create the Fly app and volume:

   fly apps create hermes-$AGENT_NAME
   fly volumes create ${AGENT_NAME_UNDERSCORE}_data -a hermes-$AGENT_NAME --region fra --size 3 --yes

2) Generate this agent's API key and save it locally (you'll need it on the peer apps):

   THIS_KEY=\$(openssl rand -hex 32)
   echo "Save this value (you'll paste it on peer apps): \$THIS_KEY"

3) Set the new agent's secrets:

   fly secrets set \\
     OPENROUTER_API_KEY=<your OpenRouter key> \\
     GITHUB_PAT=<your fine-grained GitHub PAT> \\
     API_SERVER_KEY=\$THIS_KEY \\
     -a hermes-$AGENT_NAME

4) Give the new agent bearer tokens for EVERY existing peer it should be able to call:

   # First, fetch each existing peer's API_SERVER_KEY (you may have saved it
   # when you created the peer; otherwise SSH in and 'printenv API_SERVER_KEY').
   fly secrets set \\
     GATEWAY_API_KEY=<gateway's API_SERVER_KEY> \\
     SQUAD_API_KEY=<squad's API_SERVER_KEY> \\
     -a hermes-$AGENT_NAME

5) Give EVERY existing peer the new agent's bearer token so they can call it:

   fly secrets set $AGENT_KEY_ENV=\$THIS_KEY -a hermes-gateway
   fly secrets set $AGENT_KEY_ENV=\$THIS_KEY -a hermes-coding-squad

6) Flesh out the role:
   - Edit $DEST_DIR/SOUL.md — replace placeholders, write actual agent-specific rules
   - Edit $PEER_RULES — replace the TODO stub for $AGENT_NAME with real rules
   - Edit $SMOKE_TEST if there are role-specific behaviors to verify

7) Commit and push (CI will run lint + skill tests on the PR):

   git add $DEST_DIR/ $REGISTRY $PEER_RULES $SMOKE_TEST
   git commit -m "Add hermes-$AGENT_NAME agent"
   git push   # open as PR if you're branching; or push to main if you own the repo

8) Deploy:

   fly deploy --config $DEST_DIR/fly.toml --ha=false

9) Smoke-test the whole system (including the new agent):

   bash tests/smoke/run_all_smoke.sh

NEXT
