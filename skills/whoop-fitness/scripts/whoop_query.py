#!/usr/bin/env python3
"""WHOOP Q&A data fetcher. Fetches fresh data and outputs JSON for analysis."""

import json
import os
import sys
import time
import tempfile
from datetime import datetime, timezone
from pathlib import Path

TOKENS_FILE = Path("/opt/data/whoop/tokens.json")
CACHE_FILE = Path("/opt/data/whoop/daily_profile_raw.json")
BASE_URL = "https://api.prod.whoop.com/developer"
TOKEN_URL = "https://api.prod.whoop.com/oauth/oauth2/token"

# Ensure data directory exists
TOKENS_FILE.parent.mkdir(parents=True, exist_ok=True)


def load_tokens():
    with open(TOKENS_FILE) as f:
        return json.load(f)


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
        print(f"ERROR: Token refresh returned error: {result.get('error_hint', result['error'])}", file=sys.stderr)
        return None
    if "access_token" not in result:
        print("ERROR: Token refresh response missing access_token", file=sys.stderr)
        return None
    tokens["access_token"] = result["access_token"]
    tokens["refresh_token"] = result.get("refresh_token", tokens["refresh_token"])
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
    """Fetch fresh data from API. Returns None on auth error, dict on success."""
    data = {}
    endpoints = [
        ("profile", "/v2/user/profile/basic", False),
        ("body", "/v2/user/measurement/body", False),
        ("recovery", f"/v2/recovery?limit={days}", True),
        ("sleep", f"/v2/activity/sleep?limit={days}", True),
        ("workout", f"/v2/activity/workout?limit={days}", True),
        ("cycles", f"/v2/cycle?limit={days}", True),
    ]
    for key, path, is_list in endpoints:
        result = api_get(path, token)
        if "_auth_error" in result:
            return None
        if is_list:
            data[key] = result.get("records", []) if "_error" not in result else []
        else:
            data[key] = result if "_error" not in result else {}
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

    # Cache it atomically with restrictive permissions
    fd, tmp_path = tempfile.mkstemp(dir=CACHE_FILE.parent, suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(data, f, indent=2, default=str)
        os.chmod(tmp_path, 0o600)
        os.replace(tmp_path, CACHE_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise

    print(json.dumps(data, indent=2, default=str))


if __name__ == "__main__":
    main()
