# WHOOP Fitness Tracker — System Design

## Overview
A personal fitness tracking system that syncs WHOOP data, logs exercises, and provides analysis via Telegram. Designed for single-user deployment on Fly.io with SQLite storage.

## Architecture Decisions

### Why SQLite?
- Single user, ~10K rows/year — trivial for SQLite
- No external dependencies (no Postgres/MySQL needed)
- Lives on persistent Fly.io volume (`/opt/data/whoop/whoop.db`)
- Supports JSON fields for flexible data (planned workout templates)

### Why Python over Shell Scripts?
- JSON parsing, error handling, SQLite interaction are painful in bash
- `requests` + `sqlite3` in Python is cleaner and more maintainable
- Single `whoop.py` CLI tool with subcommands (sync, refresh, query, log)

### Token Management Strategy
1. **Initial auth**: User clicks OAuth link → callback → atomic shell exchange (token never hits LLM due to redaction)
2. **Storage**: SQLite `tokens` table (not .env — avoids redaction issues)
3. **Refresh**: On-demand before API calls (check `expires_at`, refresh if <5 min left)
4. **Fallback cron**: Every 45 min as backup
5. **Alerting**: Telegram message if refresh fails → user must re-authorize

## Database Schema

```sql
-- Token storage
CREATE TABLE tokens (
    id INTEGER PRIMARY KEY,
    access_token TEXT NOT NULL,
    refresh_token TEXT,
    expires_at TEXT NOT NULL,
    updated_at TEXT DEFAULT (datetime('now'))
);

-- WHOOP workout data (synced from API)
CREATE TABLE workouts (
    whoop_id TEXT PRIMARY KEY,
    sport_name TEXT,
    sport_id INTEGER,
    start_time TEXT,
    end_time TEXT,
    duration_minutes REAL,
    strain REAL,
    avg_heart_rate INTEGER,
    max_heart_rate INTEGER,
    calories_kj REAL,
    distance_meters REAL,
    synced_at TEXT DEFAULT (datetime('now'))
);

-- Exercise detail (user-provided, API doesn't have this)
CREATE TABLE exercises (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    workout_id TEXT REFERENCES workouts(whoop_id),
    exercise_name TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now'))
);

-- Per-set tracking (critical for progression analysis)
CREATE TABLE exercise_sets (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    exercise_id INTEGER REFERENCES exercises(id),
    set_number INTEGER NOT NULL,
    reps INTEGER,
    weight_kg REAL,
    rpe REAL,
    notes TEXT
);

-- Exercise name aliases for fuzzy matching
CREATE TABLE exercise_aliases (
    alias TEXT PRIMARY KEY,
    canonical_name TEXT NOT NULL
);

-- WHOOP sleep data
CREATE TABLE sleep (
    whoop_id TEXT PRIMARY KEY,
    cycle_id INTEGER,
    start_time TEXT,
    end_time TEXT,
    is_nap BOOLEAN DEFAULT FALSE,
    total_in_bed_ms INTEGER,
    total_awake_ms INTEGER,
    total_light_ms INTEGER,
    total_sws_ms INTEGER,
    total_rem_ms INTEGER,
    sleep_cycles INTEGER,
    disturbances INTEGER,
    respiratory_rate REAL,
    sleep_performance_pct REAL,
    sleep_consistency_pct REAL,
    sleep_efficiency_pct REAL,
    synced_at TEXT DEFAULT (datetime('now'))
);

-- WHOOP recovery data
CREATE TABLE recovery (
    whoop_id TEXT PRIMARY KEY,
    cycle_id INTEGER,
    sleep_id TEXT,
    created_at TEXT,
    recovery_score REAL,
    resting_heart_rate REAL,
    hrv_rmssd_ms REAL,
    spo2_pct REAL,
    skin_temp_celsius REAL,
    synced_at TEXT DEFAULT (datetime('now'))
);

-- Planned workouts
CREATE TABLE planned_workouts (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    planned_date TEXT NOT NULL,
    workout_type TEXT,
    exercises JSON,
    status TEXT DEFAULT 'planned',
    actual_workout_id TEXT REFERENCES workouts(whoop_id),
    notes TEXT,
    created_at TEXT DEFAULT (datetime('now'))
);

-- Body measurements (time-series)
CREATE TABLE body_measurements (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    date TEXT NOT NULL,
    weight_kg REAL,
    body_fat_pct REAL,
    notes TEXT,
    source TEXT DEFAULT 'manual'
);

-- Schema versioning
CREATE TABLE schema_version (
    version INTEGER PRIMARY KEY,
    applied_at TEXT DEFAULT (datetime('now'))
);
```

## Sync Flow

```
Daily cron or manual trigger:
1. Read access_token from SQLite
2. If expired → refresh (if refresh_token available) or alert user
3. Fetch: workouts, sleep, recovery, cycles (paginated)
4. For each record: INSERT ... ON CONFLICT (whoop_id) DO UPDATE
5. Validate data ranges (recovery 0-100, HR 30-250)
6. Send Telegram summary

Error handling:
- Each endpoint fetch is independent (one failure doesn't kill sync)
- Retry with exponential backoff on 429/5xx
- Track last_synced_at per endpoint for resume
- Alert user on persistent failures
```

## Design Review Findings (Principal Engineer)

### Critical
1. **Error handling**: Each endpoint fetch must be independent with retry logic
2. **Token refresh**: On-demand (not just cron) — check before each API call
3. **Data validation**: Validate ranges on insert, use ON CONFLICT DO UPDATE for WHOOP backfills

### Major
4. **Exercise schema**: Per-set tracking (exercise_sets table) is required for progression analysis
5. **Weight units**: Store in kg only, convert on display
6. **Schema versioning**: Use schema_version table for migrations
7. **First sync**: Fetch ALL available data (not just 30 days) for long-term trends

### Missing Features (consider for v2)
- Streaks/habit tracking
- Goal setting (target weight, workout frequency)
- DB backup strategy (daily dump)
- WHOOP webhooks for real-time workout detection
- Weekly/monthly rollup summaries
- Correlation analysis framework (sleep vs performance)
