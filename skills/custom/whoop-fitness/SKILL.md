---
name: whoop-fitness
description: "WHOOP fitness integration — daily sleep/recovery/strain profiles, token auto-refresh, and Telegram summaries."
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [fitness, whoop, health, sleep, recovery, telegram]
    related_skills: [google-workspace]
---

# WHOOP Fitness Integration

Daily WHOOP data sync with automatic token refresh and Telegram summaries. Provides contextual awareness of the user's sleep, recovery, strain, and workout history.

## How It Works

1. **Daily cron** runs at **12:00 UTC** (= 8am EDT in summer / 7am EST in winter). **Note: the correct schedule is `0 12 * * *`, which is 12pm UTC — not 8am UTC (which would be 4am ET and wrong).** Cron is UTC-fixed so the ET display time shifts by 1 hour with DST. → fetches WHOOP data → sends Telegram summary
2. **Token auto-refresh** using `offline` scope refresh token (no re-auth needed)
3. **Profile file** at `/opt/data/whoop/daily_profile.json` is readable by Hermes for contextual awareness

## Files

```
/opt/data/whoop/
├── tokens.json              # OAuth tokens (access + refresh + client credentials)
├── daily_profile.json       # Latest profile summary (JSON: {timestamp, summary_text})
├── daily_profile_raw.json   # Latest raw API data (JSON)

skills/custom/whoop-fitness/scripts/
├── whoop_daily.py           # Main daily sync script (cron target)
├── whoop_query.py           # On-demand Q&A data fetcher
└── run_coach.py             # WHOOP-powered running coach

Install: symlink or copy scripts into `/opt/data/scripts/` for cron access.
```

## Setup

### 1. Register WHOOP App
1. Go to https://developer.whoop.com
2. Create an app with these scopes:
   - `read:recovery`, `read:sleep`, `read:workout`, `read:cycles`, `read:profile`, `read:body_measurement`, `offline`
3. Set redirect URI to: `https://<your-fly-app>.fly.dev/callback`

### 2. Initial OAuth Authorization
Generate auth URL:
```
https://api.prod.whoop.com/oauth/oauth2/auth?response_type=code&client_id=<CLIENT_ID>&redirect_uri=<REDIRECT_URI>&scope=read%3Arecovery+read%3Asleep+read%3Aworkout+read%3Acycles+read%3Aprofile+read%3Abody_measurement+offline&state=<random_8_chars>
```

Exchange code for tokens (atomic — token never exposed to LLM due to redaction):
```bash
curl -s -X POST https://api.prod.whoop.com/oauth/oauth2/token \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=authorization_code" \
  -d "code=<CODE>" \
  -d "client_id=<CLIENT_ID>" \
  -d "client_secret=<CLIENT_SECRET>" \
  -d "redirect_uri=<REDIRECT_URI>" | python3 -c "
import sys, json, os
d = json.load(sys.stdin)
path = '/opt/data/whoop/tokens.json'
open(path,'w').write(json.dumps({
    'access_token': d['access_token'],
    'refresh_token': d.get('refresh_token',''),
    'expires_at': '',
    'client_id': '<CLIENT_ID>',
    'client_secret': '<CLIENT_SECRET>',
    'redirect_uri': '<REDIRECT_URI>'
}, indent=2))
os.chmod(path, 0o600)
print(f'Saved. refresh_token: {len(d.get(\"refresh_token\",\"\"))} chars')
"
```

### 3. Set Up Cron Job
```bash
# In Hermes (8am ET = 12pm UTC during EDT):
cronjob create --name "WHOOP Daily Profile" --schedule "0 12 * * *" --script whoop_daily.py
```
**Note:** Cron is hardcoded to UTC. Adjust for DST: 12pm UTC = 8am EDT, 1pm UTC = 8am EST.

## API Details

- **Base URL:** `https://api.prod.whoop.com/developer`
- **Auth:** OAuth 2.0 with `offline` scope for refresh tokens
- **Token expiry:** 1 hour (auto-refreshed after 401 response)
- **Endpoints used:**
  - `GET /v2/user/profile/basic` — name, email
  - `GET /v2/user/measurement/body` — height, weight, max HR
  - `GET /v2/recovery?limit=7` — recovery score, HRV, RHR, SpO2
  - `GET /v2/activity/sleep?limit=7` — sleep stages, performance, efficiency, wake time (end field)
  - `GET /v2/activity/workout?limit=7` — strain, HR, duration, sport type
  - `GET /v2/cycle?limit=7` — daily strain, calories

## Token Refresh Flow

