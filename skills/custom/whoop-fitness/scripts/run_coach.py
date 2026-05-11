#!/usr/bin/env python3
"""RunCoach — WHOOP-powered running coach for Rishi Jatia.
Commands: brief | post-run | digest | q <question>
"""

import json
import os
import sys
import tempfile
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

# Paths
TOKENS_FILE = Path("/opt/data/whoop/tokens.json")
PROFILE_FILE = Path("/opt/data/whoop/daily_profile_raw.json")
BASE_URL = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"
ET_TZ = ZoneInfo("America/New_York")

# Ensure data directory exists on first run
TOKENS_FILE.parent.mkdir(parents=True, exist_ok=True)

# Rishi's config
MAX_HR = 194  # observed max HR
# WHOOP zones (5-zone model mapped to Rishi's max HR 194)
# WHOOP sends zone_zero through zone_five as bins relative to its own max HR (190)
# We remap to Rishi's actual zones for coaching:
HR_ZONES = {
    "Z0 (Recovery)":  (0, 97),
    "Z1 (Easy)":      (97, 116),
    "Z2 (Aerobic)":   (116, 136),
    "Z3 (Tempo)":     (136, 155),
    "Z4 (Threshold)": (155, 175),
    "Z5 (VO2max)":    (175, 194),
}
Z2_CAP = HR_ZONES["Z2 (Aerobic)"][1]  # derived from HR_ZONES


# ── Token management ────────────────────────────────────────────────────────

def load_tokens():
    """Load tokens from disk. Returns None if file is missing or malformed."""
    try:
        with open(TOKENS_FILE) as f:
            return json.load(f)
    except FileNotFoundError:
        return None
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: tokens.json is corrupt: {e}", file=sys.stderr)
        return None

