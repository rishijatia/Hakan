---
name: haircut-log
version: 0.1.0
description: "Log haircuts with before/after photos, dates, barber, style notes. Track haircut history over time."
triggers:
  - haircut
  - barber
  - hair style
  - before after
  - haircut log
  - haircut history
metadata:
  hermes:
    tags: [lifestyle, photos, personal, grooming]
    related_skills: []
---

# Haircut Log

Track haircuts with photos, dates, barber details, style notes, and optional ratings.

## Storage

- **Log file:** `/opt/data/haircuts/log.json` — structured JSON with `schema_version` and `entries` array
- **Photos:** `/opt/data/haircuts/photos/` — named `{id}_{kind}.{ext}` (e.g., `20260511-01_before.jpg`)

## Schema (v1)

```json
{
  "schema_version": 1,
  "entries": [
    {
      "id": "20260511-01",
      "date": "2026-05-11",
      "created_at": "2026-05-11T10:30:00Z",
      "updated_at": "2026-05-11T18:00:00Z",
      "barber": "Name or shop",
      "style": "Description of cut",
      "tags": ["fade", "short"],
      "cost": null,
      "notes": "Any extra notes",
      "photos": [
        {"kind": "before", "path": "photos/20260511-01_before.jpg"},
        {"kind": "after", "path": "photos/20260511-01_after.jpg"}
      ],
      "rating": null
    }
  ]
}
```

### Fields
- `id` — `YYYYMMDD-NN` (date + sequence number for same-day duplicates). Required.
- `date` — Haircut date, `YYYY-MM-DD`. Required.
- `created_at` — ISO 8601 timestamp when entry was created. Required.
- `updated_at` — ISO 8601 timestamp of last modification. Updated on rating, photo additions, etc.
- `barber` — Name of barber or shop. Optional.
- `style` — Description of the haircut/style requested. Optional.
- `tags` — Array of searchable tags: `["fade", "beard-trim", "short", "long"]`. Optional.
- `cost` — Price in dollars (number). Optional.
- `notes` — Freeform notes. Optional.
- `photos` — Array of `{kind, path}` objects. `kind` is `"before"`, `"after"`, `"mid"`, or `"other"`. Optional.
- `rating` — 1-5 rating, can be added later. Optional (stored as `null` until rated).

## Usage

### Logging a New Haircut

When user mentions getting a haircut or sends a haircut photo:

1. **Photo processing with vision model:**
   - Use `vision_analyze(image_url=..., question="Describe this photo — is it a before or after haircut photo? Describe the haircut/style.")` to process the image
   - `vision_analyze` auto-falls back to a vision-capable model when the current model doesn't support vision
   - This lets you "see" the photo even on non-vision models
2. **Save the photo** to `/opt/data/haircuts/photos/{id}_{kind}.{ext}`
   - If the image is a URL, download it: `curl -o /opt/data/haircuts/photos/{id}_{kind}.{ext} "<url>"`
   - If the image is a local file path, copy it: `cp <path> /opt/data/haircuts/photos/{id}_{kind}.{ext}`
3. **Create entry** with today's date and a new `id` (check existing entries for same-day collisions — increment `NN`)
4. **Ask minimally** — if user just sends a photo, log it. Don't interrogate about barber/style/notes unless they volunteer.

### Adding a Photo Later

If user sends another photo for the same day:
- Process with `vision_analyze` to identify if it's before/after/mid/other
- Find existing entry for today (or most recent entry if sent same day)
- Add photo to the entry's `photos` array with appropriate `kind`
- Update `updated_at`

### Rating Later

When user says "rate my last haircut" or "4 out of 5":
- Find the most recent entry with `rating: null` (or the one they're referring to)
- Set `rating`, update `updated_at`

### Updating an Entry

If user corrects barber, style, or notes:
- Find entry by date or "last one"
- Update the field(s), set `updated_at`

### Queries

- **"Show last haircut"** → Read last entry, use `vision_analyze` to show/describe the photo
- **"How often do I get haircuts?"** → Compute average days between entries
- **"Show all by Tony"** → Filter entries by barber field
- **"Show all fades"** → Filter by tags containing "fade"

## Atomic Write Rule

**Always** write atomically to prevent corruption:
```python
import json, os, tempfile
fd, tmp = tempfile.mkstemp(dir="/opt/data/haircuts", suffix=".tmp")
try:
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
    os.replace(tmp, "/opt/data/haircuts/log.json")
except:
    os.unlink(tmp)
    raise
```

## Backup Rule

Before writing, copy `log.json` to `log.json.bak` if it exists.

## Setup

Create directories on first use:
```bash
mkdir -p /opt/data/haircuts/photos
```

If `log.json` doesn't exist, create it as `{"schema_version": 1, "entries": []}`.

### Vision Setup (required for photo analysis)

`vision_analyze` needs an explicitly configured vision provider. `provider: auto` silently fails. Edit `/opt/data/config.yaml`:

```yaml
auxiliary:
  vision:
    provider: openrouter
    model: google/gemini-2.0-flash-001
    base_url: https://openrouter.ai/api/v1
    api_key: ''       # empty = uses main provider's key
    timeout: 120
```

After editing, **restart the gateway** for changes to take effect:
```bash
fly apps restart hermes-agent
```

The config change must also be synced to GitHub (`flyio/config.yaml` in the Hakan repo). See [references/vision-setup.md](references/vision-setup.md) for alternatives and troubleshooting.

## Pitfalls

1. **EXIF leaks location** — Always strip EXIF from photos before saving. Telegram re-encodes photos (usually strips EXIF), but direct file uploads may retain it. If Pillow is available: `python3 -c "from PIL import Image; Image.open(f).save(f, exif=b'')"`. If not, note it as a known limitation.

2. **Vision model for photos** — `vision_analyze` requires a vision provider **explicitly** configured in `config.yaml`. The `provider: auto` setting silently fails even when API keys are present. You must set all three: `provider`, `model`, and `base_url`. See [references/vision-setup.md](references/vision-setup.md) for the exact config. Without this, photos can still be saved but cannot be analyzed/described.
3. **Same-day collisions** — Use `YYYYMMDD-NN` IDs so two haircuts on the same day don't overwrite each other.
3. **Photo extension varies** — Telegram sends WEBP, iPhone sends HEIC, screenshots are PNG. Don't hardcode `.jpg`; use the actual extension.
4. **Atomic writes** — Never write directly to `log.json`. Always write to a temp file then `os.replace()`.
5. **Don't ask too many questions** — If user sends a photo, log it. Barber/style/notes are optional; rating can come later.
6. **Date is haircut date, not log date** — If user backfills ("I got a haircut last Tuesday"), use last Tuesday's date.
7. **Backup before write** — Copy to `log.json.bak` before any modification.
8. **Timezone** — Use the user's timezone for "today" determination. Rishi is in ET (America/New_York).
