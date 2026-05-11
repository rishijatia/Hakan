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

1. **Daily cron** runs at 8am UTC → fetches WHOOP data → sends Telegram summary
2. **Token auto-refresh** using `offline` scope refresh token (no re-auth needed)
3. **Profile file** at `/opt/data/whoop/daily_profile.json` is readable by Hermes for contextual awareness

## Files

```
/opt/data/whoop/
├── tokens.json              # OAuth tokens (access + refresh + client credentials)
├── daily_profile.json       # Latest human-readable profile summary
├── daily_profile_raw.json   # Latest raw API data (JSON)
└── daily_update.py          # Main sync script (also at /opt/data/scripts/whoop_daily.py)
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
import sys, json
d = json.load(sys.stdin)
open('/opt/data/whoop/tokens.json','w').write(json.dumps({
    'access_token': d['access_token'],
    'refresh_token': d.get('refresh_token',''),
    'expires_at': '',
    'client_id': '<CLIENT_ID>',
    'client_secret': '<CLIENT_SECRET>',
    'redirect_uri': '<REDIRECT_URI>'
}, indent=2))
print(f'Saved. refresh_token: {len(d.get(\"refresh_token\",\"\"))} chars')
"
```

### 3. Set Up Cron Job
```bash
# In Hermes:
cronjob create --name "WHOOP Daily Profile" --schedule "0 8 * * *" --script whoop_daily.py
```

## API Details

- **Base URL:** `https://api.prod.whoop.com/developer`
- **Auth:** OAuth 2.0 with `offline` scope for refresh tokens
- **Token expiry:** 1 hour (auto-refreshed before each use)
- **Endpoints used:**
  - `GET /v2/user/profile/basic` — name, email
  - `GET /v2/user/measurement/body` — height, weight, max HR
  - `GET /v2/recovery?limit=7` — recovery score, HRV, RHR, SpO2
  - `GET /v2/activity/sleep?limit=7` — sleep stages, performance, efficiency
  - `GET /v2/activity/workout?limit=7` — strain, HR, duration, sport type
  - `GET /v2/cycle?limit=7` — daily strain, calories

## Token Refresh Flow

```
Before each API call:
1. Read tokens.json
2. If access_token expired:
   a. POST to /oauth/oauth2/token with grant_type=refresh_token
   b. Save new access_token + new refresh_token
   c. If refresh fails → send re-auth link via Telegram
3. Proceed with API call
```

## Pitfalls

- **Secret redaction:** Hermes redacts tokens in terminal output. All token handling must be atomic (curl | python3 → file). Never pass tokens through LLM context.
- **Cloudflare blocking:** WHOOP API blocks bare urllib requests. Add `User-Agent: Mozilla/5.0 hermes-whoop/1.0` header.
- **urllib timeout:** Use `timeout=30` (single int), NOT `timeout=(5, 30)` (tuple is for `requests` library).
- **Token file location:** `/opt/data/whoop/tokens.json` (not .env — avoids redaction issues).
- **Offline scope:** Must be included in both the app settings AND the auth URL. Not listed in OpenAPI spec but documented in OAuth docs.

## What WHOOP API Cannot Do

- ❌ Create/edit/delete workouts
- ❌ Read Strength Trainer exercise data (sets, reps, weights)
- ❌ Write any data back to WHOOP
- Exercise tracking must be done manually (voice input or separate system)
