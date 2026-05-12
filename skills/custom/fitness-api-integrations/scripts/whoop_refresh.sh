#!/bin/bash
# WHOOP Token Refresh Script
# Refreshes the OAuth access token using the refresh token.
# Run via cron every ~45 minutes (before the 1-hour expiry).
#
# Usage: ./whoop_refresh.sh
#
# Requires these env vars (set in /opt/data/.env or similar):
#   WHOOP_CLIENT_ID
#   WHOOP_CLIENT_SECRET
#   WHOOP_REFRESH_TOKEN (path to file containing refresh token)
#
# Saves new tokens to:
#   WHOOP_ACCESS_TOKEN_FILE (default: /tmp/whoop_token.txt)
#   WHOOP_REFRESH_TOKEN_FILE (default: /tmp/whoop_refresh.txt)

set -euo pipefail

TOKEN_URL="https://api.prod.whoop.com/oauth/oauth2/token"
ACCESS_FILE="${WHOOP_ACCESS_TOKEN_FILE:-/tmp/whoop_token.txt}"
REFRESH_FILE="${WHOOP_REFRESH_TOKEN_FILE:-/tmp/whoop_refresh.txt}"

# Load credentials
source /opt/data/.env 2>/dev/null || true

if [ -z "${WHOOP_CLIENT_ID:-}" ] || [ -z "${WHOOP_CLIENT_SECRET:-}" ]; then
  echo "ERROR: WHOOP_CLIENT_ID and WHOOP_CLIENT_SECRET must be set" >&2
  exit 1
fi

if [ ! -f "$REFRESH_FILE" ]; then
  echo "ERROR: No refresh token found at $REFRESH_FILE" >&2
  exit 1
fi

REFRESH_TOKEN=$(cat "$REFRESH_FILE")

# Exchange refresh token for new access + refresh tokens
RESPONSE=$(curl -s -X POST "$TOKEN_URL" \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=refresh_token" \
  -d "refresh_token=$REFRESH_TOKEN" \
  -d "client_id=$WHOOP_CLIENT_ID" \
  -d "client_secret=$WHOOP_CLIENT_SECRET" \
  -d "scope=offline")

# Extract and save tokens using python (avoid redaction in shell)
echo "$RESPONSE" | python3 -c "
import sys, json
d = json.load(sys.stdin)
if 'error' in d:
    print(f'ERROR: {d.get(\"error_hint\", d.get(\"error\"))}', file=sys.stderr)
    sys.exit(1)
open('$ACCESS_FILE', 'w').write(d['access_token'])
open('$REFRESH_FILE', 'w').write(d.get('refresh_token', ''))
print(f'Refreshed OK. Token expires in {d.get(\"expires_in\", \"?\")}s')
"
