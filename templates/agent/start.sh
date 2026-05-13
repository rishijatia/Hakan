#!/bin/bash
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
REPO="rishijatia/Hakan"
BRANCH="main"

# Sync a single file from the GitHub repo (repo is source of truth).
sync_from_github() {
    local src="$1"
    local dst="$2"
    local url="https://raw.githubusercontent.com/$REPO/$BRANCH/$src"
    local args=(-fsSL "$url" -o "$dst")
    [ -n "${GITHUB_PAT:-}" ] && args+=(-H "Authorization: token $GITHUB_PAT")
    if curl "${args[@]}"; then
        echo "Synced $src from GitHub"
    else
        echo "Warning: could not sync $src — using existing file"
    fi
}

# Assemble SOUL.md = role-specific base + shared/guardrails.md + shared/peer_rules.md.
sync_from_github "flyio-{{AGENT_NAME}}/SOUL.md" "$HERMES_HOME/SOUL.md.base"
sync_from_github "shared/guardrails.md" "$HERMES_HOME/.shared_guardrails.md"
sync_from_github "shared/peer_rules.md" "$HERMES_HOME/.shared_peer_rules.md"
{
    # Order matters: shared guardrails FIRST (dominant context), role last.
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

# Sync the skills/custom/ tree from GitHub on every boot.
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
        fi
    else
        echo "Warning: git clone failed — keeping existing skills"
    fi
    rm -rf "$tmpdir"
}
sync_skills_from_github

# {{AGENT_NAME}} doesn't need proxychains by default (no Telegram outbound
# from this agent). If you add a Telegram bot or another service that
# needs the residential proxy, mirror the proxychains setup from
# flyio/start.sh including the `localnet fdaa::/16` bypass for 6PN.
exec /opt/hermes/docker/entrypoint.sh "$@"
