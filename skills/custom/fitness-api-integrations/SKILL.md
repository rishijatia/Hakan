---
name: fitness-api-integrations
description: Connect to wearable/fitness device APIs (WHOOP, Fitbit, Garmin, Apple Health, Oura) — OAuth setup, scopes, approval requirements, Python libraries, and data access patterns.
triggers:
  - whoop data
  - fitness API
  - wearable data
  - recovery score
  - sleep data
  - strain data
  - HRV data
  - health data API
---

# Fitness API Integrations

Connect to wearable/fitness device data programmatically. Each device has its own OAuth flow, scopes, and approval process.

## General Pattern

1. Research the developer platform (most wearables have one)
2. Register an app — note the approval threshold (personal use vs public)
3. Identify OAuth scopes needed for the user's data goals
4. Set up OAuth 2.0 flow (authorization code grant)
5. Store credentials as Fly.io secrets (`fly secrets set KEY=value`)
6. Build polling scripts (cron) or webhook listeners (real-time)

## Supported Devices

See `references/` for device-specific setup guides:

- **WHOOP** → `references/whoop.md` — Official OAuth API, 10-member dev limit, recovery/sleep/strain/workout data. Includes full endpoint list, scopes, approval requirements, Python libraries, and setup steps.

## System Design

### Two Approaches

**Approach A: Daily Profile for Agent Awareness (Recommended for personal use)**
Simple: daily cron fetches WHOOP data → writes coaching-style summary to file → agent reads it before conversations. No database. Agent becomes contextually aware of user's sleep/recovery/strain state.

- Tokens stored in JSON file (`/opt/data/whoop/tokens.json`)
- Summary stored as markdown (`/opt/data/whoop/daily_profile.json`)
- Raw data cached at `/opt/data/whoop/daily_profile_raw.json`
- Hermes cron job runs `whoop_daily.py` daily at 9:15am ET, sends summary to Telegram
- Agent reads profile file to know user's fitness state
- Key: summary should be **action-oriented** (coach, not dashboard). Lead with "what should I do today" not "here are your numbers."

**Approach B: Full Fitness Tracker (for exercise progression tracking)**
Full SQLite database with workouts, exercise sets, sleep, recovery, planned workouts. See `references/system-design.md` for complete schema and Principal Engineer review findings. Use when user wants to track individual lift progressions (bench press max, squat volume, etc.).

### RunCoach Spec (Running-Specific)
A PM spec for a running coach skill exists at `/opt/data/workspace/run_coach_spec.md`. Key insight: WHOOP data can derive pace (distance/time), aerobic efficiency (pace normalized by HR), and zone balance scores. The biggest finding for active runners: most recreational runners spend too much time in Z4-Z5 (racing every run). The #1 intervention is building Z2 aerobic base (target 70-80% easy running).

## Automation Scripts

- `scripts/whoop_daily.py` — **Primary script.** Refreshes token, fetches WHOOP data, writes coaching-style daily profile summary (not data dump). Handles on-demand refresh + re-auth alerts. Run via Hermes cron at 9:15am ET.
- `scripts/whoop_query.py` — **Q&A data fetcher.** Fetches fresh data (last N days) and outputs JSON for on-demand queries. Updates cache file. Usage: `python3 whoop_query.py 30`
- `scripts/whoop_refresh.sh` — Standalone shell-based token refresh (legacy, prefer Python script).
- `scripts/whoop_fetch.sh` — Standalone shell-based data fetch (legacy, prefer Python script).

## Common Scopes Across Devices

| Data Type       | Typical Scope Names                          |
|-----------------|----------------------------------------------|
| Recovery/Readiness | `read:recovery`, `read:readiness`          |
| Sleep           | `read:sleep`                                 |
| Workouts/Strain | `read:workout`, `read:activity`              |
| Heart Rate/HRV  | `read:heart_rate`, `read:recovery`           |
| Body Metrics    | `read:body_measurement`, `read:weight`       |
| Profile         | `read:profile`                               |

## Python Libraries by Device

| Device | Library | Stars | Notes |
|--------|---------|-------|-------|
| WHOOP  | `hedgertronic/whoop` | 98 | Returns DataFrames, MIT license |
| WHOOP  | `gabrielmbmb/whoop-client` | — | Includes MCP server |
| WHOOP  | `rowesk/Whoop-Data-Downloader` | 1 | CLI downloader |

## Approval Thresholds (Important!)

