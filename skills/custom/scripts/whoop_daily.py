#!/usr/bin/env python3
"""WHOOP daily profile updater. Refreshes token, fetches data, writes summary."""

import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

TOKENS_FILE = Path("/opt/data/whoop/tokens.json")
PROFILE_FILE = Path("/opt/data/whoop/daily_profile.json")
BASE_URL = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"


def load_tokens():
    with open(TOKENS_FILE) as f:
        return json.load(f)


def save_tokens(data):
    with open(TOKENS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def refresh_access_token(tokens):
    """Refresh the access token using the refresh token."""
    import urllib.request
    import urllib.parse

    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
        "client_id": tokens["client_id"],
        "client_secret": tokens["client_secret"],
        "scope": "offline",
    }).encode()

    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("User-Agent", "Mozilla/5.0 hermes-whoop/1.0")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
    except Exception as e:
        print(f"ERROR: Token refresh failed: {e}", file=sys.stderr)
        return None

    if "error" in result:
        print(f"ERROR: {result.get('error_hint', result['error'])}", file=sys.stderr)
        return None

    tokens["access_token"] = result["access_token"]
    tokens["refresh_token"] = result["refresh_token"]  # new refresh token
    tokens["expires_at"] = datetime.now(timezone.utc).isoformat()
    save_tokens(tokens)
    return tokens["access_token"]


def api_get(path, token, retries=3):
    """GET request with retry and timeout."""
    import urllib.request

    url = f"{BASE_URL}{path}"
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url)
            req.add_header("Authorization", f"Bearer {token}")
            req.add_header("User-Agent", "Mozilla/5.0 hermes-whoop/1.0")
            with urllib.request.urlopen(req, timeout=30) as resp:
                return json.loads(resp.read())
        except urllib.error.HTTPError as e:
            if e.code == 429:  # Rate limited
                time.sleep(2 ** attempt * 5)
                continue
            elif e.code == 401:
                return {"_auth_error": True}
            elif e.code >= 500:  # Server error
                time.sleep(2 ** attempt * 2)
                continue
            else:
                return {"_error": f"HTTP {e.code}"}
        except Exception as e:
            if attempt < retries - 1:
                time.sleep(2 ** attempt)
                continue
            return {"_error": str(e)}
    return {"_error": "max retries exceeded"}


def fetch_all(token):
    """Fetch latest data from all endpoints."""
    data = {}

    profile = api_get("/v2/user/profile/basic", token)
    if "_auth_error" in profile:
        return None  # signal to refresh
    data["profile"] = profile

    recovery = api_get("/v2/recovery?limit=7", token)
    data["recovery"] = recovery.get("records", []) if "_error" not in recovery else []

    sleep = api_get("/v2/activity/sleep?limit=7", token)
    data["sleep"] = sleep.get("records", []) if "_error" not in sleep else []

    workout = api_get("/v2/activity/workout?limit=7", token)
    data["workout"] = workout.get("records", []) if "_error" not in workout else []

    cycles = api_get("/v2/cycle?limit=7", token)
    data["cycles"] = cycles.get("records", []) if "_error" not in cycles else []

    body = api_get("/v2/user/measurement/body", token)
    data["body"] = body if "_error" not in body else {}

    return data


