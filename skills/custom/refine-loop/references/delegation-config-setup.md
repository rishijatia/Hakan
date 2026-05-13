# Delegation Config Setup

## Prerequisites for Sub-Agents

Before `delegate_task` will use a strong model, you must configure the delegation section in `config.yaml`:

```yaml
delegation:
  model: anthropic/claude-sonnet-4   # The model sub-agents use
  provider: openrouter                # Must match a configured provider
  max_iterations: 50
  child_timeout_seconds: 600
  max_concurrent_children: 3
  max_spawn_depth: 1                  # 1 = leaf only, 2 = orchestrator can spawn
  orchestrator_enabled: true
  subagent_auto_approve: true         # Required for non-interactive sub-agents
```

## Setting via CLI

```bash
hermes config set delegation.model "anthropic/claude-sonnet-4"
hermes config set delegation.provider "openrouter"
hermes config set delegation.subagent_auto_approve true
```

## Critical Pitfall: Gateway Restart Required

`hermes config set` writes to `config.yaml` but the **running gateway process caches config in memory**. After changing delegation settings, you MUST restart:

```bash
hermes gateway restart
```

Without this, sub-agents will continue using the old model (typically the parent's default model, e.g. `xiaomi/mimo-v2.5-pro`).

## Verifying It Worked

After restart, delegate a simple task and check:
1. The sub-agent should use the configured model
2. Note: `delegate_task` result `model` field shows the **parent** model, not the child — this is a display quirk
3. Quality/token counts will reflect the actual child model

## Cost Implications

| Model | Approx cost per 1K tokens | Good for |
|-------|--------------------------|----------|
| mimo-v2.5-pro | ~$0.001 | Parent/routing (cheap) |
| claude-sonnet-4 | ~$0.01 | Sub-agent work (balanced) |
| claude-opus-4 | ~$0.05 | Complex reasoning (expensive) |

A typical refine-loop (3 iterations × 2 delegates) costs ~$0.10-0.15 with claude-sonnet-4.
