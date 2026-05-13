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

if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    cat > /etc/proxychains4.conf << EOF
strict_chain
proxy_dns
quiet_mode
[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF
    exec proxychains4 -q /opt/hermes/docker/entrypoint.sh "$@"
else
    exec /opt/hermes/docker/entrypoint.sh "$@"
fi
