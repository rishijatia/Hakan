# Adding a New Agent to Hakan

End-to-end runbook for adding a third (or fourth, fifth…) Hermes agent to the system. Takes you from "I want a Research agent" to "it's deployed, peer-to-peer, in the audit log, and smoke-tested."

**Time estimate:** 10–15 minutes from start to smoke-test-green.

---

## TL;DR (the fast path)

```bash
# Scaffold local files + registry + peer rules + smoke test stub
bash scripts/bootstrap_new_agent.sh <agent-name> "<Agent Title>" "<one-line description>"

# Follow the printed Fly.io commands (create app + volume + secrets)
# Edit the generated SOUL.md and peer_rules.md to add real role-specific rules
# Commit + push (CI must pass)
# Deploy:
fly deploy --config flyio-<agent-name>/fly.toml --ha=false

# Verify:
bash tests/smoke/run_all_smoke.sh
```

---

## Step 1 — Plan the agent

Before you scaffold, answer these:

| Question | Why it matters |
|----------|---------------|
| **What does it do?** | Drives the SOUL.md description and the boundaries between this agent and existing peers. |
| **What does it refuse?** | Goes into the per-agent section of `shared/peer_rules.md`. |
| **Who does it call?** | Determines which bearer tokens you set on this agent's Fly secrets. |
| **Who calls it?** | Determines which peer apps need this agent's bearer token. |
| **Does it need outbound network beyond Fly + LLM?** | If yes (e.g., Telegram, a specific API), you may need proxychains in `start.sh`. |
| **Does it need a Telegram/Discord bot?** | If yes, set the platform tokens and disable `proxy_dns` properly. If no, no messaging tokens needed. |

