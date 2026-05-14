# Backfilling Historical Strength Data from WHOOP

## Key Discovery
WHOOP's **in-app AI assistant** (Beta) can return exercise-level detail (sets, reps, weight) that the REST API does NOT expose. The API only gives session-level data (strain, HR, duration, sport_name). Use the in-app AI for historical exercise data.

## Prompt for WHOOP In-App AI

Give this to the WHOOP agent in the app:

```
Get me ALL my strength training workouts from the last 6 months (start date to today). Include every exercise, every set. Format each workout like this:

DATE: YYYY-MM-DD
WORKOUT: [workout name if available]
EXERCISE: [exercise name] ([variation])
Set N: [weight] lb x [reps]

Group by date, oldest first. Include ALL exercises per session, not just one. Don't skip any sessions.

Example format:
DATE: 2026-03-24
WORKOUT: Gym Chest & Arms
EXERCISE: Bench Press (machine)
Set 1: 25 lb x 12
Set 2: 25 lb x 12
Set 3: 30 lb x 10

EXERCISE: Shoulder Press (dumbbell)
Set 1: 20 lb x 10
Set 2: 20 lb x 10

DATE: 2026-04-02
EXERCISE: Bench Press (dumbbell)
Set 1: 25 lb x 10
...

Save to a note or copy the full output so I can import it.
```

## Parsing the Output

The output is plain text. Parse with regex:
- `DATE:\s*(\d{4}-\d{2}-\d{2})` → session date
- `WORKOUT:\s*(.+)` → workout name (optional, may not always appear)
- `EXERCISE:\s*(.+)` → exercise name (includes variation in parens)
- `Set\s+\d+:\s*(\d+|bodyweight)\s*lb?\s*x\s*(\d+)\s*(s)?` → weight, reps, optional time suffix
- "bodyweight" → weight = 0
- "x 30 s" → timed exercise (plank, deadbug), store as `duration_sec: 30`, exclude from tonnage

## What WHOOP In-App AI Returns
- Exercise name with variation (e.g. "Goblet Squat (dumbbell)", "Bench Press (barbell)")
- Each set with weight in lbs and reps
- Workout name when available (e.g. "Nemo Back Leg Arms", "Full Body with Aman")
- Timed exercises: "bodyweight x 30 s" format for planks, deadbugs
- Does NOT include: HR per set, strain, duration, calories
- May return multiple sessions on the same date (different workouts)
- May be scrollable/paginated — user may need to ask for more

## What the REST API Returns (for correlation)
- `sport_name`: "weightlifting_msk", "running", "stairmaster", "activity"
- `score.strain`, `score.average_heart_rate`, `score.max_heart_rate`
- `score.kilojoule` (calories)
- Duration from start/end timestamps
- Use `whoop_query.py <days>` to fetch

## Workflow
1. User asks WHOOP in-app AI for historical data
2. User pastes text output to Hermes on Telegram
3. Hermes parses with regex → saves to `/opt/data/strength-training/YYYY-MM-DD.json`
4. Updates `/opt/data/strength-training/prs.json`
5. Correlates with WHOOP API data for strain/HR context if available

## Edge Cases
- **Same-day sessions**: Append `-session2` suffix to filename (e.g. `2026-04-21-session2.json`)
- **Workout name missing**: Some sessions won't have WORKOUT line — set `workout_name: null`
- **Partial exercises visible**: If output cuts off, ask user to request remaining sessions
- **Exercise name variations**: "Bicep Curl – Dumbbell" vs "Bicep Curl (dumbbell)" — normalize to consistent format
