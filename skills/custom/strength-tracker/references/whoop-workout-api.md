# WHOOP Workout API Data Format

## Endpoint
GET /v2/activity/workout?limit=7

## Response Structure (score object)
```json
{
  "sport_name": "weightlifting_msk",
  "start": "2026-05-09T22:52:00.000Z",
  "score": {
    "strain": 7.6344485,
    "average_heart_rate": 118,
    "max_heart_rate": 138,
    "kilojoule": 494.12,
    "duration": 0
  }
}
```

## Sport Types for Strength
- weightlifting_msk — strength training
- strength — also used sometimes

## Field Notes
- duration is sometimes 0 (WHOOP bug) — compute from start/end
- kilojoule to kcal: divide by 4.184
- strain is 0-21 scale
- average_heart_rate can be 0/None
- Timestamps are UTC — convert to ET for date matching
- Data lags ~24 hours