```
On fetch:
1. Attempt all API calls with current access_token
2. If any endpoint returns 401:
   a. POST to /oauth/oauth2/token with grant_type=refresh_token
   b. Save new access_token (keep existing refresh_token if none returned)
   c. Retry full fetch with new token
   d. If refresh fails → write error profile JSON with re-auth URL (built from stored redirect_uri)
```

## Pitfalls

- **Secret redaction:** Hermes redacts tokens in terminal output (`security.redact_secrets: true`). All token handling must be atomic (curl | python3 → file). Never pass tokens through LLM context. Use `execute_code` or single shell pipelines.
- **Cloudflare blocking:** WHOOP API blocks bare `urllib` requests (error 1010). Add `User-Agent: Mozilla/5.0 hermes-whoop/1.0` header, or use `curl` instead.
- **urllib timeout:** Use `timeout=30` (single int), NOT `timeout=(5, 30)` (tuple is for `requests` library).
- **Token file location:** `/opt/data/whoop/tokens.json` (not .env — avoids redaction issues).
- **Offline scope:** Must be included in both the app settings AND the auth URL. Not listed in OpenAPI spec but documented at `https://developer.whoop.com/docs/developing/oauth`.
- **API base URL:** `https://api.prod.whoop.com/developer` (not just `/whoop.com`). Discovered via OpenAPI spec at `/developer/doc/openapi.json`.
- **Auth codes are single-use:** Each code can only be exchanged once. If the exchange fails or the token gets redacted, generate a fresh auth link.
- **OAuth state parameter:** WHOOP requires `state` with minimum 8 characters.
- **Redirect URI must match exactly:** Including path (`/callback` vs `/whoop-callback`) — no trailing slash.
- **Cron timezone:** Cron uses UTC. 8am ET = 12pm UTC (EDT) or 1pm UTC (EST). Adjust seasonally.

## Wake Time Tracking

Sleep records include `end` time which is the user's wake-up time. Scripts convert from UTC to ET using `zoneinfo.ZoneInfo('America/New_York')` (DST-aware). Typical wake window: 7:50–9:00 AM ET.

## Q&A Support

When Rishi asks fitness questions, use the WHOOP data to answer. Two approaches:

### 1. Use cached data (fast)
Read `/opt/data/whoop/daily_profile_raw.json` — contains data from the last fetch. The daily cron (`whoop_daily.py`) fetches the last 14 records per endpoint; on-demand runs via `whoop_query.py` default to 30 days (configurable). Check the file's timestamp to confirm freshness.

### 2. Fetch fresh data (if needed)
```bash
python3 /opt/data/scripts/whoop_query.py 30  # fetches last 30 days
```
Outputs JSON to stdout. Also updates the cache file.

### Question Types & How to Answer

| Type | Example | Approach |
|------|---------|----------|
| **State** | "How's my recovery?" | Read latest recovery from cache |
| **Trend** | "Is my HRV improving?" | Compare 7-day vs 30-day averages |
| **Causal** | "Did my run affect sleep?" | Correlate workout date → next day sleep |
| **Comparison** | "Runs vs lifts — what recovers better?" | Group workouts by type, avg next-day recovery |
| **Advice** | "Should I work out today?" | Check recovery + recent strain + sleep debt |
| **Specific** | "How much did I sleep Tuesday?" | Filter sleep by date |
| **Aggregate** | "Total miles this month?" | Sum workout distances |

### Coaching Rules
1. **Lead with the answer**, then explain the data
2. **Be honest** — if data is insufficient, say so
3. **Give actionable advice** — not just numbers
4. **Use context** — consider day of week, recent patterns, sleep debt
5. **Keep it concise** — 3-5 lines max unless asked for detail

### Example Q&A

**Q:** "Should I run today?"
**A:** "Recovery is 61 🟡. You ran yesterday (strain 13.2) and sleep debt is 1.8hrs. Swap for Z2 stairmaster or rest. If you do run, 30min max, stay in Z2."

**Q:** "Do I sleep better after runs or lifts?"
**A:** "Last 30 days: after runs — avg sleep perf 84%, 7h 12m. After lifts — 78%, 6h 48m. Run days give you better sleep, especially morning runs. Evening lifts past 7pm correlate with worst sleep."

**Q:** "Am I overtraining?"
**A:** "Checking... Last 7 days: 6 workouts, avg strain 11.4. Recovery declined 4 of 5 days (72→41). Sleep debt climbing. HRV dipped to 38ms (avg 52ms). ⚠️ Yes, looks like overreaching. Take 2 rest days."

## What WHOOP API Cannot Do

- ❌ Create/edit/delete workouts
- ❌ Read Strength Trainer exercise data (sets, reps, weights)
- ❌ Write any data back to WHOOP
- Exercise tracking must be done manually (voice input or separate system)
