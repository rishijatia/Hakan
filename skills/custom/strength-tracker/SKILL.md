---
name: strength-tracker
description: "Track strength training sessions via WHOOP screenshots or text backfill. SQLite database, analytics CLI, web dashboard, PR tracking, progressive overload suggestions, weekly summaries."
triggers:
  - "strength"
  - "lifting"
  - "gym"
  - "workout log"
  - "exercise"
  - "WHOOP workout"
  - "PRs"
  - "progression"
---

# Strength Training Tracker

## When to Use
- User sends a WHOOP workout screenshot (EXERCISE SUMMARY screen)
- User pastes workout text from WHOOP in-app AI assistant
- User asks about their lifting history, PRs, or progress
- Weekly summary cron runs (Sundays 7pm ET)

## Input Paths

### Path 1: WHOOP Screenshot
User sends screenshot → vision parses exercise data (exercises, sets, reps, weight, avg HR per set).
Screenshots include HR per set but NOT workout names.

### Path 2: WHOOP In-App AI Text
User asks WHOOP's AI assistant for "all Strength Trainer sessions" → gets structured text:
```
DATE: 2026-05-06
WORKOUT: Legs & Arms
EXERCISE: Goblet Squat – Dumbbell
Set 1: 40 lb x 10
Set 2: 45 lb x 10
```
Text includes workout names but NOT HR per set. Parse with regex, not vision.

### Path 3: Manual Entry
User types something like "bench 3x5@185" → parse and log.

**Dual input paths:** Screenshots give HR per set but no workout name. Backfill text gives workout name but no HR. Both are valuable; don't discard either.

## Architecture

```
/opt/data/strength-training/
├── strength.db              # SQLite (primary data store)
├── dashboard.py             # Web dashboard (port 8080)
├── *.json                   # Legacy daily logs (migrated to DB)
/opt/data/scripts/
├── strength_logger.py       # Deterministic logging module (USE THIS)
├── strength_analytics.py    # Analytics CLI
├── test_strength_logger.py  # Test suite (51 tests)
```

### Logging Module (strength_logger.py)

**USE THIS, NOT raw SQL.** All session logging goes through `strength_logger.py` for determinism.

```python
from strength_logger import log_session, parse_whoop_text, backfill_whoop_text, get_session, get_prs

# Log a single session
result = log_session(
    date="2026-05-13",
    exercises=[{
        "name": "Bench Press",
        "variation": "Barbell",
        "sets": [
            {"reps": 10, "weight_lbs": 135, "avg_hr_bpm": 120},
            {"reps": 8, "weight_lbs": 155},
        ],
    }],
    source="whoop_screenshot",
    workout_name="Chest Day",
)
# Returns: {session_id, total_reps, total_tonnage, exercises_count, prs_hit, whoop, errors}

# Parse WHOOP text backfill
sessions = parse_whoop_text(raw_text)
# Returns: [{"date", "workout_name", "exercises": [{name, variation, sets}]}, ...]

# Backfill all sessions from text
results = backfill_whoop_text(raw_text)

# Query
session = get_session("2026-05-13")
prs = get_prs()
```

### Exercise Name Parsing

`_parse_exercise_name()` handles all WHOOP formats:
## Architecture

```
/opt/data/strength-training/
├── strength.db              # SQLite (primary data store)
├── dashboard.py             # Web dashboard (port 8080)
├── *.json                   # Legacy daily logs (migrated to DB)
/opt/data/scripts/
├── strength_logger.py       # Deterministic logging module (USE THIS)
├── strength_analytics.py    # Analytics CLI
├── test_strength_logger.py  # Test suite (51 tests, all passing)
```

### Logging Module (strength_logger.py)

**USE THIS INSTEAD OF RAW SQL.** Handles parsing, DB insert, PR detection, and WHOOP correlation deterministically.

```python
from strength_logger import log_session, parse_whoop_text, backfill_whoop_text, get_session, get_prs

# Log a single session
result = log_session(
    date="2026-05-13",
    exercises=[{
        "name": "Bench Press",
        "variation": "Barbell",
        "sets": [
            {"reps": 10, "weight_lbs": 135, "avg_hr_bpm": 120},
            {"reps": 8, "weight_lbs": 155},
        ],
    }],
    source="whoop_screenshot",
    workout_name="Chest Day",
)
# result = {session_id, total_reps, total_tonnage, exercises_count, prs_hit, whoop, errors}

# Parse and log WHOOP text backfill
sessions = parse_whoop_text(raw_text)  # returns list of {date, workout_name, exercises}
results = backfill_whoop_text(raw_text)  # parses + logs all sessions

# Query
session = get_session("2026-05-13")  # full session with exercises + sets
prs = get_prs()  # all PRs grouped by exercise
```

### Database Schema (SQLite)

```sql
sessions:  id, date, workout_name, source, total_reps, total_tonnage_lbs,
           duration_minutes, avg_strain, calories, whoop_avg_hr, whoop_max_hr, notes
exercises: id, session_id, name, variation, total_reps, tonnage_lbs
sets:      id, exercise_id, set_number, reps, weight_lbs, avg_hr_bpm, duration_sec, set_type
prs:       exercise_name, pr_type, value, unit, reps, date
```

### Web Dashboard
`/opt/data/strength-training/dashboard.py` — single-file Python http.server dashboard on port 8080.
Pages: Overview (weekly volume chart), Exercises (table), PRs, Progression (per-exercise line charts), Muscle Groups (pie chart), Suggestions (progressive overload).

To start: `cd /opt/data/strength-training && python3 dashboard.py &`
To access progression for a specific exercise: `http://localhost:8080/progression?exercise=Goblet+Squat`

