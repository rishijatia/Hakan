#!/bin/bash
set -e

HERMES_HOME="${HERMES_HOME:-/opt/data}"
REPO="rishijatia/Hakan"
BRANCH="main"

# Sync a file from the GitHub repo (source of truth)
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

# SOUL.md is always overwritten from the repo on boot.
# To change it permanently, open a PR — not edit the volume directly.
# Sync runtime config from the repo. Same principle as SOUL.md: the repo
# is source of truth; volume edits are not persisted across boots. If
# Hermes mutates config.yaml at runtime (model auth, etc.), those changes
# need to be committed back to the repo to survive — or stored as Fly
# secrets / .env instead.
sync_from_github "flyio/config.yaml" "$HERMES_HOME/config.yaml"

sync_from_github "flyio/SOUL.md" "$HERMES_HOME/SOUL.md.base"

# Assemble the final SOUL.md.
# Order matters: shared/guardrails.md goes FIRST so the firewall is the
# dominant context. peer rules second. Role-specific SOUL last — it's the
# personality layer, not the constraints layer. An earlier ordering put the
# role-specific section first and the agent rationalized past the firewall
# ("I'm the gateway, my constraints are different…"). Don't reorder this.
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

# Force API_SERVER_HOST to the literal 6PN IPv6 address.
# proxychains4 (active because PROXY_HOST is set) intercepts getaddrinfo()
# and returns a fake 224.x.x.x address for any hostname like "fly-local-6pn".
# Using FLY_PRIVATE_IP (already an IPv6 literal) bypasses DNS entirely.
if [ -n "${FLY_PRIVATE_IP:-}" ]; then
    export API_SERVER_HOST="$FLY_PRIVATE_IP"
fi

if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    cat > /etc/proxychains4.conf << EOF
strict_chain
quiet_mode

# Bypass the SOCKS proxy for local and Fly private network traffic.
# - 127.0.0.0/8: localhost (so the API server can talk to itself)
# - fdaa::/16: Fly 6PN — every Fly app's .internal hostname lives here, and
#   peer-to-peer calls (gateway ↔ coding-squad) must connect directly.
# proxy_dns is intentionally NOT set: with it on, proxychains intercepts
# getaddrinfo() for ALL hostnames (including fly-local-6pn) and returns
# fake 224.x.x.x addresses, breaking both the API server bind and any
# attempt to resolve .internal. Without proxy_dns, the local resolver
# handles names normally and the localnet rules above apply at connect time.

localnet 127.0.0.0/255.0.0.0
localnet fdaa::/16

[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF
    exec proxychains4 -q /opt/hermes/docker/entrypoint.sh "$@"
else
    exec /opt/hermes/docker/entrypoint.sh "$@"
fi
