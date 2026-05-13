#!/bin/bash
# call_agent.sh — generic peer-to-peer call to another Hermes agent over Fly 6PN.
#
# Reads the agent registry at:
#   <skill_dir>/references/agents.yaml   (default)
# or set AGENTS_YAML env var to override.
#
# Usage:
#   call_agent.sh <agent-name> "prompt text"
#   call_agent.sh --json <agent-name> "prompt text"
#   echo "prompt" | call_agent.sh <agent-name> -
#
# The bearer token comes from the env var named in agents.yaml under api_key_env.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REGISTRY="$(dirname "$SCRIPT_DIR")/references/agents.yaml"
AGENTS_YAML="${AGENTS_YAML:-$DEFAULT_REGISTRY}"

# Use Hermes' venv python — it has PyYAML installed.
PYTHON="${PYTHON:-/opt/hermes/.venv/bin/python3}"
[ -x "$PYTHON" ] || PYTHON=python3

RETURN_JSON=false
IS_RELAY=false
DRY_RUN=false

# Flags can appear in any order before the agent name.
while true; do
    case "${1:-}" in
        --json)    RETURN_JSON=true; shift ;;
        --relay)   IS_RELAY=true;    shift ;;
        --dry-run) DRY_RUN=true;     shift ;;
        *) break ;;
    esac
done

AGENT_NAME="${1:-}"
if [ -z "$AGENT_NAME" ]; then
    echo "Usage: $0 [--json] [--relay] [--dry-run] <agent-name> \"prompt text\"" >&2
    echo "  --relay   wrap the prompt in [[RELAY]]...[[/RELAY]] markers so the" >&2
    echo "            receiving agent treats it as a protocol directive (push" >&2
    echo "            to user via its messaging adapter) rather than a chat" >&2
    echo "            request. Today only 'gateway' handles relay markers." >&2
    echo "  --dry-run print the assembled payload to stderr and exit (no HTTP)." >&2
    echo "Available agents:" >&2
    yq -r '.agents[].name' "$AGENTS_YAML" 2>/dev/null | sed 's/^/  - /' >&2 \
        || "$PYTHON" -c "import yaml,sys; [print(f'  - {a[\"name\"]}') for a in yaml.safe_load(open('$AGENTS_YAML'))['agents']]" >&2
    exit 1
fi
shift

if [ "${1:-}" = "-" ]; then
    PROMPT=$(cat)
else
    PROMPT="${1:-}"
fi

if [ -z "$PROMPT" ]; then
    echo "Error: empty prompt" >&2
    exit 1
fi

# Look up agent details from the registry (use python since yq may not be installed)
read -r AGENT_URL AGENT_KEY_ENV < <("$PYTHON" -c "
import yaml, sys
with open('$AGENTS_YAML') as f:
    reg = yaml.safe_load(f)
for a in reg['agents']:
    if a['name'] == '$AGENT_NAME':
        print(a['url'], a['api_key_env'])
        sys.exit(0)
sys.exit(1)
") || { echo "Error: agent '$AGENT_NAME' not found in $AGENTS_YAML" >&2; exit 1; }

# Fetch bearer token from env var named in the registry
API_KEY="${!AGENT_KEY_ENV:-}"
if [ -z "$API_KEY" ]; then
    echo "Error: env var $AGENT_KEY_ENV is empty (needed to authenticate to $AGENT_NAME)" >&2
    exit 1
fi

# If --relay, wrap the prompt with protocol markers. The receiving agent
# is expected to detect these and route to its messaging adapter, bypassing
# normal chat-completion processing. Markers chosen to be unmistakable
# (unlikely in normal prose) and easy to grep for in audit logs.
if [ "$IS_RELAY" = true ]; then
    PROMPT="[[RELAY]]${PROMPT}[[/RELAY]]"
fi

PAYLOAD=$(jq -n --arg p "$PROMPT" '{
  model: "hermes-agent",
  messages: [{role: "user", content: $p}]
}')

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would POST to $AGENT_URL/v1/chat/completions"
    echo "[dry-run] payload:"
    echo "$PAYLOAD" | "$PYTHON" -m json.tool
    exit 0
fi

RESPONSE=$(curl -sS -X POST "$AGENT_URL/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --max-time 600 \
    -d "$PAYLOAD")

# Auto-audit every peer call (truncate prompt to keep entries small).
PROMPT_PREVIEW="${PROMPT:0:120}"
[ ${#PROMPT} -gt 120 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW}..."
AUDIT_OUTCOME="success"
echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1 && AUDIT_OUTCOME="failure"
AUDIT_SCRIPT="$(dirname "$(dirname "$SCRIPT_DIR")")/audit-log/scripts/log_action.sh"
[ -x "$AUDIT_SCRIPT" ] && bash "$AUDIT_SCRIPT" peer-call \
    "Called $AGENT_NAME: $PROMPT_PREVIEW" "$AUDIT_OUTCOME" 2>/dev/null || true

if [ "$RETURN_JSON" = true ]; then
    echo "$RESPONSE"
else
    echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .error // "(empty response)"'
fi
