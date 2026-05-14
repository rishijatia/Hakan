---
name: call-agent
description: "Peer-to-peer call to another Hermes agent over Fly's private network. Use to delegate work to a specialized agent (e.g., squad for coding) or to relay to the user via the gateway. Same skill installed on every agent."
version: 0.2.0
author: Hakan
metadata:
  hermes:
    tags: [delegation, multi-agent, peer-to-peer, a2a]
    related_skills: [delegate_task]
---

# Call Agent — Cross-App Peer Communication

Send a prompt to another Hermes agent over Fly.io's 6PN private network and get a response. This is **peer-to-peer**: the same skill is installed on every agent in the system, and the agent registry (`references/agents.yaml`) lists who can be called.

## Why This Exists Separately from `delegate_task`

`delegate_task` runs in-process — the parent agent waits while a child runs in the same machine, blocking the chat. `call_agent` is **cross-app HTTP**: the called agent runs in its own machine, so the caller stays responsive. Use `call_agent` when the work belongs to a different specialist; use `delegate_task` for fine-grained parallelism within the same agent.

## When to Use

- **From the gateway:** delegating code work to the squad (`call_agent squad "..."`)
- **From the squad:** relaying a question or completion notice to the user via the gateway (`call_agent gateway "Tell Rishi: ..."`)
- Any cross-agent call where the work belongs to a peer with specialized skills or resources

## When NOT to Use

- Talking to yourself (loops — the script doesn't currently detect this; use `delegate_task` instead)
- Work that can finish in the current agent without specialist help
- Trivial conversational responses

## How to Use

```bash
# Discover available agents
bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh

# Call a specific agent
bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh squad "Implement X in repo Y"
bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh gateway "Tell Rishi: build X complete, ready for review"

# Get raw JSON (when you need full response metadata)
bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh --json squad "..."

# Read prompt from stdin (handy for long prompts)
cat plan.md | bash /opt/data/skills/custom/call-agent/scripts/call_agent.sh squad -
```

## Required Environment

The script reads `references/agents.yaml` (relative to the script's parent dir) to find each agent's URL and the env var that holds its bearer token. Each agent's environment must have the bearer tokens for the peers it intends to call.

Current registry:

| Agent | URL | Bearer env var |
|-------|-----|----------------|
| `gateway` | `http://hermes-gateway.internal:8642` | `GATEWAY_API_KEY` |
| `squad` | `http://hermes-coding-squad.internal:8642` | `SQUAD_API_KEY` |

## Cost Awareness

Each remote call loads ~16K prompt tokens (the called agent's full Hermes context). At current model pricing that's roughly $0.005 per call. Bundle related sub-tasks into one call when possible — don't chat back and forth.

## Forward-Compatibility

The registry format (`name`, `url`, `description`, `api_key_env`) maps cleanly to A2A Agent Cards. When Hermes ships A2A support (issue #514), the migration is to swap `agents.yaml` for `/.well-known/agent.json` discovery and use the A2A SDK in place of curl.

## Async Dispatch Patterns

### Retry After Infra Fix

When an async task fails due to infrastructure (PAT permissions, redeploy, network blip) and the user confirms a fix + redeploy:

1. Wait 10-15 seconds for the target machine to come back up (it may still be deploying).
2. Fire a fresh `--async` call with a short, focused prompt — just the remaining steps, not the full original task.
3. If the connection fails (exit code 7), the machine is still restarting — wait and retry once more.

```bash
# Example: retry just the push step after PAT fix
sleep 10 && bash call_agent.sh --async squad "PAT updated. Retry: push the branch and open the PR. Relay back the URL."
```

### Status Check for Async Tasks

When the user asks "what's the status?" of a running async task:

1. **Audit-log grep first** — fastest signal, no network hop:
   ```bash
   grep "<task_id>" /opt/data/logs/audit.log | tail -5
   ```
2. **Check GitHub directly** if the gateway has `gh` auth (it usually doesn't — that's the squad's domain).
3. **Ping the squad** with a fresh `--async` status check — this is the definitive answer.
4. **Report to user** with what you know: last relay received, any new audit entries, and that you've pinged for a fresh update.

**Pitfall:** Don't just say "checking..." and wait. Give the user the last known state immediately, THEN ping.

### Gateway `gh` Auth

The gateway typically does NOT have `gh` authenticated — GitHub operations are the squad's domain. Don't try to `gh pr list` from the gateway; it will fail. Instead, ask the squad or check the audit log for relayed status.

## Failure Modes

- **Network unreachable:** wrong URL, target app stopped, 6PN issue → curl error
- **HTTP 401:** bearer token mismatch — check the api_key_env value on both sides
- **HTTP 502/504:** target app crashed or busy → check its logs
- **Long delay (60s+):** target is doing heavy work — the script's `--max-time` is 10 minutes

When in doubt, run `curl http://<agent>.internal:8642/health` first to verify reachability.
