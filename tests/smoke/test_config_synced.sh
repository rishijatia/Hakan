#!/bin/bash
# test_config_synced.sh — verify config.yaml on each app's volume matches
# the repo's version (modulo Hermes' bootstrap fields). Catches sync
# regressions and unauthorized volume edits.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAILED=0
TEST="config-synced"

# We verify by checking that specific values from the repo's config.yaml
# are present on the volume. Hashing won't work because the entrypoint
# may add fields the first time it boots, and YAML serialization can
# differ. Marker-based check is robust against that.

check_config() {
    local app="$1" repo_path="$2"

    if [ ! -f "$REPO_ROOT/$repo_path" ]; then
        # No config in the repo for this app — sync is a no-op, skip.
        pass "$TEST: $app has no repo config.yaml (sync is no-op, OK)"
        return 0
    fi

    local remote
    remote=$(flyssh "$app" "cat /opt/data/config.yaml" 2>/dev/null)

    # Marker 1: env_passthrough should include TELEGRAM_BOT_TOKEN (this is a
    # value we set explicitly in the repo, so its presence proves sync).
    if echo "$remote" | grep -q "TELEGRAM_BOT_TOKEN"; then
        pass "$TEST: $app config.yaml contains TELEGRAM_BOT_TOKEN passthrough"
    else
        fail "$TEST: $app config.yaml missing TELEGRAM_BOT_TOKEN passthrough" "sync may not have run"
        FAILED=$((FAILED+1))
    fi

    # Marker 2: api_server platform_toolsets entry (also set explicitly).
    if echo "$remote" | grep -A2 "api_server:" | grep -q "messaging"; then
        pass "$TEST: $app config.yaml has api_server platform_toolsets with messaging"
    else
        fail "$TEST: $app config.yaml missing api_server messaging toolset" "sync may not have run"
        FAILED=$((FAILED+1))
    fi
}

check_config "$GATEWAY_APP" "flyio/config.yaml"
# Squad has no config.yaml in repo today — this just verifies the test
# behaves correctly when there's nothing to sync.
check_config "$SQUAD_APP" "flyio-squad/config.yaml"

exit "$FAILED"
