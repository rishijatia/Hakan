#!/bin/bash
# log_action.sh — append one audit entry to /opt/data/logs/audit.log
#
# Append-only, JSON Lines format. Every meaningful autonomous action an
# agent takes should produce one entry: file edits, PR opens, peer calls,
# cron triggers, secret reads, etc.
#
# Usage:
#   log_action.sh <action> "<description>" [outcome]
#
#   action      = short category, lowercase, hyphenated
#                 (e.g., "peer-call", "pr-open", "file-write", "cron-fire")
#   description = free-text human-readable explanation
#   outcome     = optional: success | failure | partial | pending
#
# Examples:
#   log_action.sh peer-call "Asked squad to identify itself"
#   log_action.sh pr-open "Opened PR rishijatia/Hakan#42" success
#   log_action.sh cron-fire "Daily WHOOP brief at 09:15 ET"
set -euo pipefail

LOG_DIR="${HERMES_HOME:-/opt/data}/logs"
LOG_FILE="$LOG_DIR/audit.log"
mkdir -p "$LOG_DIR"

ACTION="${1:-}"
DESCRIPTION="${2:-}"
OUTCOME="${3:-}"

if [ -z "$ACTION" ] || [ -z "$DESCRIPTION" ]; then
    echo "Usage: $0 <action> \"<description>\" [outcome]" >&2
    exit 1
fi

# Agent name = the Fly app name from env, falling back to hostname.
AGENT="${FLY_APP_NAME:-$(hostname)}"

# ISO 8601 UTC timestamp, second precision.
TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Build a single JSON line with jq for proper escaping.
jq -nc \
    --arg ts "$TS" \
    --arg agent "$AGENT" \
    --arg action "$ACTION" \
    --arg description "$DESCRIPTION" \
    --arg outcome "$OUTCOME" \
    '{ts: $ts, agent: $agent, action: $action, description: $description}
     + (if $outcome != "" then {outcome: $outcome} else {} end)' \
    >> "$LOG_FILE"
