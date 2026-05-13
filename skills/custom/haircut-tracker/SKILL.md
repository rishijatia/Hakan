---
name: haircut-tracker
description: "Track haircuts with before/after photos, barber details, style notes, and ratings. Logs to /opt/data/haircuts/."
version: 1.0.0
author: Hermes Agent
metadata:
  hermes:
    tags: [photos, tracking, haircuts, personal, grooming]
---

# Haircut Tracker

Track haircuts with before/after photos, barber details, style notes, and ratings.

## Directory Structure

```
/opt/data/haircuts/
├── photos/           # All photos organized by date
│   ├── 20260511-01_before.jpg
│   └── 20260511-01_after.jpg
└── log.json          # Structured haircut log (source of truth)
```

## Photo Naming Convention

Format: `YYYYMMDD-NN_[before|after].jpg`

- `YYYYMMDD` — date of haircut
- `NN` — sequence number (01, 02 if multiple haircuts same day)
- `before` or `after` — timing relative to haircut

## Log Format (log.json)

Schema version 1. Each entry:
```json
{
  "id": "YYYYMMDD-NN",
  "date": "YYYY-MM-DD",
  "created_at": "ISO timestamp",
  "updated_at": "ISO timestamp",
  "barber": "Name/Shop or null",
  "style": "Description or null",
  "tags": [],
  "cost": null,
  "notes": "Free text",
  "photos": [
    {"kind": "before", "path": "photos/YYYYMMDD-NN_before.jpg"},
    {"kind": "after", "path": "photos/YYYYMMDD-NN_after.jpg"}
  ],
  "rating": null
}
```

## Workflow

### Before Photo (User Sends Pre-Haircut Photo)

1. Save photo to `/opt/data/haircuts/photos/YYYYMMDD-NN_before.jpg`
2. Use `vision_analyze` to describe the current haircut
3. Create entry in `log.json` with:
   - Date, before photo path
   - "Before" description in notes
   - Barber/shop (if known)
   - Requested style (if mentioned)

### After Photo (User Sends Post-Haircut Photo)

1. Save photo to `/opt/data/haircuts/photos/YYYYMMDD-NN_after.jpg`
2. Use `vision_analyze` to describe the new haircut
3. Ask user for:
   - Barber/shop name
   - Style requested
   - Cost
   - Rating (1-10)
   - Notes (would go back? beard trimmed? any issues?)
4. Update `log.json` entry with after photo, details, and rating

## Key Rules

- **Always use vision_analyze** to describe photos — don't just save them
- **Ask for rating** after the haircut (1-10 scale)
- **Track barber loyalty** — note which barbers produce good results
- **Compare before/after** — call out what changed
- Photos are private — don't share without explicit ask
- **Never push haircut data to GitHub** — personal photos/logs stay local only

## Pitfalls

- `vision_analyze` is a gateway-side tool — use `delegate_task` with `toolsets: ["vision"]` to call it from the agent
- **Credential pool exhaustion:** If vision gets a 401, the pool marks the key as exhausted. Fix: `hermes auth reset openrouter` + restart gateway.
- **Never embed API keys in config.yaml** — use `.env` or Fly secrets. `auxiliary.vision.api_key` must stay `''`.
- **Beard tracking:** Ask explicitly if beard was trimmed — vision analysis may assume grooming happened when it didn't
- **User corrections mid-flow:** If user corrects barber name, location, or other details, update the log immediately
- Photo naming must be consistent for the log to link correctly
- If user sends multiple before photos, use sequence numbering (01, 02)
