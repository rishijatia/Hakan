#!/usr/bin/env python3
"""WHOOP Q&A data fetcher. Fetches fresh data and outputs JSON for analysis."""

import json
import sys
import time
from datetime import datetime, timezone, timedelta
from pathlib import Path

TOKENS_FILE = Path("/opt/data/whoop/tokens.json")
CACHE_FILE = Path("/opt/data/whoop/daily_profile_raw.json")
BASE_URL = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"


def load_tokens():
    with open(TOKENS_FILE) as f:
        return json.load(f)


def save_tokens(data):
    with open(TOKENS_FILE, "w") as f:
        json.dump(data, f, indent=2)


def refresh_access_token(tokens):
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
        return None
    if "error" in result:
        return None
    tokens["access_token"] = result["access_token"]
    tokens["refresh_token"] = result["refresh_token"]
    tokens["expires_at"] = datetime.now(timezone.utc).isoformat()
    save_tokens(tokens)
    return tokens["access_token"]


def api_get(path, token, retries=3):
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


def fetch_fresh(token, days=30):
    """Fetch fresh data from API."""
    data = {}
    profile = api_get("/v2/user/profile/basic", token)
    if "_auth_error" in profile:
        return None
    data["profile"] = profile
    data["body"] = api_get("/v2/user/measurement/body", token)
    data["recovery"] = api_get(f"/v2/recovery?limit={days}", token).get("records", [])
    data["sleep"] = api_get(f"/v2/activity/sleep?limit={days}", token).get("records", [])
    data["workout"] = api_get(f"/v2/activity/workout?limit={days}", token).get("records", [])
    data["cycles"] = api_get(f"/v2/cycle?limit={days}", token).get("records", [])
    return data


def main():
    tokens = load_tokens()
    days = int(sys.argv[1]) if len(sys.argv) > 1 else 30

    data = fetch_fresh(tokens["access_token"], days)
    if data is None:
        new_token = refresh_access_token(tokens)
        if not new_token:
            print(json.dumps({"error": "AUTH_NEEDED"}))
            return
        data = fetch_fresh(new_token, days)
        if data is None:
            print(json.dumps({"error": "AUTH_FAILED"}))
            return

    # Cache it
    with open(CACHE_FILE, "w") as f:
        json.dump(data, f, indent=2, default=str)

    print(json.dumps(data, indent=2, default=str))


if __name__ == "__main__":
    main()
