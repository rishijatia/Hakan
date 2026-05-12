# Browserbase Plan Tiers & Feature Availability

Based on Hermes `browser_providers/browserbase.py` (lines 56-147) and live testing.

## Feature → Plan Mapping

| Feature | Env Var | Launch Plan | Scale Plan |
|---------|---------|:-----------:|:----------:|
| Basic stealth | (always on) | ✅ | ✅ |
| Cloud browser session | (implicit) | ✅ | ✅ |
| Residential proxies | `BROWSERBASE_PROXIES=true` | ❌ (402) | ✅ |
| Advanced stealth | `BROWSERBASE_ADVANCED_STEALTH=true` | ❌ (402) | ✅ |
| Keep-alive sessions | `BROWSERBASE_KEEP_ALIVE=true` | ⚠️ may 402 | ✅ |

## What Each Feature Does

- **Basic stealth** — random fingerprints, standard browser profile. Helps with basic bot checks but NOT Cloudflare/PerimeterX.
- **Residential proxies** — routes traffic through real residential IPs. Critical for StreetEasy, Zillow, Apartments.com, Google Search. Without this, the IP is a known datacenter IP and gets captcha'd.
- **Advanced stealth** — custom Chromium build that avoids bot detection signatures. Combined with residential proxies, this beats most anti-bot systems.

## Error Behavior

The Hermes Browserbase provider handles 402 gracefully:
1. Tries with all requested features
2. If 402 on keepAlive → retries without it
3. If 402 on proxies → retries without proxies
4. Session always succeeds (just with fewer features)

The browser response includes a `stealth_warning` field when proxies are unavailable.

## Recommendation

For apartment searching (StreetEasy, Zillow), the **Scale plan** is required.
Without residential proxies, Browserbase sessions are no better than local Chrome
from a datacenter — same captchas, same blocks.

## Required Env Vars

```
BROWSERBASE_API_KEY=bb_live_xxxxx        # From browserbase.com dashboard
BROWSERBASE_PROJECT_ID=proj_xxxxx        # From browserbase.com dashboard
BROWSERBASE_PROXIES=true                 # Enable residential proxies
BROWSERBASE_ADVANCED_STEALTH=true        # Enable custom Chromium (Scale only)
```

Set via `fly secrets set` (preferred) or `.env`.
