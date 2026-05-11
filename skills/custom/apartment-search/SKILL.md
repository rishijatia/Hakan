---
name: apartment-search
description: >
  Search NYC apartment listings using NYBits (no-bot-detection). Works from
  headless servers where StreetEasy/Zillow/Apartments.com block with captchas.
  Supports filtering by neighborhood, bedrooms, price, fee status, and amenities.
  Use this skill whenever the user asks to find, search, or browse apartments in NYC.
triggers:
  - apartment
  - rental
  - 2br
  - 1br
  - for rent
  - find apartment
  - search apartment
  - listing
---

# Apartment Search Skill

## Problem
Major NYC real estate sites (StreetEasy, Zillow, Apartments.com, RentHop) all use
aggressive bot detection (Cloudflare, captchas, "Press & Hold") that blocks headless
browsers on cloud servers. Google Search also blocks from datacenter IPs.

## Solution: NYBits.com
NYBits is a smaller NYC rental aggregator that does NOT use bot detection. It works
with both `curl` and headless Chrome from cloud servers.

## How NYBits Search Works

NYBits uses a server-side HTML form (not AJAX). URL query params alone DON'T work —
the form requires hidden session tokens (`_rid_`, `_ust_todo_`, `_xid_`).

### Step 1: Load the search page
Navigate browser to: `https://www.nybits.com/search/`

### Step 2: Fill form via JavaScript
Use `browser_console` to set form values and submit:

```javascript
(() => {
    const f = document.forms['sform'];
    // Uncheck "all", check desired layout
    document.getElementById('sball').checked = false;
    document.getElementById('sb2').checked = true;  // sb0=studio, sb1=1br, sb2=2br, sb3=3+
    // Set max rent
    f.elements['!!rmax'].value = '6000';
    // Set fee: 'nofee' or 'any'
    f.querySelector('input[name="!!fee"][value="any"]').checked = true;
    // Check neighborhoods
    f.querySelectorAll('input[name="nei"]').forEach(cb => {
        if (cb.value === 'downtown_brooklyn' || cb.value === 'long_island_city') cb.checked = true;
    });
    f.querySelector('input[type="submit"]').click();
    return 'submitted';
})()
```

### Step 3: Extract results via JavaScript
After the results page loads:

```javascript
(() => {
    const arts = document.querySelectorAll('article');
    const listings = [];
    arts.forEach(a => {
        const title = a.querySelector('h3')?.textContent?.trim() || '';
        const price = a.textContent.match(/\$[\d,]+\/month/)?.[0] || '';
        const beds = a.textContent.match(/(\d+)\s*Beds?/)?.[1] || '';
        const baths = a.textContent.match(/([\d.]+)\s*Baths?/)?.[1] || '';
        const link = a.querySelector('a')?.href || '';
        listings.push({ title, price, beds, baths, link });
    });
    return JSON.stringify(listings);
})()
```

### Step 4: Check individual listings for amenities
Navigate to each listing URL. The description paragraph reveals in-unit W/D and
other details not shown in search results. Use curl for speed:

```bash
curl -sL -A "Mozilla/5.0" "<listing_url>" | grep -oP 'listing__text[^>]*>\K[^<]+'
```

## Available Neighborhoods (NYBits `nei` values)

**Brooklyn:** `downtown_brooklyn`, `brooklyn_heights`, `dumbo`, `bushwick`,
`flatbush`, `greenpoint`, `park_slope`, `williamsburg`

**Queens:** `long_island_city`, `astoria`, `rego_park`, `ridgewood`

**Manhattan:** `alphabet_city`, `battery_park_city`, `chelsea`, `east_village`,
`financial_district`, `gramercy_park`, `hells_kitchen`, `hudson_yards`,
`kips_bay`, `midtown_east`, `murray_hill`, `soho`, `tribeca`, `upper_east_side`,
`upper_west_side`, `west_village`, `stuy_town`, and many more.

## Form Fields Reference

| Field | Name | Values |
|-------|------|--------|
| Layout | `!!atypes` | `studio`, `1br`, `2br`, `3more`, `room` |
| Min rent | `!!rmin` | number |
| Max rent | `!!rmax` | number |
| Fee status | `!!fee` | `nofee`, `any` |
| Sort order | `!!orderby` | `dateposted`, `neighborhood`, `rent` |
| Neighborhoods | `nei` | see list above (repeatable) |
| Amenities | checkbox names | `doorman`, `elevator`, `gym`, `garage`, `children` |

## Pitfalls

1. **URL params don't work** — the form requires session tokens; must use browser JS
2. **Checkbox `all` must be unchecked first** — otherwise all layouts are returned
3. **Variable redeclaration errors** — browser_console runs in shared scope; wrap code
   in IIFE `(() => { ... })()` or use `var` instead of `const`/`let` if re-running
4. **NYBits has limited inventory** — may have 0 results for some neighborhoods;
   try expanding to adjacent areas
5. **In-unit W/D not in search filters** — must check individual listing descriptions
6. **`submit` button naming conflict** — NYBits names its submit button `submit`,
   which shadows `form.submit()`. Use `btn.click()` instead.

## Multi-Source Strategy (Future)

If more inventory is needed, try these additional sources that may work:
- **ListingsProject.com** — returned HTTP 200 from curl, may have listings
- **NakedApartments.com** — no-fee focused
- **The Listings Project** (newsletter) — weekly curated no-fee listings

Major sites requiring stealth mode (BROWSERBASE_ADVANCED_STEALTH):
- StreetEasy, Zillow, Apartments.com, RentHop — all blocked from datacenter IPs
