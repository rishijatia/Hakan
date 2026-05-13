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
sync_from_github "flyio/SOUL.md" "$HERMES_HOME/SOUL.md"

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
