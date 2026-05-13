#!/bin/bash
# test_audit_log.sh — trigger a peer call and verify an audit entry lands.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./_lib.sh
. "$DIR/_lib.sh"

FAILED=0
TEST="audit-log"

# Unique marker so we can find this exact entry in the log.
# Hex marker — long numeric strings get redacted to [PHONE] by Hermes'
# secret-redaction layer, breaking grep-based assertions.
MARKER="smoke-$(openssl rand -hex 6)"

# 1. Trigger a peer call on the gateway with the marker in the prompt.
flyssh "$GATEWAY_APP" \
    "bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh squad 'audit smoke test $MARKER reply OK'" \
    >/dev/null 2>&1 || true

# 2. Look for an audit entry containing our marker.
out=$(flyssh "$GATEWAY_APP" "tail -50 /opt/data/logs/audit.log" || true)
if assert_contains "$out" "$MARKER" "$TEST: marker not in audit log"; then
    pass "$TEST: peer-call entry written with marker $MARKER"
else
    FAILED=$((FAILED+1))
fi

# 3. Verify the entry is valid JSON with expected fields.
entry=$(echo "$out" | grep "$MARKER" | tail -n1)
if [ -n "$entry" ]; then
    if echo "$entry" | python3 -c "
import sys, json
e = json.loads(sys.stdin.read())
assert 'ts' in e, 'missing ts'
assert e.get('action') == 'peer-call', f'wrong action: {e.get(\"action\")}'
assert e.get('agent') == '$GATEWAY_APP', f'wrong agent: {e.get(\"agent\")}'
assert 'outcome' in e, 'missing outcome'
" 2>/tmp/audit_err; then
        pass "$TEST: entry has valid JSON shape (ts, agent, action=peer-call, outcome)"
    else
        fail "$TEST: entry malformed" "$(cat /tmp/audit_err)"
        FAILED=$((FAILED+1))
    fi
    rm -f /tmp/audit_err
fi

exit "$FAILED"
