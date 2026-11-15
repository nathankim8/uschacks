# Campus Guard cloud gateway (Cloudflare Worker)

The iOS app is in `frontend/ios` (branch `fe/T-02-native-ios-app`). Unrelated to the Supabase backend in `be/T-01`; this only serves the tag's Find My locations.

Public, token-protected endpoint the iOS app uses for **Find My locations**.

```
iPhone app ──Bearer APP_TOKEN──▶  campus-guard-gateway.ryan-bohan-chen.workers.dev  ◀──Bearer INGEST_TOKEN── laptop uploader
                                   GET /api/locations   (KV: latest reports)                 POST /v1/ingest
iPhone app ◀────────── ntfy.sh (tag link, unchanged) ──────────▶ tag
```

| Route | Auth | What |
|---|---|---|
| `GET /v1/health` | none | liveness, no data |
| `GET /api/locations` | `APP_TOKEN` | latest decrypted Find My reports (`ts, lat, lon, accuracy_m, confidence`), newest first |
| `POST /v1/ingest` | `INGEST_TOKEN` | uploader stores reports (validated, max 500, unknown fields dropped) |
| `GET /tag/json`, `POST /tag-cmd` | `APP_TOKEN` | optional ntfy proxy, **off** (returns 503) unless `NTFY_TOPIC` is set |

- **The private key never leaves the laptop.** `backend/findmy-uploader/upload.py` reuses `findmy/server.py` (unmodified) to fetch and decrypt, and sends only timestamps and coordinates. Outbound HTTPS only: no tunnel, no open port.
- **Two tokens.** The app can read but not write, and the laptop can write but not read. Tokens are compared in constant time, and wrong or missing tokens get 401. They live in `backend/cloud-gateway/.secrets.local` (git-ignored) and as Worker secrets.
- **Why the tag link isn't proxied.** Workers share outbound IPs with other Cloudflare customers, and ntfy.sh rate-limits per IP. In testing it returned 429 and 522 intermittently, which isn't acceptable for alarms. To enable the proxy anyway, set `NTFY_TOPIC` and an ntfy.sh account token (`NTFY_TOKEN`, so limits apply per account). Then the phone would hold only the app token, not the topic.

## Demo checklist

```bash
docker start anisette macless-haystack            # Find My backend (Apple login)
source backend/cloud-gateway/.secrets.local
python3 backend/findmy-uploader/upload.py           # leave running; uploads every 5 min
```

Check from anywhere:

```bash
curl -s -H "Authorization: Bearer $CG_APP_TOKEN" $CG_GATEWAY_URL/api/locations | head -c 300
```

## Deploy / change

```bash
cd backend/cloud-gateway
npx wrangler deploy                                # code changes
printf '%s' "$NEW" | npx wrangler secret put APP_TOKEN   # rotate a token (then update the app)
npx wrangler tail                                  # live logs
```

KV namespace `LOCATIONS` (`94623189c94b4a4d9f122f5217727d7d`). Preview URLs are disabled.

**Privacy:** anyone with the app token can see where the bag has been over the last 7 days. Rotate the token after the demo, or delete the Worker: `npx wrangler delete`.
