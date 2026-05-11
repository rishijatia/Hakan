#!/usr/bin/env python3
"""WHOOP daily profile updater. Refreshes token, fetches data, writes coach-style briefing."""

import json
import os
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

TOKENS_FILE = Path("/opt/data/whoop/tokens.json")
PROFILE_FILE = Path("/opt/data/whoop/daily_profile.json")
BASE_URL = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
ET_OFFSET = timedelta(hours=-4)  # EDT


def load_tokens():
    with open(TOKENS_FILE) as f:
        return json.load(f)


def save_tokens(data):
    with open(TOKENS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def utc_to_et(utc_str):
    """Convert ISO UTC string to ET datetime."""
    dt = datetime.fromisoformat(utc_str.replace("Z", "+00:00"))
    return dt.astimezone(timezone(ET_OFFSET))


def ms_to_hm(ms):
    """Convert milliseconds to Xh Ym string."""
    h = ms // 3600000
    m = (ms % 3600000) // 60000
    if h > 0:
        return f"{h}h {m}m"
    return f"{m}m"


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
    tokens["refresh_token"] = result["refresh_token"]
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
            if e.code == 429:
                time.sleep(2 ** attempt * 5)
                continue
            elif e.code == 401:
                return {"_auth_error": True}
            elif e.code >= 500:
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
        return None
    data["profile"] = profile

    recovery = api_get("/v2/recovery?limit=14", token)
    data["recovery"] = recovery.get("records", []) if "_error" not in recovery else []

    sleep = api_get("/v2/activity/sleep?limit=14", token)
    data["sleep"] = sleep.get("records", []) if "_error" not in sleep else []

    workout = api_get("/v2/activity/workout?limit=14", token)
    data["workout"] = workout.get("records", []) if "_error" not in workout else []

    cycles = api_get("/v2/cycle?limit=14", token)
    data["cycles"] = cycles.get("records", []) if "_error" not in cycles else []

    body = api_get("/v2/user/measurement/body", token)
    data["body"] = body if "_error" not in body else {}

    return data


def compute_trends(records, field_path, days=7):
    """Compute average and trend for a field over N days."""
    def get_nested(obj, path):
        for key in path.split("."):
            if isinstance(obj, dict):
                obj = obj.get(key)
            else:
                return None
        return obj

    values = []
    for r in records[:days]:
        v = get_nested(r, field_path)
        if v is not None:
            values.append(v)

    if not values:
        return None, None

    avg = sum(values) / len(values)
    if len(values) >= 3:
        first_half = sum(values[len(values)//2:]) / (len(values) - len(values)//2)
        second_half = sum(values[:len(values)//2]) / (len(values)//2)
        trend = "↗️" if second_half > first_half * 1.05 else "↘️" if second_half < first_half * 0.95 else "→"
    else:
        trend = "→"

    return avg, trend


def compute_sleep_debt(sleeps, days=7):
    """Estimate cumulative sleep debt over N days."""
    total_debt_ms = 0
    for s in sleeps[:days]:
        needed = s.get("score", {}).get("sleep_needed", {})
        debt = needed.get("need_from_sleep_debt_milli", 0)
        total_debt_ms += debt
    return total_debt_ms


def recovery_emoji(score):
    if score >= 67:
        return "🟢"
    elif score >= 34:
        return "🟡"
    else:
        return "🔴"


def sport_emoji(name):
    name = (name or "").lower()
    if "run" in name:
        return "🏃"
    elif "lift" in name or "weight" in name:
        return "🏋️"
    elif "stair" in name:
        return "🪜"
    elif "cycle" in name or "bike" in name:
        return "🚴"
    elif "swim" in name:
        return "🏊"
    elif "yoga" in name:
        return "🧘"
    else:
        return "💪"


def sport_display(name):
    name = (name or "").lower()
    if "weightlifting" in name or "weight" in name:
        return "Lifting"
    elif "running" in name or "run" in name:
        return "Running"
    elif "stair" in name:
        return "Stairmaster"
    elif "cycling" in name or "bike" in name:
        return "Cycling"
    elif "swimming" in name or "swim" in name:
        return "Swimming"
    return name.title()


def build_coaching_briefing(data):
    """Build an action-oriented morning briefing — coach, not dashboard."""
    now_et = datetime.now(timezone(ET_OFFSET))
    lines = [f"🌅 Good morning, Rishi", ""]

    # Recovery
    recs = data.get("recovery", [])
    if recs:
        r = recs[0]
        s = r.get("score", {})
        score = s.get("recovery_score", 0)
        hrv = s.get("hrv_rmssd_milli", 0)
        rhr = s.get("resting_heart_rate", 0)
        emoji = recovery_emoji(score)

        # 7-day trend
        hrv_avg, hrv_trend = compute_trends(recs, "score.hrv_rmssd_milli", 7)
        rec_avg, rec_trend = compute_trends(recs, "score.recovery_score", 7)

        lines.append(f"🔋 Recovery: {score:.0f} {emoji} | HRV: {hrv:.0f}ms {hrv_trend or ''} | RHR: {rhr:.0f}")
        if rec_avg:
            lines.append(f"📊 7-day avg: recovery {rec_avg:.0f} | HRV {hrv_avg:.0f}ms")

    # Sleep
    sleeps = data.get("sleep", [])
    if sleeps:
        sl = sleeps[0]
        sc = sl.get("score", {})
        stages = sc.get("stage_summary", {})
        total_ms = stages.get("total_in_bed_time_milli", 0)
        perf = sc.get("sleep_performance_percentage", 0)
        debt_ms = compute_sleep_debt(sleeps, 7)
        sws_min = stages.get("total_slow_wave_sleep_time_milli", 0) // 60000
        rem_min = stages.get("total_rem_sleep_time_milli", 0) // 60000

        # Wake time
        wake_et = utc_to_et(sl["end"])
        wake_str = wake_et.strftime("%-I:%M%p").lower()

        lines.append(f"😴 Sleep: {ms_to_hm(total_ms)} | Perf: {perf:.0f}% | Woke: {wake_str}")

        if debt_ms > 3600000:
            debt_h = debt_ms // 3600000
            debt_m = (debt_ms % 3600000) // 60000
            lines.append(f"⚠️ Sleep debt: {debt_h}h {debt_m}m (7-day cumulative)")

    # Yesterday's workout
    workouts = data.get("workout", [])
    if workouts:
        w = workouts[0]
        w_start = w.get("start", "")
        if w_start[:10] == (now_et - timedelta(days=1)).strftime("%Y-%m-%d") or \
           w_start[:10] == now_et.strftime("%Y-%m-%d"):
            sc = w.get("score", {})
            dur_ms = 0
            if w.get("start") and w.get("end"):
                try:
                    s = datetime.fromisoformat(w["start"].replace("Z", "+00:00"))
                    e = datetime.fromisoformat(w["end"].replace("Z", "+00:00"))
                    dur_ms = (e - s).total_seconds() * 1000
                except:
                    pass
            sport = sport_display(w.get("sport_name"))
            emoji = sport_emoji(w.get("sport_name"))
            dist = sc.get("distance_meters")
            dist_str = f" | {dist/1000:.1f}km" if dist else ""
            lines.append(f"{emoji} Yesterday: {sport} — {ms_to_hm(dur_ms)}, strain {sc.get('strain', 0):.1f}{dist_str}")

    # Today's cycle (if already started)
    cycles = data.get("cycles", [])
    if cycles:
        c = cycles[0]
        cs = c.get("score", {})
        strain = cs.get("strain", 0)
        if strain > 0:
            lines.append(f"📈 Today's strain so far: {strain:.1f}/21")

    # Coaching recommendation
    lines.append("")

    if recs:
        score = recs[0].get("score", {}).get("recovery_score", 0)
        debt_ms = compute_sleep_debt(sleeps, 7) if sleeps else 0
        recent_strain = sum(w.get("score", {}).get("strain", 0) for w in workouts[:3]) if workouts else 0

        if score >= 67 and debt_ms < 3600000:
            lines.append("💡 Green light — you're recovered. Push hard today.")
        elif score >= 67 and debt_ms >= 3600000:
            lines.append("💡 Recovery is good but sleep debt is building. Solid workout OK, but prioritize sleep tonight.")
        elif score >= 34:
            if recent_strain > 30:
                lines.append("💡 Yellow zone + high recent strain. Consider a lighter session — Z2 cardio or mobility work.")
            else:
                lines.append("💡 Moderate recovery. You can train, but listen to your body and don't go max effort.")
        else:
            lines.append("💡 Red zone — take a rest day. Your body needs recovery. Light walk or stretching only.")

    # Weekly workout summary
    if len(workouts) >= 3:
        lines.append("")
        run_count = sum(1 for w in workouts[:7] if "run" in (w.get("sport_name") or "").lower())
        lift_count = sum(1 for w in workouts[:7] if "lift" in (w.get("sport_name") or "").lower() or "weight" in (w.get("sport_name") or "").lower())
        cardio_other = sum(1 for w in workouts[:7] if w.get("sport_name") and "run" not in w["sport_name"].lower() and "lift" not in w["sport_name"].lower() and "weight" not in w["sport_name"].lower())
        total_strain = sum(w.get("score", {}).get("strain", 0) for w in workouts[:7])
        lines.append(f"📅 This week: {len(workouts[:7])} workouts ({run_count} runs, {lift_count} lifts) | Total strain: {total_strain:.0f}")

    return "\n".join(lines)


def build_weekly_review(data):
    """Build a Sunday weekly review."""
    now_et = datetime.now(timezone(ET_OFFSET))
    lines = [f"📊 Week in Review — {now_et.strftime('%b %d')}", ""]

    workouts = data.get("workout", [])
    sleeps = data.get("sleep", [])
    recs = data.get("recovery", [])

    if workouts:
        run_count = sum(1 for w in workouts[:7] if "run" in (w.get("sport_name") or "").lower())
        lift_count = sum(1 for w in workouts[:7] if "lift" in (w.get("sport_name") or "").lower() or "weight" in (w.get("sport_name") or "").lower())
        total_strain = sum(w.get("score", {}).get("strain", 0) for w in workouts[:7])
        avg_strain = total_strain / min(len(workouts), 7)
        lines.append(f"🏋️ {min(len(workouts), 7)} workouts: {run_count} runs, {lift_count} lifts")
        lines.append(f"⚡ Total strain: {total_strain:.0f} | Avg daily: {avg_strain:.1f}")

    if sleeps:
        avg_perf, perf_trend = compute_trends(sleeps, "score.sleep_performance_percentage", 7)
        total_sleep_ms = sum(s.get("score", {}).get("stage_summary", {}).get("total_in_bed_time_milli", 0) for s in sleeps[:7])
        avg_sleep_ms = total_sleep_ms / min(len(sleeps), 7)
        debt_ms = compute_sleep_debt(sleeps, 7)
        lines.append(f"😴 Avg sleep: {ms_to_hm(int(avg_sleep_ms))} | Perf: {avg_perf:.0f}% {perf_trend}")
        if debt_ms > 0:
            lines.append(f"💤 Cumulative sleep debt: {ms_to_hm(debt_ms)}")

    if recs:
        avg_rec, rec_trend = compute_trends(recs, "score.recovery_score", 7)
        best = max(recs[:7], key=lambda r: r.get("score", {}).get("recovery_score", 0))
        best_date = best.get("created_at", "")[:10]
        best_score = best.get("score", {}).get("recovery_score", 0)
        lines.append(f"💚 Avg recovery: {avg_rec:.0f} {rec_trend} | Best: {best_score:.0f} on {best_date}")

    # Observations
    lines.append("")
    lines.append("🔍 Observations:")

    if recs and sleeps:
        # Check recovery trend
        avg_rec, rec_trend = compute_trends(recs, "score.recovery_score", 7)
        if rec_trend == "↘️":
            lines.append("• Recovery trending down — consider a rest day or lighter week")
        elif rec_trend == "↗️":
            lines.append("• Recovery trending up — training load is balancing well")

        # Check sleep consistency
        wake_times = []
        for s in sleeps[:7]:
            if s.get("end"):
                wake_et = utc_to_et(s["end"])
                wake_times.append(wake_et.hour * 60 + wake_et.minute)
        if wake_times:
            spread = max(wake_times) - min(wake_times)
            if spread > 90:
                lines.append("• Wake time varies by >1.5hrs — inconsistent sleep schedule affects recovery")

    return "\n".join(lines)


def main():
    tokens = load_tokens()

    # Try fetching with current token
    data = fetch_all(tokens["access_token"])

    # If auth error, refresh and retry
    if data is None:
        print("Token expired, refreshing...", file=sys.stderr)
        new_token = refresh_access_token(tokens)
        if not new_token:
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

    # Determine if it's Sunday (weekly review) or daily briefing
    now_et = datetime.now(timezone(ET_OFFSET))
    if now_et.weekday() == 6:  # Sunday
        summary = build_weekly_review(data)
    else:
        summary = build_coaching_briefing(data)

    with open(PROFILE_FILE, "w") as f:
        f.write(summary)

    print(summary)


if __name__ == "__main__":
    main()
