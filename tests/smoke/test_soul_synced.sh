#!/bin/bash
# test_soul_synced.sh — verify on-volume SOUL.md matches the repo source.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAILED=0
TEST="soul-synced"

check_soul() {
    local app="$1" repo_path="$2"
    local local_hash remote_hash

    if [ ! -f "$REPO_ROOT/$repo_path" ]; then
        fail "$TEST: $repo_path missing locally" ""
        return 1
    fi

    local_hash=$(shasum -a 256 "$REPO_ROOT/$repo_path" | awk '{print $1}')
    remote_hash=$(flyssh "$app" "sha256sum /opt/data/SOUL.md" 2>/dev/null | awk '{print $1}' | tail -n1)

    if [ "$local_hash" = "$remote_hash" ]; then
        pass "$TEST: $app SOUL.md matches $repo_path"
    else
        fail "$TEST: $app SOUL.md differs from $repo_path" \
             "local=$local_hash  remote=$remote_hash"
        return 1
    fi
}

check_soul "$GATEWAY_APP" "flyio/SOUL.md" || FAILED=$((FAILED+1))
check_soul "$SQUAD_APP"   "flyio-squad/SOUL.md" || FAILED=$((FAILED+1))

exit "$FAILED"
