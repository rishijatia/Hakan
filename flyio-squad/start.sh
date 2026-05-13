#!/bin/bash
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
REPO="rishijatia/Hakan"
BRANCH="main"

# Sync the squad's SOUL.md from GitHub (repo is source of truth)
sync_from_github() {
    local src="$1"
    local dst="$2"
    local url="https://raw.githubusercontent.com/$REPO/$BRANCH/$src"
    local args=(-fsSL "$url" -o "$dst")
    [ -n "$GITHUB_TOKEN" ] && args+=(-H "Authorization: token $GITHUB_TOKEN")
    if curl "${args[@]}"; then
        echo "Synced $src from GitHub"
    else
        echo "Warning: could not sync $src — using existing file"
    fi
}

# Sync runtime config from the repo if a squad-specific config.yaml exists.
# Same principle as SOUL.md: repo is source of truth, volume edits are not
# persisted. Today the squad uses Hermes defaults bootstrapped by the
# entrypoint, so this is a no-op unless flyio-squad/config.yaml is added.
sync_from_github "flyio-squad/config.yaml" "$HERMES_HOME/config.yaml" || true

sync_from_github "flyio-squad/SOUL.md" "$HERMES_HOME/SOUL.md.base"

# Assemble SOUL.md with shared guardrails FIRST (dominant context). See
# flyio/start.sh for the reasoning — the order is load-bearing.
sync_from_github "shared/guardrails.md" "$HERMES_HOME/.shared_guardrails.md"
sync_from_github "shared/peer_rules.md" "$HERMES_HOME/.shared_peer_rules.md"
{
    cat "$HERMES_HOME/.shared_guardrails.md"
    echo
    echo "---"
    echo
    cat "$HERMES_HOME/.shared_peer_rules.md"
    echo
    echo "---"
    echo
    cat "$HERMES_HOME/SOUL.md.base"
} > "$HERMES_HOME/SOUL.md"
rm -f "$HERMES_HOME/SOUL.md.base" "$HERMES_HOME/.shared_guardrails.md" "$HERMES_HOME/.shared_peer_rules.md"

# Sync the skills/custom/ tree from the GitHub repo. Source of truth lives in
# the repo so all agents stay in lockstep; volume edits are not persisted.
sync_skills_from_github() {
    if [ -z "${GITHUB_PAT:-}" ]; then
        echo "Warning: GITHUB_PAT not set — skipping skills sync (using existing files)"
        return
    fi
    local tmpdir
    tmpdir=$(mktemp -d)
    local clone_url="https://x-access-token:${GITHUB_PAT}@github.com/${REPO}.git"
    if git clone --quiet --depth=1 --branch "$BRANCH" "$clone_url" "$tmpdir" 2>/dev/null; then
        if [ -d "$tmpdir/skills/custom" ]; then
            mkdir -p "$HERMES_HOME/skills"
            rm -rf "$HERMES_HOME/skills/custom"
            cp -r "$tmpdir/skills/custom" "$HERMES_HOME/skills/custom"
            find "$HERMES_HOME/skills/custom" -name '*.sh' -exec chmod +x {} \;
            echo "Synced skills/custom/ from GitHub ($(find "$HERMES_HOME/skills/custom" -name 'SKILL.md' | wc -l) skill(s))"
        else
            echo "Warning: skills/custom/ not present in repo — keeping existing files"
        fi
    else
        echo "Warning: git clone failed — keeping existing skills"
    fi
    rm -rf "$tmpdir"
}
sync_skills_from_github

exec /opt/hermes/docker/entrypoint.sh "$@"