Most wearable APIs have a **dev mode** that works immediately for personal use (typically ≤10 users). Going public requires:
- Privacy Policy URL
- Brand/design guidelines compliance
- App submission form
- Terms of Use agreement

**For personal use, none of this is needed** — just register, get credentials, and go.

## API Limitations (Important!)

**WHOOP API is READ-ONLY.** There are no POST/PUT/PATCH endpoints for workouts, sleep, or recovery data. You cannot:
- Create or edit workouts programmatically
- Delete workout data
- Write any user data back to WHOOP

**Strength Trainer exercise data is NOT exposed via API.** WHOOP's Strength Trainer feature (where users log individual sets, reps, and weights) exists only in the WHOOP app. The API returns only aggregate workout data:
- `sport_name` (e.g. "weightlifting_msk", "running")
- `strain` (0-21 cardiovascular load score)
- `avg_heart_rate`, `max_heart_rate`
- `duration`, `calories`, `distance` (if applicable)
- Zone durations (time in each HR zone)

**No exercise-level detail** — no exercise names, no sets/reps/weights, no movement breakdown. For tracking individual lift progressions (e.g. "bench press max"), you need a separate exercise logging system alongside WHOOP.

**Workarounds for exercise tracking:**
1. User voice input after workout ("did bench 185x5 today") → parse and store in local DB
2. Screenshot OCR — user sends WHOOP Strength Trainer screenshot → vision model extracts data
3. Manual logging via conversational input
4. Import from third-party apps (Strong, Apple Health, etc.)

## Pitfalls

- **Don't assume you need approval for personal use.** Most platforms (WHOOP, Fitbit, etc.) allow immediate dev-mode access for small user counts.
- **Webhooks may be required for OAuth.** WHOOP returned `request_forbidden` on the OAuth flow until a webhook URL was added to the app config. Even if you don't plan to use webhooks, add a placeholder HTTPS webhook URL (e.g., `https://your-app.fly.dev/whoop-webhook`) to the app settings.
- **HTTPS required for redirect URIs.** WHOOP rejects `http://` redirect URIs. Use an HTTPS URL.
- **OAuth `state` parameter is mandatory.** Must be ≥8 characters or WHOOP returns `invalid_state` error.
- **Redirect URIs must match exactly.** Include the full path (e.g., `https://your-app.fly.dev/callback`, not just `https://your-app.fly.dev`).
- **Client Secrets must stay server-side.** Never expose in client code, logs, or Telegram messages. Use Fly.io secrets.
- **Scopes are one-way.** You can always request fewer scopes later, but adding new scopes requires re-authorization from the user.
- **Research docs before trial-and-error.** When a user asks to connect to a new API, read the developer docs (OAuth page, API reference, OpenAPI spec) FIRST before generating auth links or guessing at parameters. The user will get frustrated if they have to authorize multiple times because you didn't read about required parameters (state, scopes, redirect URI format) upfront. Use `curl` to fetch docs, parse HTML, and extract the OpenAPI spec URL. Don't make the user click through auth flows repeatedly.
- **Use curl/web_extract for static docs, not browser.** Documentation pages are static HTML — fetch with `curl` + HTML parsing or `web_extract`. Save browser automation for dynamic/JS-rendered content, auth flows, and interactive forms.
- **Secret redaction can mangle tokens in transit.** When `security.redact_secrets` is enabled, tokens get mangled by the time they reach the LLM context. To save OAuth tokens reliably: pipe the token exchange response directly to a file in a single shell command (`curl ... | python3 -c "import sys,json; open('/tmp/token.txt','w').write(json.load(sys.stdin)['access_token'])"`). Then read from file for API calls. The token never passes through the tool output layer.
- **Cloudflare blocks default urllib User-Agent.** WHOOP's API is behind Cloudflare which returns error 1010 for Python urllib requests with the default User-Agent. Fix: `req.add_header("User-Agent", "Mozilla/5.0 hermes-whoop/1.0")` on all urllib requests. Alternatively, use `curl` for all API calls.
- **urllib timeout must be a single int.** `urllib.request.urlopen(req, timeout=30)` works. `timeout=(5, 30)` (tuple) causes `TypeError`. The tuple form is for the `requests` library, not `urllib`.
- **WHOOP field name: `distance_meter` (singular).** The API returns `distance_meter`, NOT `distance_meters`. Using the wrong name silently returns None. Always check the OpenAPI spec for exact field names.
