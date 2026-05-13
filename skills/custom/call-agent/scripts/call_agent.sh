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
IS_ASYNC=false
DRY_RUN=false

# Flags can appear in any order before the agent name.
while true; do
    case "${1:-}" in
        --json)    RETURN_JSON=true; shift ;;
        --relay)   IS_RELAY=true;    shift ;;
        --async)   IS_ASYNC=true;    shift ;;
        --dry-run) DRY_RUN=true;     shift ;;
        *) break ;;
    esac
done

# --async and --relay are mutually exclusive: relay is for sync responses,
# async returns immediately. If both are set, that's a usage error.
if [ "$IS_ASYNC" = true ] && [ "$IS_RELAY" = true ]; then
    echo "Error: --async and --relay are mutually exclusive. The squad relays back asynchronously by protocol when it sees [[ASYNC]] markers." >&2
    exit 1
fi

AGENT_NAME="${1:-}"
if [ -z "$AGENT_NAME" ]; then
    echo "Usage: $0 [--json] [--relay|--async] [--dry-run] <agent-name> \"prompt text\"" >&2
    echo "  --relay   wrap the prompt in [[RELAY]]...[[/RELAY]] markers so the" >&2
    echo "            receiving agent treats it as a protocol directive (push" >&2
    echo "            to user via its messaging adapter) rather than a chat" >&2
    echo "            request. Today only 'gateway' handles relay markers." >&2
    echo "  --async   wrap the prompt in [[ASYNC task_id=... reply_to=gateway]]" >&2
    echo "            markers and POST to /v1/runs instead of /v1/chat/completions." >&2
    echo "            Returns 'task_id=...' immediately (HTTP 202); the receiving" >&2
    echo "            agent works in background and relays progress back." >&2
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

# Wrap the prompt with protocol markers if a flag is set.
#   --relay  → [[RELAY]]<msg>[[/RELAY]]  : receiver pushes to user via messaging adapter
#   --async  → [[ASYNC task_id=<id> reply_to=gateway]]<msg>[[/ASYNC]]  :
#              receiver works in background, must relay progress back tagged
#              with the task_id so the user can correlate.
TASK_ID=""
if [ "$IS_RELAY" = true ]; then
    PROMPT="[[RELAY]]${PROMPT}[[/RELAY]]"
elif [ "$IS_ASYNC" = true ]; then
    # Stable, locally-generated task_id. We include it in the prompt so
    # the squad's progress relays can carry it. /v1/runs also returns a
    # Hermes-side run_id which we expose alongside for direct status query.
    TASK_ID="task-$(date +%s)-$$"
    PROMPT="[[ASYNC task_id=${TASK_ID} reply_to=gateway]]${PROMPT}[[/ASYNC]]"
fi

# Endpoint and payload shape differ between sync and async modes.
if [ "$IS_ASYNC" = true ]; then
    ENDPOINT="$AGENT_URL/v1/runs"
    PAYLOAD=$(jq -n --arg p "$PROMPT" '{input: $p}')
else
    ENDPOINT="$AGENT_URL/v1/chat/completions"
    PAYLOAD=$(jq -n --arg p "$PROMPT" '{
      model: "hermes-agent",
      messages: [{role: "user", content: $p}]
    }')
fi

if [ "$DRY_RUN" = true ]; then
    echo "[dry-run] would POST to $ENDPOINT"
    echo "[dry-run] payload:"
    echo "$PAYLOAD" | "$PYTHON" -m json.tool
    [ -n "$TASK_ID" ] && echo "[dry-run] task_id=$TASK_ID"
    exit 0
fi

# Async POSTs have a much shorter timeout — they should return 202 fast.
TIMEOUT=600
[ "$IS_ASYNC" = true ] && TIMEOUT=30

RESPONSE=$(curl -sS -X POST "$ENDPOINT" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    --max-time "$TIMEOUT" \
    -d "$PAYLOAD")

# Audit-log every dispatch. Action differs by mode so we can answer
# "what's pending?" via grep later.
PROMPT_PREVIEW="${PROMPT:0:120}"
[ ${#PROMPT} -gt 120 ] && PROMPT_PREVIEW="${PROMPT_PREVIEW}..."
AUDIT_OUTCOME="success"
echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1 && AUDIT_OUTCOME="failure"
AUDIT_SCRIPT="$(dirname "$(dirname "$SCRIPT_DIR")")/audit-log/scripts/log_action.sh"

if [ "$IS_ASYNC" = true ]; then
    RUN_ID=$(echo "$RESPONSE" | jq -r '.run_id // empty' 2>/dev/null || true)
    # Audit entry tagged with task_id for grep-based status queries.
    AUDIT_DESC="Dispatched $AGENT_NAME [task_id=$TASK_ID run_id=${RUN_ID:-none}]: $(echo "$PROMPT_PREVIEW" | sed 's/\[\[ASYNC[^]]*\]\]//; s/\[\[\/ASYNC\]\]//')"
    [ -x "$AUDIT_SCRIPT" ] && bash "$AUDIT_SCRIPT" async-dispatch "$AUDIT_DESC" "$AUDIT_OUTCOME" 2>/dev/null || true

    if [ "$RETURN_JSON" = true ]; then
        echo "$RESPONSE"
    else
        echo "task_id=$TASK_ID"
        [ -n "$RUN_ID" ] && echo "run_id=$RUN_ID"
        echo "status=dispatched"
    fi
    exit 0
fi

# Synchronous mode: audit as peer-call, return chat content as before.
[ -x "$AUDIT_SCRIPT" ] && bash "$AUDIT_SCRIPT" peer-call \
    "Called $AGENT_NAME: $PROMPT_PREVIEW" "$AUDIT_OUTCOME" 2>/dev/null || true

if [ "$RETURN_JSON" = true ]; then
    echo "$RESPONSE"
else
    echo "$RESPONSE" | jq -r '.choices[0].message.content // .error.message // .error // "(empty response)"'
fi
