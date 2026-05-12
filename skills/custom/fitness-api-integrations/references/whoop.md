# WHOOP API Reference

## Developer Platform

- **URL**: https://developer.whoop.com
- **API Docs**: https://developer.whoop.com/api (Redocly-powered OpenAPI spec)
- **OpenAPI Spec**: `https://api.prod.whoop.com/developer/doc/openapi.json`
- **Dashboard**: https://developer.whoop.com/dashboard (requires WHOOP account login via id.whoop.com)

## Authentication

- **Type**: OAuth 2.0 Authorization Code
- **Auth URL**: `https://api.prod.whoop.com/oauth/oauth2/auth`
- **Token URL**: `https://api.prod.whoop.com/oauth/oauth2/token`
- **Credentials**: Client ID + Client Secret (obtained after app creation)
- **State parameter**: REQUIRED, must be ≥8 characters

### OAuth Flow

```
# 1. User visits auth URL (browser) — include 'offline' scope for refresh tokens
https://api.prod.whoop.com/oauth/oauth2/auth
  ?response_type=code
  &client_id=YOUR_CLIENT_ID
  &redirect_uri=https://your-app.fly.dev/callback
  &scope=read:recovery+read:sleep+read:workout+read:cycles+read:profile+read:body_measurement+offline
  &state=random8chars

# 2. User authorizes → redirected to callback with ?code=XXX&state=XXX

# 3. Exchange code for token (pipe directly to file to avoid secret redaction)
curl -s -X POST https://api.prod.whoop.com/oauth/oauth2/token \
  -d "grant_type=authorization_code" \
  -d "code=THE_CODE" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "redirect_uri=https://your-app.fly.dev/callback" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); open('/tmp/whoop_token.txt','w').write(d['access_token']); open('/tmp/whoop_refresh.txt','w').write(d.get('refresh_token',''))"
```

Token response (without `offline` scope):
```json
{
  "access_token": "...",
  "expires_in": 3599,
  "scope": "read:recovery read:sleep read:workout read:cycles read:profile read:body_measurement",
  "token_type": "bearer"
}
```

## Refresh Tokens (Critical for Automation)

Without the `offline` scope, access tokens expire in ~1 hour and there's no way to refresh — the user must re-authorize. For any automated/cron use case, include `offline` in the scopes.

### Getting a Refresh Token

Add `offline` to the scopes in the auth URL:
```
scope=read:recovery+read:sleep+read:workout+read:cycles+read:profile+read:body_measurement+offline
```

Token response WITH `offline` scope:
```json
{
  "access_token": "...",
  "expires_in": 3600,
  "refresh_token": "...",
  "scope": "offline read:recovery read:sleep read:workout read:cycles read:profile read:body_measurement",
  "token_type": "bearer"
}
```

### Refreshing the Token

```bash
curl -X POST https://api.prod.whoop.com/oauth/oauth2/token \
  -d "grant_type=refresh_token" \
  -d "refresh_token=YOUR_REFRESH_TOKEN" \
  -d "client_id=YOUR_CLIENT_ID" \
  -d "client_secret=YOUR_CLIENT_SECRET" \
  -d "scope=offline"
```

Response returns a **new access token AND a new refresh token**. The old refresh token is invalidated on use.

**Strategy**: Run a cron job every ~45 minutes to refresh before the 1-hour expiry. Save both tokens to disk after each refresh.

### Token Refresh Pitfalls

- **Each refresh token is single-use.** The response contains a NEW refresh token — always save it.
- **Concurrent refresh requests will fail.** Only one process should refresh. Use a lock file or single cron job.
- **Scope must include `offline`.** The refresh request must include `scope=offline` or it won't return a new refresh token.
- **Scope name is `offline`, NOT `offline_access`.** WHOOP uses `offline`, not the more common `offline_access` seen in other OAuth providers.

## API Base URL

**CRITICAL**: The API base URL is **`https://api.prod.whoop.com/developer`**, NOT `https://api.prod.whoop.com`.

Using the wrong base returns `default backend - 404` for all endpoints.

## Available Scopes

| Scope | Data |
|-------|------|
| `offline` | **Required for refresh tokens.** Not a data scope — enables long-lived access. |
| `read:recovery` | Recovery score, HRV, resting heart rate |
| `read:cycles` | Day strain, average heart rate during physiological cycle |
| `read:workout` | Activity strain, workout heart rate |
| `read:sleep` | Sleep performance %, duration per sleep stage |
| `read:profile` | Name, email |
| `read:body_measurement` | Height, weight, max heart rate |

## API Endpoints (v2)