def save_tokens(data):
    """Write tokens atomically with restrictive permissions."""
    fd, tmp_path = tempfile.mkstemp(dir=TOKENS_FILE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, TOKENS_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise

def refresh_access_token(tokens):
    import urllib.request, urllib.parse
    data = urllib.parse.urlencode({
        "grant_type": "refresh_token",
        "refresh_token": tokens["refresh_token"],
        "client_id": tokens["client_id"],
        "client_secret": tokens["client_secret"],
        "scope": "offline",
    }).encode()
    req = urllib.request.Request(TOKEN_URL, data=data, method="POST")
    req.add_header("Content-Type", "application/x-www-form-urlencoded")
    req.add_header("User-Agent", "Mozilla/5.0 hermes-runcoach/1.0")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            result = json.loads(resp.read())
    except Exception as e:
        print(f"ERROR: Token refresh failed: {e}", file=sys.stderr)
        return None
    if "error" in result:
        print(f"ERROR: {result}", file=sys.stderr)
        return None
    if "access_token" not in result:
        print("ERROR: Token refresh response missing access_token", file=sys.stderr)
        return None
    tokens["access_token"] = result["access_token"]
    tokens["refresh_token"] = result.get("refresh_token", tokens["refresh_token"])
    expires_in = result.get("expires_in", 3600)
    tokens["expires_at"] = (datetime.now(timezone.utc) + timedelta(seconds=expires_in)).isoformat()
    save_tokens(tokens)
    return tokens["access_token"]

def api_get(path, token, retries=3):
    import urllib.request
    import urllib.error
    url = f"{BASE_URL}{path}"
    for attempt in range(retries):
        try:
            req = urllib.request.Request(url)
            req.add_header("Authorization", f"Bearer {token}")
            req.add_header("User-Agent", "Mozilla/5.0 hermes-runcoach/1.0")
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
    data = {}
    errors = {}
    profile = api_get("/v2/user/profile/basic", token)
    if "_auth_error" in profile:
        return None
    if "_error" in profile:
        errors["profile"] = profile["_error"]
    data["profile"] = profile
    recovery = api_get("/v2/recovery?limit=30", token)
    if "_auth_error" in recovery:
        return None
    if "_error" in recovery:
        errors["recovery"] = recovery["_error"]
    data["recovery"] = recovery.get("records", []) if "_error" not in recovery else []
    sleep = api_get("/v2/activity/sleep?limit=30", token)
    if "_auth_error" in sleep:
        return None
    if "_error" in sleep:
        errors["sleep"] = sleep["_error"]
    data["sleep"] = sleep.get("records", []) if "_error" not in sleep else []
    workout = api_get("/v2/activity/workout?limit=30", token)
    if "_auth_error" in workout:
        return None
    if "_error" in workout:
        errors["workout"] = workout["_error"]
    data["workout"] = workout.get("records", []) if "_error" not in workout else []
    cycles = api_get("/v2/cycle?limit=14", token)
    if "_auth_error" in cycles:
        return None
    if "_error" in cycles:
        errors["cycles"] = cycles["_error"]
    data["cycles"] = cycles.get("records", []) if "_error" not in cycles else []
    body = api_get("/v2/user/measurement/body", token)
    if "_auth_error" in body:
        return None
    if "_error" in body:
        errors["body"] = body["_error"]
    data["body"] = body if "_error" not in body else {}
    if errors:
        data["_errors"] = errors
        print(f"WARNING: Partial fetch failures: {errors}", file=sys.stderr)
    return data


# ── Helpers ─────────────────────────────────────────────────────────────────

def utc_to_et(utc_str):
    dt = datetime.fromisoformat(utc_str.replace("Z", "+00:00"))
    return dt.astimezone(ET_TZ)

def ms_to_hm(ms):
    h = int(ms) // 3600000
    m = (int(ms) % 3600000) // 60000
    return f"{h}h {m}m" if h > 0 else f"{m}m"

def sec_to_pace(sec_per_km):
    """Convert seconds/km to M:SS format."""
    m = int(sec_per_km) // 60
    s = int(sec_per_km) % 60
    return f"{m}:{s:02d}"

def recovery_emoji(score):
    if score >= 67: return "🟢"
    if score >= 34: return "🟡"
    return "🔴"

def is_running(w):
    return "run" in (w.get("sport_name") or "").lower()

def get_workout_duration_ms(w):
    if w.get("start") and w.get("end"):
        try:
            s = datetime.fromisoformat(w["start"].replace("Z", "+00:00"))
            e = datetime.fromisoformat(w["end"].replace("Z", "+00:00"))
            return (e - s).total_seconds() * 1000
        except Exception:
            pass
    return 0

def get_zone_durations(score):
    """Extract zone durations dict from workout score."""
    zd = score.get("zone_durations", {})
    return {
        "z0": zd.get("zone_zero_milli", 0),
        "z1": zd.get("zone_one_milli", 0),
        "z2": zd.get("zone_two_milli", 0),
        "z3": zd.get("zone_three_milli", 0),
        "z4": zd.get("zone_four_milli", 0),
        "z5": zd.get("zone_five_milli", 0),
    }

def zone_pcts(zones):
    total = sum(zones.values())
    if total == 0:
        return {k: 0 for k in zones}
    return {k: round(v / total * 100, 1) for k, v in zones.items()}

def zone_bar(pct, width=20):
    filled = round(pct / 100 * width)
    return "█" * filled + "░" * (width - filled)


# ── Data extraction ─────────────────────────────────────────────────────────

def get_latest_recovery(recs):
    return recs[0] if recs else None

def get_latest_sleep(sleeps):
    return sleeps[0] if sleeps else None

def get_runs(workouts):
    return [w for w in workouts if is_running(w)]

def get_run_volume_km(runs, days=7):
    """Total km from runs in the last N days."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=days)
    total = 0
    for r in runs:
        try:
            start = datetime.fromisoformat(r["start"].replace("Z", "+00:00"))
            if start >= cutoff:
                dist = r.get("score", {}).get("distance_meter")
                if dist:
                    total += dist / 1000
        except Exception:
            pass
    return total

def days_since_last_run(runs):
    if not runs:
        return 99
    try:
        last = datetime.fromisoformat(runs[0]["start"].replace("Z", "+00:00"))
        delta = datetime.now(timezone.utc) - last
        return delta.days
    except Exception:
        return 99

def compute_sleep_debt(sleeps, days=7):
    total = 0
    for s in sleeps[:days]:
        debt = s.get("score", {}).get("sleep_needed", {}).get("need_from_sleep_debt_milli", 0)
        total += debt
    return total

def aggregate_run_zones(runs, days=14):
    """Aggregate zone durations across all runs in last N days."""
    now = datetime.now(timezone.utc)
    cutoff = now - timedelta(days=days)
    agg = {"z0": 0, "z1": 0, "z2": 0, "z3": 0, "z4": 0, "z5": 0}
    for r in runs:
        try:
            start = datetime.fromisoformat(r["start"].replace("Z", "+00:00"))
            if start >= cutoff:
                zones = get_zone_durations(r.get("score", {}))
                for k in agg:
                    agg[k] += zones[k]
        except Exception:
            pass
    return agg

def load_cached_data():
    """Load data from the cached profile file (written by whoop_daily.py)."""
    if not PROFILE_FILE.exists():
        return None
    with open(PROFILE_FILE) as f:
        return json.load(f)

def get_fresh_data():
    """Fetch fresh data from WHOOP API, refreshing token if needed."""
    tokens = load_tokens()
    if tokens is None:
        print("❌ WHOOP tokens not configured. Re-run the WHOOP setup skill or re-authorize.", file=sys.stderr)
        return None
    data = fetch_all(tokens["access_token"])
    if data is None:
        print("🔄 Token expired, refreshing...", file=sys.stderr)
        new_token = refresh_access_token(tokens)
        if not new_token:
            return None
        data = fetch_all(new_token)
        if data is None:
            return None
    # Update cache atomically with restrictive permissions
    fd, tmp_path = tempfile.mkstemp(dir=PROFILE_FILE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, default=str)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, PROFILE_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise
    return data


# ── Command: brief ──────────────────────────────────────────────────────────

def cmd_brief():
    data = load_cached_data()
    if not data:
        data = get_fresh_data()
    if not data:
        print("❌ Cannot load WHOOP data. Re-auth may be needed.")
        return

    now_et = datetime.now(ET_TZ)
    recs = data.get("recovery", [])
    sleeps = data.get("sleep", [])
    workouts = data.get("workout", [])
    runs = get_runs(workouts)

    r = get_latest_recovery(recs)
    sl = get_latest_sleep(sleeps)

    if not r:
        print("❌ No recovery data available.")
        return

    score = r.get("score", {}).get("recovery_score", 0)
    hrv = r.get("score", {}).get("hrv_rmssd_milli", 0)
    rhr = r.get("score", {}).get("resting_heart_rate", 0)
    emoji = recovery_emoji(score)

    # Sleep info
    sleep_perf = None
    sleep_total_ms = 0
    if sl:
        sc = sl.get("score", {})
        sleep_perf = sc.get("sleep_performance_percentage", 0)
        stages = sc.get("stage_summary", {})
        sleep_total_ms = stages.get("total_in_bed_time_milli", 0)

    debt_ms = compute_sleep_debt(sleeps, 7)
    days_off = days_since_last_run(runs)
    week_km = get_run_volume_km(runs, 7)

    # Determine decision
    poor_sleep = sleep_perf is not None and sleep_perf < 70
    if score < 50 or poor_sleep and score < 60:
        decision = "REST"
        decision_emoji = "🛑"
    elif score >= 70 and not poor_sleep:
        decision = "GO"
        decision_emoji = "✅"
    else:
        decision = "EASY"
        decision_emoji = "🟡"

    lines = []
    lines.append(f"🏃‍♂️ *RunCoach Morning Brief*")
    lines.append(f"_{now_et.strftime('%A, %b %d')}_")
    lines.append("")

    # Status panel
    lines.append(f"*Status*")
    lines.append(f"{emoji} Recovery: *{score:.0f}* | HRV: {hrv:.0f}ms | RHR: {rhr:.0f}")
    lines.append(f"😴 Sleep: {ms_to_hm(sleep_total_ms)} | Performance: {f'{sleep_perf:.0f}%' if sleep_perf is not None else 'N/A'}")
    if debt_ms > 1800000:
        debt_str = ms_to_hm(debt_ms)
        lines.append(f"⚠️ Sleep debt (7d): {debt_str}")
    lines.append(f"📅 Days since last run: *{days_off}*")
    lines.append(f"📊 Weekly run volume: *{week_km:.1f} km*")
    lines.append("")

    # Zone balance warning (14-day aggregate)
    agg_zones = aggregate_run_zones(runs, 14)
    agg_pcts = zone_pcts(agg_zones)
    high_z = agg_pcts["z4"] + agg_pcts["z5"]
    z2_pct = agg_pcts["z2"]
    if sum(agg_zones.values()) > 0:
        if high_z > 40:
            lines.append(f"🚨 *Zone imbalance*: {high_z:.0f}% in Z4-Z5 (target: <20%). Prioritize Z2!")
        elif z2_pct < 50:
            lines.append(f"⚠️ *Zone balance*: Only {z2_pct:.0f}% Z2 (target: 60%+). Slow down today.")
        lines.append("")

    # Prescription
    lines.append(f"*Today's Prescription: {decision_emoji} {decision}*")
    lines.append("")

    if decision == "GO":
        # Pick workout type based on days off and recent volume
        if days_off >= 3:
            # Back from rest — start with easy tempo
            lines.append("▸ *Easy Tempo Run* — 35-45 min")
            lines.append(f"  Warmup: 10 min Z1-Z2 (HR <{Z2_CAP})")
            lines.append(f"  Main: 20-25 min @ Z3 (HR {HR_ZONES['Z3 (Tempo)'][0]}-{HR_ZONES['Z3 (Tempo)'][1]})")
            lines.append(f"  Cooldown: 5-10 min Z1")
        elif week_km < 15:
            # Low volume week — build with aerobic base
            lines.append("▸ *Aerobic Base Run* — 40-50 min")
            lines.append(f"  Entire run in Z2 (HR <{Z2_CAP})")
            lines.append(f"  Pace: conversational, nose-breathing pace")
            lines.append(f"  Focus: build aerobic engine, not ego")
        else:
            # Good volume, recovered — intervals OK
            lines.append("▸ *Interval Session* — 45-50 min")
            lines.append(f"  Warmup: 10 min Z1-Z2 (HR <{Z2_CAP})")
            lines.append(f"  Main: 5×4min @ Z4 (HR {HR_ZONES['Z4 (Threshold)'][0]}-{HR_ZONES['Z4 (Threshold)'][1]}) w/ 2min Z1 jog recoveries")
            lines.append(f"  Cooldown: 8 min Z1-Z2")
        lines.append("")
        lines.append("💡 _You're recovered — this is your green light to push. But stay honest: Z2 on warmup/cooldown._")

    elif decision == "EASY":
        lines.append(f"▸ *Easy Z2 Run* — 30-40 min")
        lines.append(f"  HR cap: *{Z2_CAP} bpm* (top of Z2)")
        lines.append(f"  Pace: ignore pace entirely, run by HR only")
        lines.append(f"  If HR spikes above Z2, walk until it drops")
        lines.append("")
        lines.append(f"💡 _Recovery is moderate ({score:.0f}). Easy aerobic work is fine and beneficial — just don't push it. Shut the ego down._")

    else:  # REST
        lines.append("▸ *No running today*")
        lines.append("  • Light walk (20-30 min) if you want to move")
        lines.append("  • Mobility/stretching session")
        lines.append("  • Prioritize sleep tonight")
        lines.append("")
        if poor_sleep:
            lines.append(f"💡 _Sleep performance at {sleep_perf:.0f}% + recovery {score:.0f} = rest day. Your body rebuilds during rest, not during effort._")
        else:
            lines.append(f"💡 _Recovery at {score:.0f} — your system needs rest. Trust the process. A rest today enables a hard session tomorrow._")

    print("\n".join(lines))


# ── Command: post-run ───────────────────────────────────────────────────────

def cmd_post_run():
    data = load_cached_data()
    if not data:
        data = get_fresh_data()
    if not data:
        print("❌ Cannot load WHOOP data.")
        return

    workouts = data.get("workout", [])
    runs = get_runs(workouts)

    if not runs:
        print("❌ No recent running workouts found.")
        return

    w = runs[0]
    sc = w.get("score", {})
    w_start = w.get("start")
    if not w_start:
        print("❌ Most recent run missing start time.")
        return
    start_et = utc_to_et(w_start)
    dur_ms = get_workout_duration_ms(w)
    dur_sec = dur_ms / 1000
    dist_m = sc.get("distance_meter")
    avg_hr = sc.get("average_heart_rate", 0)
    max_hr_w = sc.get("max_heart_rate", 0)
    strain = sc.get("strain", 0)

    zones = get_zone_durations(sc)
    pcts = zone_pcts(zones)

    lines = []
    lines.append(f"🏃‍♂️ *Post-Run Analysis*")
    lines.append(f"_{start_et.strftime('%a %b %d, %-I:%M%p')}_")
    lines.append("")

    # Basic stats
    lines.append(f"*Workout Stats*")
    lines.append(f"⏱ Duration: {ms_to_hm(dur_ms)}")
    if dist_m:
        km = dist_m / 1000
        pace_sec = dur_sec / km
        lines.append(f"📏 Distance: {km:.2f} km")
        lines.append(f"⚡ Pace: {sec_to_pace(pace_sec)} /km")
    lines.append(f"❤️ Avg HR: {avg_hr} | Max HR: {max_hr_w}")
    lines.append(f"💪 Strain: {strain:.1f}/21")
    lines.append("")

    # Zone distribution
    lines.append(f"*Zone Distribution*")
    zone_labels = ["Z0", "Z1", "Z2", "Z3", "Z4", "Z5"]
    zone_keys = ["z0", "z1", "z2", "z3", "z4", "z5"]
    for label, key in zip(zone_labels, zone_keys):
        pct = pcts[key]
        dur = zones[key]
        bar = zone_bar(pct, 15)
        lines.append(f"  {label}: {bar} {pct:.0f}% ({ms_to_hm(dur)})")

    lines.append("")

    # Zone audit
    z4_z5_pct = pcts["z4"] + pcts["z5"]
    z2_pct = pcts["z2"]

    if z4_z5_pct > 30:
        lines.append(f"🚨 *Zone Audit: TOO MUCH HIGH INTENSITY*")
        lines.append(f"  Z4+Z5 = {z4_z5_pct:.0f}% of run (target: <20%)")
        lines.append(f"  Z2 = {z2_pct:.0f}% (target: 60%+)")
        lines.append(f"  _You're building anaerobic debt without aerobic base. This is the #1 issue in your training._")
    elif z2_pct < 50:
        lines.append(f"⚠️ *Zone Audit: Low Z2 time*")
        lines.append(f"  Z2 = {z2_pct:.0f}% (target: 60%+)")
        lines.append(f"  _Slow down. Your easy days aren't easy enough._")
    else:
        lines.append(f"✅ *Zone Audit: Good distribution*")
        lines.append(f"  Z2 = {z2_pct:.0f}% — solid aerobic work")

    lines.append("")

    # Intensity mismatch
    recs = data.get("recovery", [])
    if recs:
        rec_score = recs[0].get("score", {}).get("recovery_score", 0)
        if rec_score < 50 and z4_z5_pct > 25:
            lines.append(f"🚨 *Intensity Mismatch!*")
            lines.append(f"  Recovery was {rec_score:.0f} but you ran {z4_z5_pct:.0f}% Z4-Z5.")
            lines.append(f"  _Low recovery + high intensity = injury risk. Easy runs on low recovery days._")
            lines.append("")
        elif rec_score >= 70 and z2_pct > 80:
            lines.append(f"⚠️ *Missed opportunity*")
            lines.append(f"  Recovery was {rec_score:.0f} (great) but run was all Z2.")
            lines.append(f"  _High recovery days are for quality sessions — tempo or intervals._")
            lines.append("")

    # Recovery forecast
    lines.append(f"*Recovery Forecast*")
    if strain > 14:
        lines.append(f"  High strain ({strain:.1f}) — expect recovery dip tomorrow.")
        lines.append(f"  Sleep 8+ hrs tonight. No intense training tomorrow.")
    elif strain > 10:
        lines.append(f"  Moderate strain ({strain:.1f}) — normal recovery expected.")
        lines.append(f"  Light activity or rest tomorrow is fine.")
    else:
        lines.append(f"  Low strain ({strain:.1f}) — should recover well.")
        lines.append(f"  Good to train tomorrow if sleep is solid.")

    print("\n".join(lines))


# ── Command: digest ─────────────────────────────────────────────────────────

def cmd_digest():
    data = load_cached_data()
    if not data:
        data = get_fresh_data()
    if not data:
        print("❌ Cannot load WHOOP data.")
        return

    now_et = datetime.now(ET_TZ)
    workouts = data.get("workout", [])
    runs = get_runs(workouts)
    recs = data.get("recovery", [])
    sleeps = data.get("sleep", [])

    lines = []
    lines.append(f"📊 *Weekly Run Digest*")
    lines.append(f"_{now_et.strftime('%b %d, %Y')}_")
    lines.append("")

    # Volume
    week_km = get_run_volume_km(runs, 7)
    month_km = get_run_volume_km(runs, 28)
    avg_weekly_km = month_km / 4 if month_km > 0 else 0

    _cutoff_7d = datetime.now(timezone.utc) - timedelta(days=7)
    run_count_7d = 0
    for _r in runs:
        try:
            if datetime.fromisoformat(_r["start"].replace("Z", "+00:00")) >= _cutoff_7d:
                run_count_7d += 1
        except Exception:
            pass

    if week_km > avg_weekly_km * 1.15:
        trend = "↗️ up"
    elif week_km < avg_weekly_km * 0.85:
        trend = "↘️ down"
    else:
        trend = "→ steady"

    lines.append(f"*Running Volume*")
    lines.append(f"  This week: *{week_km:.1f} km* ({run_count_7d} runs)")
    lines.append(f"  4-week avg: {avg_weekly_km:.1f} km/week ({trend})")
    lines.append("")

    # Aerobic Efficiency Index
    # AEI = pace_sec_per_km / (avg_hr - resting_hr)
    if runs and recs:
        total_dist = 0
        total_time = 0
        total_hr = 0
        run_count = 0
        for r in runs[:7]:
            sc = r.get("score", {})
            dist = sc.get("distance_meter")
            dur = get_workout_duration_ms(r) / 1000
            hr = sc.get("average_heart_rate", 0)
            if dist and dist > 0 and dur > 0 and hr > 0:
                total_dist += dist
                total_time += dur
                total_hr += hr
                run_count += 1

        if run_count > 0 and total_dist > 0:
            avg_pace_sec = total_time / (total_dist / 1000)
            avg_run_hr = total_hr / run_count
            rhr = recs[0].get("score", {}).get("resting_heart_rate", 65)
            hr_reserve = avg_run_hr - rhr
            if hr_reserve > 0:
                aei = avg_pace_sec / hr_reserve
                lines.append(f"*Aerobic Efficiency Index*")
                lines.append(f"  AEI: *{aei:.2f}* (lower = better)")
                lines.append(f"  Pace: {sec_to_pace(avg_pace_sec)}/km | Avg HR: {avg_run_hr:.0f} | RHR: {rhr:.0f}")
                lines.append(f"  _AEI tracks aerobic fitness. It should improve over weeks of consistent Z2 work._")
                lines.append("")

    # Zone balance
    agg_zones = aggregate_run_zones(runs, 7)
    agg_pcts = zone_pcts(agg_zones)
    total_run_ms = sum(agg_zones.values())

    if total_run_ms > 0:
        z2_pct = agg_pcts["z2"]
        z4z5_pct = agg_pcts["z4"] + agg_pcts["z5"]

        lines.append(f"*Zone Balance (7-day)*")
        zone_labels = ["Z0", "Z1", "Z2", "Z3", "Z4", "Z5"]
        zone_keys = ["z0", "z1", "z2", "z3", "z4", "z5"]
        for label, key in zip(zone_labels, zone_keys):
            pct = agg_pcts[key]
            bar = zone_bar(pct, 12)
            lines.append(f"  {label}: {bar} {pct:.0f}%")

        if z2_pct >= 60:
            lines.append(f"  ✅ Z2 at {z2_pct:.0f}% — great aerobic base work!")
        elif z2_pct >= 40:
            lines.append(f"  ⚠️ Z2 at {z2_pct:.0f}% — needs more easy running (target 60%+)")
        else:
            lines.append(f"  🚨 Z2 at {z2_pct:.0f}% — way too low. {z4z5_pct:.0f}% in Z4-Z5 is unsustainable.")

        # Score
        z2_score = min(z2_pct / 60 * 100, 100)
        penalty = max(0, (z4z5_pct - 20) * 2)
        balance_score = max(0, z2_score - penalty)
        lines.append(f"  Zone Balance Score: *{balance_score:.0f}/100*")
        lines.append("")

    # Recovery & sleep
    if recs:
        avg_rec = sum(r.get("score", {}).get("recovery_score", 0) for r in recs[:7]) / min(len(recs), 7)
        lines.append(f"*Recovery & Sleep*")
        lines.append(f"  Avg recovery (7d): {avg_rec:.0f}")

    if sleeps:
        avg_perf = sum(s.get("score", {}).get("sleep_performance_percentage", 0) for s in sleeps[:7]) / min(len(sleeps), 7)
        debt = compute_sleep_debt(sleeps, 7)
        lines.append(f"  Avg sleep perf: {avg_perf:.0f}%")
        if debt > 0:
            lines.append(f"  Cumulative sleep debt: {ms_to_hm(debt)}")
    lines.append("")

    # Key insights
    lines.append(f"*Key Insights*")
    insights = []

    if runs:
        high_intensity_runs = 0
        for r in runs[:7]:
            rp = zone_pcts(get_zone_durations(r.get("score", {})))
            if rp["z4"] + rp["z5"] > 30:
                high_intensity_runs += 1
        if high_intensity_runs >= 2:
            insights.append(f"🚨 {high_intensity_runs}/7 runs had >30% Z4-Z5. You need to slow down on easy days.")

    if recs:
        low_rec_days = sum(1 for r in recs[:7] if r.get("score", {}).get("recovery_score", 0) < 50)
        if low_rec_days >= 3:
            insights.append(f"⚠️ {low_rec_days}/7 days below 50 recovery. Consider reducing training load or improving sleep.")

    if sleeps:
        debt = compute_sleep_debt(sleeps, 7)
        if debt > 7200000:  # >2 hours
            insights.append(f"😴 Sleep debt is {ms_to_hm(debt)}. This directly limits recovery and running performance.")

    if week_km > 0 and week_km < avg_weekly_km * 0.7:
        insights.append(f"📉 Volume dropped {((1 - week_km/avg_weekly_km)*100):.0f}% vs 4-week avg. Was this intentional?")

    if not insights:
        insights.append("✅ Training is balanced. Keep it up!")

    for ins in insights:
        lines.append(f"  {ins}")

    print("\n".join(lines))


# ── Command: q (question) ──────────────────────────────────────────────────

def cmd_question(question):
    data = load_cached_data()
    if not data:
        data = get_fresh_data()
    if not data:
        print("❌ Cannot load WHOOP data.")
        return

    q = question.lower().strip()
    workouts = data.get("workout", [])
    runs = get_runs(workouts)
    recs = data.get("recovery", [])
    sleeps = data.get("sleep", [])

    lines = []

    # Pattern match common questions
    if any(kw in q for kw in ["zone", "distribution", "balance", "easy", "z2", "aerobic"]):
        agg_zones = aggregate_run_zones(runs, 14)
        pcts = zone_pcts(agg_zones)
        lines.append(f"*Zone Distribution (14-day running)*")
        zone_labels = ["Z0", "Z1", "Z2", "Z3", "Z4", "Z5"]
        zone_keys = ["z0", "z1", "z2", "z3", "z4", "z5"]
        for label, key in zip(zone_labels, zone_keys):
            pct = pcts[key]
            bar = zone_bar(pct, 15)
            lines.append(f"  {label}: {bar} {pct:.0f}%")
        z4z5 = pcts["z4"] + pcts["z5"]
        lines.append("")
        if z4z5 > 30:
            lines.append(f"🚨 {z4z5:.0f}% in Z4-Z5 is too high. Target: <20%.")
            lines.append(f"💡 Your body adapts to aerobic base (Z2) much more efficiently than constant high intensity. 80/20 rule: 80% easy, 20% hard.")

    elif any(kw in q for kw in ["recover", "hrv", "rhr", "heart rate"]):
        if recs:
            lines.append(f"*Recovery Trends (7-day)*")
            for r in recs[:7]:
                s = r.get("score", {})
                dt = utc_to_et(r["created_at"]).strftime("%a %m/%d")
                score = s.get("recovery_score", 0)
                hrv = s.get("hrv_rmssd_milli", 0)
                rhr = s.get("resting_heart_rate", 0)
                emoji = recovery_emoji(score)
                lines.append(f"  {dt}: {emoji} {score:.0f} | HRV {hrv:.0f}ms | RHR {rhr:.0f}")

    elif any(kw in q for kw in ["sleep", "debt", "tired", "fatigue"]):
        if sleeps:
            lines.append(f"*Sleep Trends (7-day)*")
            for s in sleeps[:7]:
                sc = s.get("score", {})
                dt = utc_to_et(s["created_at"]).strftime("%a %m/%d")
                perf = sc.get("sleep_performance_percentage", 0)
                total = sc.get("stage_summary", {}).get("total_in_bed_time_milli", 0)
                debt = sc.get("sleep_needed", {}).get("need_from_sleep_debt_milli", 0)
                lines.append(f"  {dt}: {ms_to_hm(total)} | Perf {perf:.0f}% | Debt {ms_to_hm(debt)}")
            total_debt = compute_sleep_debt(sleeps, 7)
            lines.append(f"\n  7-day cumulative debt: *{ms_to_hm(total_debt)}*")

    elif any(kw in q for kw in ["pace", "speed", "fast", "slow", "time"]):
        if runs:
            lines.append(f"*Recent Run Paces*")
            for r in runs[:5]:
                sc = r.get("score", {})
                dt = utc_to_et(r["start"]).strftime("%a %m/%d")
                dist = sc.get("distance_meter")
                dur = get_workout_duration_ms(r) / 1000
                avg_hr = sc.get("average_heart_rate", 0)
                if dist and dist > 100:
                    pace = dur / (dist / 1000)
                    lines.append(f"  {dt}: {sec_to_pace(pace)}/km | {dist/1000:.1f}km | HR {avg_hr}")
                else:
                    lines.append(f"  {dt}: no distance data | HR {avg_hr}")

    elif any(kw in q for kw in ["volume", "mileage", "km", "distance", "week"]):
        week_km = get_run_volume_km(runs, 7)
        month_km = get_run_volume_km(runs, 28)
        lines.append(f"*Running Volume*")
        lines.append(f"  This week: {week_km:.1f} km")
        lines.append(f"  4-week total: {month_km:.1f} km ({month_km/4:.1f} km/wk avg)")
        run_count = len(runs)
        lines.append(f"  Total runs in data: {run_count}")

    elif any(kw in q for kw in ["injury", "pain", "hurt", "sore"]):
        lines.append(f"*Injury Risk Assessment*")
        agg_zones = aggregate_run_zones(runs, 14)
        pcts = zone_pcts(agg_zones)
        high_pct = pcts["z4"] + pcts["z5"]
        debt = compute_sleep_debt(sleeps, 7)
        risk_factors = 0
        if high_pct > 40:
            lines.append(f"  🚨 Zone imbalance: {high_pct:.0f}% Z4-Z5 → elevated overuse risk")
            risk_factors += 1
        if debt > 7200000:
            lines.append(f"  🚨 Sleep debt {ms_to_hm(debt)} → impaired tissue repair")
            risk_factors += 1
        if recs and recs[0].get("score", {}).get("recovery_score", 0) < 40:
            lines.append(f"  🚨 Current recovery very low ({recs[0].get('score', {}).get('recovery_score', 0):.0f})")
            risk_factors += 1
        if risk_factors == 0:
            lines.append(f"  ✅ No major risk factors detected. Keep training smart.")

    else:
        # General summary
        lines.append(f"*Quick Summary*")
        if recs:
            s = recs[0].get("score", {})
            lines.append(f"  Recovery: {s.get('recovery_score', 0):.0f} | HRV: {s.get('hrv_rmssd_milli', 0):.0f}ms")
        _cutoff = datetime.now(timezone.utc) - timedelta(days=7)
        _runs_this_week = 0
        for _r in runs:
            try:
                if datetime.fromisoformat(_r["start"].replace("Z", "+00:00")) >= _cutoff:
                    _runs_this_week += 1
            except Exception:
                pass
        lines.append(f"  Runs this week: {_runs_this_week}")
        week_km = get_run_volume_km(runs, 7)
        lines.append(f"  Volume: {week_km:.1f} km")
        lines.append(f"\n  Try asking about: zones, recovery, sleep, pace, volume, injury risk")

    print("\n".join(lines))


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    if len(sys.argv) < 2:
        print("Usage: run_coach.py <brief|post-run|digest|q <question>>")
        return

    cmd = sys.argv[1].lower()

    if cmd == "brief":
        cmd_brief()
    elif cmd == "post-run":
        cmd_post_run()
    elif cmd == "digest":
        cmd_digest()
    elif cmd == "q" and len(sys.argv) > 2:
        cmd_question(" ".join(sys.argv[2:]))
    elif cmd == "q":
        print("Usage: run_coach.py q <your question>")
    else:
        print(f"Unknown command: {cmd}")
        print("Commands: brief | post-run | digest | q <question>")

if __name__ == "__main__":
    main()
