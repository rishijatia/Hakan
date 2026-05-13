---
name: audit-log
description: "Append-only audit log for autonomous agent actions. Every meaningful action (peer call, PR open, file write, cron fire, secret read) must be logged so Rishi can review what agents have done without being present."
version: 0.1.0
author: Hakan
metadata:
  hermes:
    tags: [observability, logging, audit, foundation]
    related_skills: [call-agent]
---

# Audit Log — Observability for Autonomous Actions

Every Hermes agent on this system writes meaningful autonomous actions to a shared append-only log at `/opt/data/logs/audit.log`. This is how Rishi reviews what agents have done — without being present for each action.

The log is **JSON Lines** (one JSON object per line) so it can be grepped, filtered with `jq`, and turned into dashboards/cron alerts later.

## When To Log

**Always log:**
- Peer agent calls (`call-agent` invocations)
- PR creation, branch pushes, commits
- File writes outside `/opt/data/sessions/`
- Cron job firings (start + completion)
- Secret reads (note: don't log the value, just the access)
- Telegram/Discord messages sent on behalf of the user
- Skill installations / config changes
- Failures and escalations to the user

**Don't log:**
- Conversational replies (those are session history, not audit-worthy)
- Read-only operations (file reads, status checks)
- Internal tool dispatch within a single turn

## How To Log

From any shell context on any agent:

```bash
bash /opt/data/skills/custom/audit-log/scripts/log_action.sh \
  <action-category> "free-text description" [outcome]
```

Examples:

```bash
bash .../log_action.sh peer-call "Asked squad to fix PR Hakan#42 review comments"
bash .../log_action.sh pr-open "Opened rishijatia/Hakan#43 (add audit-log skill)" success
bash .../log_action.sh cron-fire "Daily WHOOP brief at 09:15 ET" success
bash .../log_action.sh escalate "Stuck on apartment-search auth flow, asked Rishi" pending
```

Action categories should be lowercase, hyphenated, and reused across agents.

## How To Read

```bash
# Last 20 entries (default)
bash /opt/data/skills/custom/audit-log/scripts/audit_query.sh

# Filter by agent or action
bash .../audit_query.sh --agent squad --action pr-open
bash .../audit_query.sh --since 2026-05-12

# Raw JSON for piping into jq
bash .../audit_query.sh --json | jq 'select(.outcome=="failure")'
```

## Log Format

```json
{"ts":"2026-05-13T02:30:00Z","agent":"hermes-gateway","action":"peer-call","description":"Asked squad to identify itself","outcome":"success"}
```

Fields:
- `ts` — ISO-8601 UTC timestamp, second precision
- `agent` — Fly app name (e.g., `hermes-gateway`, `hermes-coding-squad`)
- `action` — short category, hyphenated
- `description` — free-text human-readable explanation
- `outcome` — optional: `success` | `failure` | `partial` | `pending`

## Rules

- **Append-only.** Never modify or delete entries. If something needs correction, append a new entry pointing to the original.
- **No secrets.** Never include passwords, tokens, or API keys in descriptions. Reference them by env-var name only (e.g., "read SQUAD_API_KEY", not the value).
- **No PII.** Per SOUL.md privacy rules — names, emails, etc. don't go in audit descriptions.
- **All agents log to the same file.** The `agent` field disambiguates who did what. Future: ship to a central audit collector for cross-app querying.