## Analytics CLI

```bash
python3 /opt/data/scripts/strength_analytics.py <command>
```

| Command | Description |
|---------|-------------|
| `summary` | Overall stats, weekly volume trend |
| `prs` | All personal records |
| `progression <exercise>` | Weight progression over time |
| `volume` | Volume trend by session |
| `muscle_groups` | Volume by muscle group |
| `exercise <name>` | Full history for an exercise |
| `suggest` | Progressive overload suggestions |
| `json` | Full analytics as JSON (for programmatic use) |

### Schema Extensions (WHOOP Session Data)

The `sessions` table includes WHOOP workout-level columns that are auto-populated by `log_session()`:

```sql
calories REAL        -- kcal (converted from kilojoules)
whoop_avg_hr INTEGER -- bpm
whoop_max_hr INTEGER -- bpm
```

These come from the WHOOP REST API (`/v2/activity/workout`), NOT from the screenshot. The API returns session-level strain, calories, and HR — but NOT exercise-level detail. Screenshots + API data are complementary.

### WHOOP Auto-Correlation

`log_session()` automatically calls `correlate_whoop_data(date)` after inserting. It reads `/opt/data/whoop/daily_profile_raw.json` and matches by date + sport type (`weightlifting_msk` or `strength`).

**WHOOP data lags ~24 hours.** Today's workout won't appear until tomorrow. The daily cron (9:15am ET) fetches fresh data.

## Logging a New Session

### From WHOOP Screenshot (may be multiple)
User may send 2-3 screenshots if the workout has many exercises (WHOOP shows ~3 per screen). 
1. Use `vision_analyze` on EACH screenshot to extract exercises
2. Accumulate ALL exercises from all screenshots before inserting
3. Deduplicate by exercise name — if the same exercise appears in two screenshots, it's the same data (user scrolled)
4. Verify total reps and tonnage match the summary shown in the screenshot header (e.g. "143 reps, 8900 lbs")
5. Call `log_session()` from `strength_logger.py` — do NOT use raw SQL
6. Auto-correlate WHOOP session data (log_session does this automatically)
7. Confirm to user: exercises logged, total volume, any PRs, WHOOP strain/calories if available

### From WHOOP Text Backfill
1. Call `backfill_whoop_text(raw_text)` from `strength_logger.py`
2. Report results to user (sessions logged, PRs, WHOOP correlation)

| Trigger | Action |
|---------|--------|
| Send WHOOP screenshot | Parse + log to DB + confirm + check PRs |
| Paste WHOOP text | Parse + log to DB + confirm + check PRs |
| "What are my PRs?" | `python3 strength_analytics.py prs` |
| "What should I do next?" | `python3 strength_analytics.py suggest` |
| "Strength summary" | `python3 strength_analytics.py summary` |
| "Progression [exercise]" | `python3 strength_analytics.py progression <name>` |
| "Muscle groups" | `python3 strength_analytics.py muscle_groups` |
| "Dashboard" | Start dashboard, give URL |

## Progressive Overload Logic

When user asks what to do next:
- If last session was 3×10 @ 40lbs → suggest 3×10 @ 45lbs OR 3×12 @ 40lbs
- If stuck at same weight for 3+ sessions → suggest volume increase (add a set)
- Track deload weeks (volume drop >20%) and flag if none in 4+ weeks
- Use `suggest` command for data-driven recommendations

## Pitfalls
- **Always use `strength_logger.py`** — never write raw SQL for logging. The module handles PR detection, WHOOP correlation, duplicate dates, and data validation deterministically.
- **Run tests after changes:** `python3 /opt/data/scripts/test_strength_logger.py` — 51 tests covering all edge cases.
- **Scrollable screenshots:** WHOOP screenshots may have more exercises below the fold. If only 2-3 exercises visible, ask user to scroll and send another screenshot.inistically.
- **Run tests after changes:** `python3 /opt/data/scripts/test_strength_logger.py` — 51 tests covering all edge cases.
- **Scrollable screenshots:** WHOOP screenshots may have more exercises below the fold. If only 2-3 exercises visible, ask user to scroll and send another screenshot.
- **Weight units:** WHOOP uses lbs by default. If user switches to kg, note in memory.
- **Exercise name variations:** "Bicep Curl - Barbell" vs "Bicep Curl - Dumbbell" vs "Bicep Curl (dumbbell, strict)" — normalize for PR matching but preserve original name.
- **Bodyweight exercises:** weight = 0, track reps only. Dips, push-ups, planks.
- **Timed exercises:** Planks/deadbugs return "bodyweight x 30 s" — parse the `s` suffix as `duration_sec`, exclude from tonnage.
- **Same-day sessions:** WHOOP may log two sessions on same date. Use `-session2` suffix on filename to avoid overwriting.
- **Workout names:** WHOOP backfill includes workout names (e.g. "Nemo Back Leg Arms"). Capture in `workout_name` field — useful for tracking program splits.
- **Dashboard is ephemeral:** Runs as background process, dies on gateway restart. User needs to ask to start it again.
- **WHOOP data lag:** Session-level WHOOP data (strain, calories) lags ~24 hours. When logging today's session, note that WHOOP metrics will be available tomorrow. The daily cron (9:15am ET) fetches fresh data — use it to backfill yesterday's session.
- **WHOOP calories conversion:** API returns `kilojoule` — divide by 4.184 to get kcal. Round to nearest integer.
- **Multiple screenshots:** User may send multiple screenshots for one session (scrolled view). Accumulate all exercises before inserting — don't create duplicate sessions.