All paths relative to `https://api.prod.whoop.com/developer`:

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v2/cycle` | Physiological cycles (paginated) |
| GET | `/v2/cycle/{cycleId}` | Single cycle |
| GET | `/v2/cycle/{cycleId}/recovery` | Recovery for a cycle |
| GET | `/v2/cycle/{cycleId}/sleep` | Sleep for a cycle |
| GET | `/v2/recovery` | All recovery records (paginated) |
| GET | `/v2/activity/sleep` | All sleep records (paginated) |
| GET | `/v2/activity/sleep/{sleepId}` | Single sleep record |
| GET | `/v2/activity/workout` | All workouts (paginated) |
| GET | `/v2/activity/workout/{workoutId}` | Single workout |
| GET | `/v2/user/profile/basic` | Profile info |
| GET | `/v2/user/measurement/body` | Body measurements |
| DELETE | `/v2/user/access` | Revoke user access |
| GET | `/v1/activity-mapping/{activityV1Id}` | Map v1 ID to v2 UUID |

### Token Refresh Endpoint

| Method | Path | Description |
|--------|------|-------------|
| POST | `/oauth/oauth2/token` | Exchange code for token OR refresh token |

### OpenAPI Spec

Download: `https://api.prod.whoop.com/developer/doc/openapi.json`

## App Registration Requirements

### For Development / Personal Use (≤10 members)
- Works **immediately** after creation — no approval needed
- Need: Scopes (including `offline` for refresh tokens) + Redirect URI (HTTPS) + Webhook URL (required even as placeholder)
- Create a Team first (prompted automatically)

### For Public Launch (>10 members)
Approval process requires:
1. WHOOP API Terms of Use compliance
2. Tested with at least one WHOOP member
3. App Name, Contact Email(s), and **Privacy Policy URL** filled in
4. WHOOP Design and Brand Guidelines compliance
5. App Submission form via their intake link

## Webhooks

- v1 webhooks have been **removed** (migration to v2 required)
- v2 webhooks: POST to your HTTPS URL with `{ user_id, id, type, trace_id }`
- Event types: `workout.updated`, `workout.deleted`, `sleep.updated`, `sleep.deleted`, `recovery.updated`, `recovery.deleted`
- Signature validation: `base64(HMACSHA256(timestamp + body, client_secret))` via `X-WHOOP-Signature` header
- Model version v2 uses UUID IDs (aligns with v2 API endpoints)

### Webhook URL Required for OAuth
During testing, WHOOP returned `request_forbidden` on the OAuth consent flow until a webhook URL was configured in the app settings. **Always add a webhook URL** (even a placeholder) when creating a WHOOP app.

## Python Libraries

### hedgertronic/whoop (98 stars, MIT)
- GitHub: https://github.com/hedgertronic/whoop
- Returns pandas DataFrames
- `pip install whoop` (or from source)

### gabrielmbmb/whoop-client
- GitHub: https://github.com/gabrielmbmb/whoop-client
- Python wrapper + MCP server integration

### rowesk/Whoop-Data-Downloader
- GitHub: https://github.com/rowesk/Whoop-Data-Downloader
- CLI tool for downloading sleep, workout, recovery data

## Pitfalls

- **Base URL is `/developer`** — `https://api.prod.whoop.com/developer`, not `https://api.prod.whoop.com`. Missing this gives 404 on every endpoint.
- **OAuth `state` param is mandatory** — must be ≥8 characters. Without it: `invalid_state` error.
- **HTTPS required for redirect URIs** — `http://` URIs are rejected.
- **Webhook URL must be configured** — OAuth flow returns `request_forbidden` without one, even if you don't use webhooks.
- **Redirect URI must match exactly** — full path including trailing component (e.g., `/callback` not just `/`).
- **No refresh token without `offline` scope** — access token expires in ~1 hour. Add `offline` scope to get a refresh token for automated use.
- **Scope is `offline`, not `offline_access`** — WHOOP uses `offline`. Using `offline_access` may cause errors.
- **Saving tokens through Hermes terminal tool** — when `security.redact_secrets` is enabled, tokens get mangled before reaching the LLM. Workaround: pipe token exchange response directly to file in a single shell command (`curl ... | python3 -c "import sys,json; open('/tmp/token.txt','w').write(json.load(sys.stdin)['access_token'])"`), then read from file for subsequent API calls.
- **OAuth codes are single-use** — each authorization code can only be exchanged once. If the exchange fails or the token gets lost, the user must re-authorize.
- **Cloudflare blocks urllib** — WHOOP's API is behind Cloudflare which returns error 1010 for Python urllib requests. Use `curl` for all API calls.
- **OpenAPI spec URL** — `https://api.prod.whoop.com/developer/doc/openapi.json` (not at the developer.whoop.com domain)
- **v1 vs v2 IDs** — v1 uses integer IDs, v2 uses UUIDs. Use `/v1/activity-mapping/{id}` to convert.
- **Rate limiting** — applies (check docs for current limits).
