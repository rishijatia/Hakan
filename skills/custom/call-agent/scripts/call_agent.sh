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
if [ "${1:-}" = "--json" ]; then
    RETURN_JSON=true
    shift
fi

AGENT_NAME="${1:-}"
if [ -z "$AGENT_NAME" ]; then
    echo "Usage: $0 [--json] <agent-name> \"prompt text\"" >&2
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

PAYLOAD=$(jq -n --arg p "$PROMPT" '{
  model: "hermes-agent",
  messages: [{role: "user", content: $p}]
}')

RESPONSE=$(curl -sS -X POST "$AGENT_URL/v1/chat/completions" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --max-time 600 \
    -d "$PAYLOAD")

if [ "$RETURN_JSON" = true ]; then
    echo "$RESPONSE"
else
    echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .error // "(empty response)"'
fi
