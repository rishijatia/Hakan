# Hakan

Rishi Jatia's personal multi-agent AI system, running 24/7 on Fly.io.

Hakan is built on [Hermes Agent](https://github.com/NousResearch/hermes-agent) and runs two long-lived agents that talk to each other over Fly's private network. The repo is the **source of truth**: SOUL.md identities and `skills/custom/` are synced from GitHub on every machine boot, so any change here flows to production by deploying or restarting.

## Architecture

```
Telegram (Rishi)
       │
       ▼
┌──────────────────────────┐    HTTP over Fly 6PN     ┌──────────────────────────┐
│  hermes-gateway          │ ◄──────────────────────► │  hermes-coding-squad     │
│  (Chief of Staff)        │   /v1/chat/completions    │  (Tech Lead + crew)      │
│                          │   Bearer-token auth       │                          │
│  - Telegram adapter       │                          │  - No public adapters     │
│  - Receives user messages │                          │  - HTTP API only (8642)   │
│  - Routes work to peers   │                          │  - Specialized coding work│
└──────────────────────────┘                          └──────────────────────────┘
       │                                                       │
       └──── persistent volume (/opt/data) ────────────────────┘
            sessions, memories, skills, audit log
```

Both apps run the same [Hermes Agent](https://github.com/NousResearch/hermes-agent) image. Inter-app communication uses Hermes' OpenAI-compatible API server (port 8642, 6PN-only, never publicly exposed). The `call-agent` skill (installed on both apps) wraps the bearer-token HTTP call.

When [A2A protocol support](https://github.com/NousResearch/hermes-agent/issues/514) lands in Hermes upstream, the registry-shaped `agents.yaml` lets us swap transports with minimal disruption.

## Repository Layout

```
Hakan/
├── flyio/                Gateway (Chief of Staff) deployment
│   ├── fly.toml          Fly app config — image, mounts, env, API server
│   ├── Dockerfile        Extends nousresearch/hermes-agent + gh + jq + proxychains
│   ├── start.sh          Entrypoint: GitHub sync (SOUL.md + skills) → proxychains → Hermes
│   ├── SOUL.md           Gateway identity (synced to /opt/data/SOUL.md on every boot)
│   └── config.yaml       Hermes runtime config (model, toolsets, agent budget)
│
├── flyio-squad/          Coding Squad deployment
│   ├── fly.toml          Squad's Fly app config (no public exposure, API server only)
│   ├── Dockerfile        Same base + gh + jq (no proxychains — squad doesn't need Telegram)
│   ├── start.sh          GitHub sync → Hermes (no proxy)
│   └── SOUL.md           Squad identity — "you are the Tech Lead"
│
├── skills/
│   ├── custom/           Custom skills (synced to every app's /opt/data/skills/custom/)
│   │   ├── call-agent/        Peer-to-peer HTTP call between Hermes apps
│   │   ├── audit-log/         Append-only JSON-Lines audit log
│   │   ├── tech-lead/         Squad orchestrator with guardrails
│   │   └── ... (others)       Personal skills: WHOOP, strength tracker, etc.
│   └── overrides/        (placeholder for modified built-in skills)
│
├── tests/
│   ├── lint/             Layer 1: shellcheck + YAML + SKILL.md frontmatter
│   ├── smoke/            Layer 3: live tests against deployed Fly apps
│   └── setup_deps.sh     One-time local setup (shellcheck, PyYAML, git hooks)
│
├── .githooks/
│   └── pre-commit        Runs lint suite on staged files
│
├── scripts/              Misc helper scripts (cron jobs, deploy helpers)
└── config/               Reserved for future shared config
```

## What Hakan Does Today

- **Chat with Rishi via Telegram.** The gateway answers, remembers conversations, runs cron jobs.
- **Delegate coding work to the squad.** Tasks like *"add a leaderboard to kaleidoscope-web"* route over the private network. The squad refuses anything Microsoft / work-adjacent, anything over 250 LOC, anything destructive — and never merges PRs itself.
- **Audit everything autonomous.** Every peer call, every PR open, every cron fire writes a structured entry to `/opt/data/logs/audit.log` so Rishi can review later.
- **Stay in sync with the repo.** Edits to `SOUL.md`, skills, or guardrails take effect on the next deploy or machine restart. The volume is *cache*, not source of truth.

## Quick Start (developer machine)

```bash
git clone https://github.com/rishijatia/Hakan.git
cd Hakan
bash tests/setup_deps.sh    # installs shellcheck + PyYAML, enables git hooks
```

You're now linted on every commit.

## Operating the System

### Deploy

```bash
# Gateway (user-facing, Telegram)
fly deploy --config flyio/fly.toml --ha=false

# Squad (backend, peer-to-peer only)
fly deploy --config flyio-squad/fly.toml --ha=false
```

### Verify everything works

```bash
bash tests/smoke/run_all_smoke.sh
```

5 tests, ~100s, hits real LLMs. Checks SOUL.md sync, skill sync, bidirectional peer-to-peer auth, audit log roundtrip, and tech-lead refusal of out-of-scope work.

### Check logs

```bash
# Live tail of either app
fly logs -a hermes-gateway
fly logs -a hermes-coding-squad

# Gateway log file directly
fly ssh console -a hermes-gateway -C "tail -50 /opt/data/logs/gateway.log"

# Audit log
fly ssh console -a hermes-gateway -C "bash /opt/data/skills/custom/audit-log/scripts/audit_query.sh -n 50"
```

### Restart without redeploying

```bash
fly machine restart -a hermes-gateway $(fly machines list -a hermes-gateway --json | jq -r '.[0].id')
```

Useful when you've pushed a new SOUL.md or skill to the repo and want it picked up without rebuilding the image.

## Adding a Skill

1. Create `skills/custom/<name>/SKILL.md` with required frontmatter (`name`, `description`, `version`).
2. Add scripts under `skills/custom/<name>/scripts/` (auto-`chmod +x` happens on boot).
3. Commit. The pre-commit hook validates frontmatter and shellchecks scripts.
4. `git push`. On next restart/deploy, both apps pull the new skill from GitHub.

For skills that should run on **only one app**, gate their use in that app's SOUL.md.

## Adding an Agent (third Hermes app)

1. Create a new `flyio-<role>/` directory with `fly.toml`, `Dockerfile`, `start.sh`, `SOUL.md` (copy from `flyio-squad/`).
2. Add the new agent to `skills/custom/call-agent/references/agents.yaml`.
3. Create the Fly app + volume:

   ```bash
   fly apps create hermes-<role>
   fly volumes create <role>_data -a hermes-<role> --region fra --size 3 --yes
   fly secrets set OPENROUTER_API_KEY=... GITHUB_PAT=... API_SERVER_KEY=$(openssl rand -hex 32) -a hermes-<role>
   ```

4. Set the cross-app bearer tokens on both peer apps so they can call each other.
5. Deploy and add a smoke test for it.

## Security & Guardrails

- **No public HTTP** — neither app exposes a public port. All inter-app traffic stays on Fly 6PN.
- **Bearer-token auth** — every API call carries a Fly-secret-backed bearer; each app validates incoming.
- **Squad refuses out-of-scope work** — Microsoft repos, work-adjacent code, anything > 250 LOC, anything destructive. Hard guardrails enforced by `tech-lead` skill + repo whitelist.
- **Never merges** — squad opens PRs but never `gh pr merge`, never force-pushes, never deletes branches.
- **All autonomous actions audited** — append-only JSON-Lines log; agents can't truncate.
- **Secrets via `fly secrets`** — never in files, never in code. Both apps use scoped fine-grained PATs.

See `flyio/SOUL.md` and `skills/custom/tech-lead/SKILL.md` for the full rules each agent must follow.

## Status

Foundation is live and tested. Active work focuses on extending the squad with specialized skills (designer for UI work, reviewer enhancements) and adding additional agents for non-coding domains (research, health, household coordination).

---

*Maintained by Rishi Jatia, with Hermes Agent and Claude.*
