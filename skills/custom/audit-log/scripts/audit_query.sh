#!/bin/bash
# audit_query.sh — read recent audit entries
#
# Usage:
#   audit_query.sh                     # last 20 entries, pretty
#   audit_query.sh -n 100              # last 100 entries
#   audit_query.sh --agent squad       # only squad's actions
#   audit_query.sh --action pr-open    # only pr-open actions
#   audit_query.sh --since 2026-05-12  # entries since a date
#   audit_query.sh --json              # raw JSON Lines (for piping into jq)
set -euo pipefail

LOG_FILE="${HERMES_HOME:-/opt/data}/logs/audit.log"
LIMIT=20
AGENT_FILTER=""
ACTION_FILTER=""
SINCE=""
RAW=false

while [ $# -gt 0 ]; do
    case "$1" in
        -n) LIMIT="$2"; shift 2 ;;
        --agent) AGENT_FILTER="$2"; shift 2 ;;
        --action) ACTION_FILTER="$2"; shift 2 ;;
        --since) SINCE="$2"; shift 2 ;;
        --json) RAW=true; shift ;;
        -h|--help)
            sed -n '2,12p' "$0" | sed 's/^# \?//'; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ ! -s "$LOG_FILE" ]; then
    echo "(audit log is empty: $LOG_FILE)" >&2
    exit 0
fi

FILTER='.'
[ -n "$AGENT_FILTER" ]  && FILTER="$FILTER | select(.agent == \"$AGENT_FILTER\")"
[ -n "$ACTION_FILTER" ] && FILTER="$FILTER | select(.action == \"$ACTION_FILTER\")"
[ -n "$SINCE" ]         && FILTER="$FILTER | select(.ts >= \"$SINCE\")"

if [ "$RAW" = true ]; then
    jq -c "$FILTER" "$LOG_FILE" | tail -n "$LIMIT"
else
    jq -r "$FILTER | [.ts, .agent, .action, (.outcome // \"-\"), .description] | @tsv" "$LOG_FILE" \
        | tail -n "$LIMIT" \
        | awk -F'\t' '{ printf "%-21s  %-22s  %-14s  %-8s  %s\n", $1, $2, $3, $4, $5 }'
fi
