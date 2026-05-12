# PR Comment Monitor — Setup Reference

## Cron Job
- **Name:** PR Comment Monitor
- **Job ID:** `9b99d8719c52`
- **Schedule:** Every 2 hours
- **Mode:** `no_agent: true` (script runs directly, no LLM)

## Script Location
```
~/.hermes/scripts/pr_comment_monitor.py
```
Must be in `~/.hermes/scripts/` — cron uses relative paths from this directory.

## Seen File
```
/opt/data/pr_monitor_seen.json
```
Tracks already-reported comment IDs to avoid re-alerting. Reset with:
```bash
rm /opt/data/pr_monitor_seen.json
```

## Environment Variables
- `PR_MONITOR_REPO` — owner/repo (default: `rishijatia/Hakan`)
- `PR_MONITOR_GH_PATH` — path to gh CLI (default: `/opt/data/bin/gh`)

## How It Works
1. Lists all open PRs via `gh pr list`
2. Fetches review comments for each PR
3. Filters: skips "Fixed" replies, skips Copilot overview messages, deduplicates
4. Compares against seen file — only reports NEW unresolved comments
5. Outputs to stdout (cron delivers to Telegram)
6. Silent when nothing new

## Cron Setup
```
cronjob create:
  name: PR Comment Monitor
  schedule: every 2h
  no_agent: true
  script: pr_comment_monitor.py
```

## Troubleshooting
- **Script not found:** Check it's in `~/.hermes/scripts/`, not `/opt/data/scripts/`
- **Always reports same comments:** Delete seen file to reset
- **Never reports:** Check `gh auth status` and that GH_TOKEN is in environment
- **Too many alerts:** Script deduplicates by (path, line, body_prefix) — should be fine
