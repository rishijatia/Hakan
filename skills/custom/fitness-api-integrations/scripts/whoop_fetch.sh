#!/bin/bash
# WHOOP Data Fetcher
# Fetches recent WHOOP data (recovery, sleep, workouts, cycles)
# using the current access token.
#
# Usage: ./whoop_fetch.sh [limit]
#   limit: number of records per endpoint (default: 7)
#
# Output: JSON files in /tmp/whoop_*.json

set -euo pipefail

LIMIT="${1:-7}"
BASE="https://api.prod.whoop.com/developer"
TOKEN_FILE="${WHOOP_ACCESS_TOKEN_FILE:-/tmp/whoop_token.txt}"

if [ ! -f "$TOKEN_FILE" ]; then
  echo "ERROR: No access token at $TOKEN_FILE. Run whoop_refresh.sh first." >&2
  exit 1
fi

TOKEN=$(cat "$TOKEN_FILE")

for ep in \
  "v2/user/profile/basic:profile" \
  "v2/user/measurement/body:body" \
  "v2/recovery?limit=${LIMIT}:recovery" \
  "v2/activity/sleep?limit=${LIMIT}:sleep" \
  "v2/activity/workout?limit=${LIMIT}:workout" \
  "v2/cycle?limit=${LIMIT}:cycles"
do
  path="${ep%%:*}"
  name="${ep##*:}"
  curl -s "$BASE/$path" \
    -H "Authorization: Bearer $TOKEN" \
    -o "/tmp/whoop_${name}.json"
done

echo "Data fetched to /tmp/whoop_*.json"