Pick a name. Use lowercase + hyphens. The Fly app will be `hermes-<name>`, the volume `<name>_data` (Fly volumes don't allow hyphens — the script handles the conversion).

---

## Step 2 — Scaffold (automated)

```bash
bash scripts/bootstrap_new_agent.sh research "Research Agent" \
    "Deep research on technical topics, market questions, and competitor analysis. Produces written briefs, never code."
```

This creates:

- `flyio-research/`
  - `fly.toml` (app: `hermes-research`, volume: `research_data`)
  - `Dockerfile` (extends `nousresearch/hermes-agent` + `gh` + `jq`)
  - `start.sh` (GitHub sync, SOUL.md assembly with shared/, skills sync)
  - `SOUL.md` (role-specific template — needs your edits)
- Appends entry to `skills/custom/call-agent/references/agents.yaml`
- Appends stub to `shared/peer_rules.md` (TODO entries you must flesh out)
- Creates `tests/smoke/test_research_health.sh` (basic reachability + identity check)
- Prints the manual Fly commands you still need

The script refuses to overwrite an existing `flyio-<agent-name>/` directory, so re-running on an existing agent is safe.

---

## Step 3 — Edit the generated content

Two files need real content (the script leaves placeholders):

### 3a. `flyio-<agent-name>/SOUL.md`

Replace:

- `{{AGENT_DESCRIPTION}}` line — write 1–3 sentences on the role.
- The "Agent-Specific Rules" section — list real rules unique to this agent's role. Universal rules are appended at boot; only role-specific rules go here.

### 3b. `shared/peer_rules.md`

Find the TODO stub for the new agent and replace it with:

- What this agent will refuse (so other agents know not to ask).
- What other agents must not ask this agent to do.

This is the **most important** edit — peer rules are how the firewall stays enforced across the whole system.

---

## Step 4 — Fly.io setup (manual, ~5 min)

The bootstrap script prints the exact commands you need with the right values pre-filled. The pattern:

### 4a. Create app + volume

```bash
fly apps create hermes-<agent-name>
fly volumes create <agent-name-underscored>_data -a hermes-<agent-name> --region fra --size 3 --yes
```

### 4b. Generate this agent's API key + set its secrets

```bash
THIS_KEY=$(openssl rand -hex 32)
echo "Save this: $THIS_KEY"   # you'll need it on every peer app

fly secrets set \
    OPENROUTER_API_KEY=<your OpenRouter key> \
    GITHUB_PAT=<your fine-grained GitHub PAT> \
    API_SERVER_KEY=$THIS_KEY \
    -a hermes-<agent-name>
```

Generate a separate OpenRouter key per agent if you want per-agent cost tracking. A fresh fine-grained GitHub PAT is also recommended (scope it only to the repos this agent should touch).

### 4c. Cross-app bearer tokens (the most error-prone step)

**Every pair of agents that should be able to call each other needs two secrets:**

- The caller needs the callee's `<CALLEE>_API_KEY`.
- The callee needs the caller's `<CALLER>_API_KEY`.

For a new agent `<X>` joining gateway + squad:

```bash
# X gets to call gateway and squad
fly secrets set \
    GATEWAY_API_KEY=<gateway's API_SERVER_KEY> \
    SQUAD_API_KEY=<squad's API_SERVER_KEY> \
    -a hermes-<X>

# Gateway and squad get to call X
fly secrets set <X>_API_KEY=$THIS_KEY -a hermes-gateway
fly secrets set <X>_API_KEY=$THIS_KEY -a hermes-coding-squad
```

If you forget step 4c on a peer, calls from that peer to the new agent will fail with `env var <X>_API_KEY is empty` from `call_agent.sh`. The Layer 3 smoke test catches this.

---

## Step 5 — Commit, push, watch CI

```bash
git add flyio-<agent-name>/ skills/custom/call-agent/references/agents.yaml shared/peer_rules.md tests/smoke/test_<agent-name>_health.sh
git commit -m "Add hermes-<agent-name> agent"
git push
```

The pre-commit hook runs Layer 1 (lint) locally. GitHub Actions runs Layer 1 + Layer 2 on the push/PR. CI must pass before deploying.

---

## Step 6 — Deploy

```bash
fly deploy --config flyio-<agent-name>/fly.toml --ha=false
```

You can also deploy any peer whose secrets you updated in step 4c. Restart-only is *not* sufficient if you changed env vars — you need a full deploy.

---

## Step 7 — Smoke-test

```bash
bash tests/smoke/run_all_smoke.sh
```

This runs every existing test plus the stub `test_<agent-name>_health.sh` the script generated for you. Expected: 5 passes plus your new agent's health check, all green.

If `test_<agent-name>_health.sh` fails:

- HTTP non-200 from `/health` → app didn't start, check `fly logs -a hermes-<agent-name>`
- `call_agent.sh` from gateway returns `env var X_API_KEY is empty` → missed step 4c on the gateway
- Identity check fails → SOUL.md didn't assemble (check `start.sh` logs in fly logs)

---

## Step 8 — Wire role-specific behavior

Once the agent is up and reachable, the role-specific work begins. Common patterns:

- **Add skills the agent will use** under `skills/custom/<skill-name>/`. They'll sync to all apps on next boot.
- **Update `tech-lead/SKILL.md`** or this agent's own SOUL.md to describe when work routes to this agent.
- **Add cron jobs** if the agent should run periodic tasks — see Hermes' cron skill docs.
- **Add role-specific smoke tests** beyond the basic health check (e.g., a research-agent test that verifies it can fetch + summarize a URL).

---

## Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| Forgot cross-app bearer token (step 4c) | `env var X_API_KEY is empty` | Set the secret, deploy that peer |
| Used `fly machine restart` after changing `start.sh` | New sync logic not running | Use `fly deploy` instead |
| Didn't bind `API_SERVER_HOST=fly-local-6pn` | API server not reachable on 6PN | Already in template; don't change it |
| Skipped editing `shared/peer_rules.md` | Other agents don't know what new agent refuses → can route around firewall | Always update peer_rules.md in the same PR |
| Forgot to chmod the new start.sh | Container won't boot | `templates/agent/start.sh` is already executable + script auto-chmods; only a problem if you hand-edit |

---

## Architectural Reminders

- Every agent's SOUL.md = role-specific base + `shared/guardrails.md` + `shared/peer_rules.md` (concatenated at boot).
- Every agent independently enforces the firewall. A peer's refusal is binding system-wide.
- Inter-agent calls go through Fly 6PN, never the public internet. No `[[services]]` block in `fly.toml`.
- Adding an agent is a PR like any other code change — tests required, CI must be green.

When you build #4 or #5, this runbook should still apply unchanged. If you find it doesn't, update the runbook in the same PR.
