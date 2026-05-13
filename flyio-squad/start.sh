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

sync_from_github "flyio-squad/SOUL.md" "$HERMES_HOME/SOUL.md"

exec /opt/hermes/docker/entrypoint.sh "$@"
