#!/usr/bin/env python3
"""Campus Guard: push Find My locations from the laptop to the Cloudflare gateway.

Reuses findmy/server.py's key loading and decryption (that file is not modified). Only timestamps
and coordinates are uploaded; the tag's private key never leaves this Mac. Outbound HTTPS only,
so it works behind the phone hotspot with no open ports or tunnels.

    source backend/cloud-gateway/.secrets.local   # CG_GATEWAY_URL, CG_INGEST_TOKEN
    python3 backend/findmy-uploader/upload.py      # every 5 min (CG_UPLOAD_EVERY seconds)
    python3 backend/findmy-uploader/upload.py --once

Needs the Macless-Haystack containers running (docker start anisette macless-haystack).
"""
import json
import os
import sys
import time
import urllib.error
import urllib.request

FINDMY_DIR = os.path.expanduser(os.environ.get("FINDMY_DIR", "~/Desktop/hackathon/findmy"))
sys.path.insert(0, FINDMY_DIR)
import server  # noqa: E402  (findmy/server.py: load_device / fetch_locations)

GATEWAY = os.environ.get("CG_GATEWAY_URL", "").rstrip("/")
TOKEN = os.environ.get("CG_INGEST_TOKEN", "")
EVERY = int(os.environ.get("CG_UPLOAD_EVERY", "300"))


def upload_once():
    data = server.fetch_locations(days=7)
    payload = {
        "tag": data.get("tag"),
        "fetched_at": data.get("fetched_at"),
        "undecryptable": data.get("undecryptable", 0),
        "reports": [
            {k: r[k] for k in ("ts", "lat", "lon", "accuracy_m", "confidence") if k in r}
            for r in data.get("reports", [])
        ],
    }
    req = urllib.request.Request(
        f"{GATEWAY}/v1/ingest",
        data=json.dumps(payload).encode(),
        method="POST",
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {TOKEN}",
                 "User-Agent": "campus-guard-uploader/1"},
    )
    with urllib.request.urlopen(req, timeout=30) as r:
        result = json.load(r)
    newest = payload["reports"][0]["ts"] if payload["reports"] else None
    age = f", newest {int((time.time() - newest) / 60)} min old" if newest else ""
    print(f"[{time.strftime('%H:%M:%S')}] uploaded {result.get('stored')} reports{age}", flush=True)


def main():
    if not GATEWAY or not TOKEN:
        sys.exit("Set CG_GATEWAY_URL and CG_INGEST_TOKEN (source backend/cloud-gateway/.secrets.local).")
    once = "--once" in sys.argv
    while True:
        try:
            upload_once()
        except urllib.error.HTTPError as e:
            print(f"[{time.strftime('%H:%M:%S')}] gateway refused: HTTP {e.code}", flush=True)
        except Exception as e:  # Apple/Docker hiccups: keep going
            print(f"[{time.strftime('%H:%M:%S')}] upload failed: {e}", flush=True)
        if once:
            return
        time.sleep(EVERY)


if __name__ == "__main__":
    main()