def build_summary(data):
    """Build a human-readable daily profile."""
    now = datetime.now(timezone.utc)
    lines = [f"# WHOOP Daily Profile — {now.strftime('%Y-%m-%d %H:%M UTC')}", ""]

    # Profile
    p = data.get("profile", {})
    if p:
        lines.append(f"**User:** {p.get('first_name', '')} {p.get('last_name', '')}")
    b = data.get("body", {})
    if b:
        lines.append(f"**Body:** {b.get('height_meter', 0)*100:.0f}cm, {b.get('weight_kilogram', 0):.1f}kg, Max HR: {b.get('max_heart_rate', '?')}")
    lines.append("")

    # Latest Recovery
    recs = data.get("recovery", [])
    if recs:
        r = recs[0]
        s = r.get("score", {})
        score = s.get("recovery_score", 0)
        emoji = "🟢" if score >= 67 else "🟡" if score >= 34 else "🔴"
        lines.append(f"## Latest Recovery ({r['created_at'][:10]})")
        lines.append(f"- Score: {score:.0f}% {emoji}")
        lines.append(f"- HRV: {s.get('hrv_rmssd_milli', 0):.1f}ms")
        lines.append(f"- RHR: {s.get('resting_heart_rate', 0):.0f} bpm")
        lines.append(f"- SpO2: {s.get('spo2_percentage', 0):.1f}%")
        lines.append(f"- Skin Temp: {s.get('skin_temp_celsius', 0):.1f}°C")
        if s.get("user_calibrating"):
            lines.append("- ⚠️ User still calibrating — scores may be unreliable")
        lines.append("")

        # Recovery trend (last 7)
        if len(recs) > 1:
            scores = [r.get("score", {}).get("recovery_score", 0) for r in recs]
            avg = sum(scores) / len(scores)
            trend = "📈 trending up" if scores[0] > scores[-1] else "📉 trending down" if scores[0] < scores[-1] else "➡️ stable"
            lines.append(f"**7-day recovery trend:** avg {avg:.0f}%, {trend}")
            lines.append("")

    # Latest Sleep + Wake Time
    sleeps = data.get("sleep", [])
    if sleeps:
        sl = sleeps[0]
        sc = sl.get("score", {})
        stages = sc.get("stage_summary", {})
        total_ms = stages.get("total_in_bed_time_milli", 0)
        h, m = total_ms // 3600000, (total_ms % 3600000) // 60000
        lines.append(f"## Latest Sleep ({sl['start'][:10]})")
        lines.append(f"- Duration: {h}h {m}m")
        lines.append(f"- Performance: {sc.get('sleep_performance_percentage', 0):.0f}%")
        lines.append(f"- Efficiency: {sc.get('sleep_efficiency_percentage', 0):.1f}%")
        lines.append(f"- SWS: {stages.get('total_slow_wave_sleep_time_milli', 0)//60000}m | REM: {stages.get('total_rem_sleep_time_milli', 0)//60000}m")
        lines.append(f"- Disturbances: {stages.get('disturbance_count', 0)}")
        lines.append(f"- Respiratory Rate: {sc.get('respiratory_rate', 0):.1f} breaths/min")
        debt_ms = sc.get("sleep_needed", {}).get("need_from_sleep_debt_milli", 0)
        if debt_ms > 3600000:
            lines.append(f"- ⚠️ Sleep debt: {debt_ms//3600000}h {(debt_ms%3600000)//60000}m")
        # Wake time
        if sl.get("end"):
            wake_utc = sl["end"]
            wake_hour = int(wake_utc[11:13])
            wake_min = int(wake_utc[14:16])
            # Convert UTC to ET (UTC-4 during EDT)
            et_hour = (wake_hour - 4) % 24
            lines.append(f"- Wake time: {et_hour}:{wake_min:02d} AM ET")
        lines.append("")

    # Latest Workouts
    workouts = data.get("workout", [])
    if workouts:
        lines.append("## Recent Workouts")
        for w in workouts[:5]:
            start = w.get("start", "")[:10]
            sport = w.get("sport_name", "unknown")
            strain = w.get("score", {}).get("strain", 0)
            dur_ms = 0
            if w.get("start") and w.get("end"):
                from datetime import datetime as dt
                try:
                    s = dt.fromisoformat(w["start"].replace("Z", "+00:00"))
                    e = dt.fromisoformat(w["end"].replace("Z", "+00:00"))
                    dur_ms = (e - s).total_seconds() * 1000
                except:
                    pass
            dur_h, dur_m = int(dur_ms // 3600000), int((dur_ms % 3600000) // 60000)
            hr = w.get("score", {}).get("average_heart_rate", 0)
            dist = w.get("score", {}).get("distance_meters")
            dist_str = f" | {dist/1000:.1f}km" if dist else ""
            lines.append(f"- {start}: **{sport}** — {dur_h}h{dur_m:02d}m, strain {strain:.1f}, avg HR {hr}{dist_str}")
        lines.append("")

    # Daily Strain
    cycles = data.get("cycles", [])
    if cycles:
        c = cycles[0]
        cs = c.get("score", {})
        lines.append(f"## Today's Cycle")
        lines.append(f"- Strain: {cs.get('strain', 0):.1f}/21")
        lines.append(f"- Avg HR: {cs.get('average_heart_rate', 0)} | Max HR: {cs.get('max_heart_rate', 0)}")
        lines.append(f"- Calories: {cs.get('kilojoule', 0)/4.184:.0f} kcal")
        lines.append("")

    return "\n".join(lines)


def main():
    tokens = load_tokens()

    # Try fetching with current token
    data = fetch_all(tokens["access_token"])

    # If auth error, refresh and retry
    if data is None:
        print("Token expired, refreshing...")
        new_token = refresh_access_token(tokens)
        if not new_token:
            # Write error profile
            error_profile = {
                "timestamp": datetime.now(timezone.utc).isoformat(),
                "error": "Token refresh failed. User needs to re-authorize.",
                "auth_url": f"https://api.prod.whoop.com/oauth/oauth2/auth?response_type=code&client_id={tokens['client_id']}&redirect_uri=https%3A%2F%2Fhermes-gateway.fly.dev%2Fcallback&scope=read%3Arecovery+read%3Asleep+read%3Aworkout+read%3Acycles+read%3Aprofile+read%3Abody_measurement+offline&state=rereauth01"
            }
            with open(PROFILE_FILE, "w") as f:
                json.dump(error_profile, f, indent=2)
            print("AUTH_NEEDED")
            return
        data = fetch_all(new_token)
        if data is None:
            print("ERROR: Still auth error after refresh", file=sys.stderr)
            return

    # Save raw data
    with open(str(PROFILE_FILE).replace(".json", "_raw.json"), "w") as f:
        json.dump(data, f, indent=2, default=str)

    # Build and save summary
    summary = build_summary(data)
    with open(PROFILE_FILE, "w") as f:
        f.write(summary)

    print(summary)


if __name__ == "__main__":
    main()
