# Campus Guard backend API — proposed contract

**Status: review draft, not yet the approved shared contract.** This document is the concrete proposal for `docs/CONTRACTS.md`. The repository requires a `contract-change` PR and human approval before that shared file changes. Mobile and firmware owners must confirm the API and [BLE format](BLE_PROTOCOL.md). Keep mocks aligned with these examples while reviewing; do not treat this draft as a silently approved interface.

The first milestone uses simulated detection data with real Supabase authentication, database storage, and owner authorization. A passing simulation does not demonstrate BLE reception or phone location collection. See the [real hardware checklist](REAL_HARDWARE_CHECKLIST.md) for that separate milestone.

## Connection and authentication

Base URL: `https://<project-ref>.supabase.co/functions/v1/campus-guard`. Local Supabase uses `http://127.0.0.1:54321/functions/v1/campus-guard`.

Every endpoint requires a normal signed-in Supabase user's access token. Use the mobile team's existing Supabase Auth flow to sign in, confirm the account's email or phone, and refresh expired sessions. Anonymous users are rejected even if they have an anonymous Auth session. A publishable key alone is not user authentication.

```http
Authorization: Bearer <user-access-token>
apikey: <project-publishable-key>
Content-Type: application/json
```

The publishable key may be shipped with the app. The service/secret key, database password, and operator provisioning credentials must never be shipped with the app. Legacy Supabase `anon` keys work as the publishable key where the project still uses them. Client user IDs and owner IDs are never accepted in the four mobile endpoints; the backend obtains identity from the verified session. Banned accounts are rejected.

Requests and responses use JSON. UUIDs use canonical lowercase `8-4-4-4-12` notation. Timestamps use RFC 3339 with an explicit timezone, for example `2026-11-14T20:15:00Z`; responses may use `+00:00`. Input requires uppercase `T` and `Z` (or a numeric offset), a valid calendar date, hours `00`–`23`, and seconds `00`–`59`; optional fractional seconds have 1–6 digits. Leap seconds are not accepted. Do not compare timestamps by string spelling. Unexpected fields and wrong JSON types are rejected. POST bodies have a 4096-byte limit; the database also caps the canonical JSON representation at 4096 bytes. The examples below contain invented identifiers and simulated locations; they are not pre-enrolled credentials.

## Integration sequence

1. An operator confirms possession of the controlled test tag, enrolls its random advertisement UUID, binds it to the intended owner's Supabase user ID, and provides that owner a private claim token.
2. The owner signs in and registers the device using that UUID and token. Save the returned `device.id` for retrieval.
3. A reporting phone signs in and explicitly opts into location reporting. Reporting and ownership may belong to different users.
4. For the first milestone, the simulator submits `simulated: true`. For the hardware milestone, the mobile app submits `simulated: false` only after a real BLE detection and a fresh phone location fix.
5. The owner requests the corresponding last-seen stream. An unrelated user receives the same result as for an unknown device: `404`.

There is no endpoint to enumerate nearby tags, arbitrary owners, reporters, or sighting history. The app must retain its registration result. Realtime subscriptions are outside this milestone.

## `POST /scanner-consent`

Consent belongs to the signed-in account; the demo supports one logical participating scanner per account. The mobile app must explain that its approximate location will be reported when it detects an enrolled tag and obtain an explicit choice before opting in. OS Bluetooth and location permissions alone do not imply backend consent.

```json
{"opted_in": true}
```

Response `200`:

```json
{"scanner": {"opted_in": true}}
```

Set `opted_in` to `false` to stop reporting. The backend removes that user's retained sightings and duplicate records; it cannot restore older sightings that were previously replaced. Calling the endpoint again with the same value is valid. A valid opt-out remains allowed even after the consent quota is exhausted; the quota must never force someone to keep participating.

```bash
curl "$BASE_URL/scanner-consent" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $REPORTER_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  --data '{"opted_in":true}'
```

## `POST /devices`

```json
{
  "advertisement_id": "12345678-1234-4abc-8def-0123456789ab",
  "claim_token": "<private operator-issued token of at least 32 characters>",
  "name": "Demo backpack tag"
}
```

`name` must contain 1–80 characters after trimming. `claim_token` must contain 32–256 characters. The UUID must be enabled in the operator's registry, bound to this signed-in owner, and accompanied by the correct claim token. Merely hearing the BLE UUID never establishes ownership. A scanner cannot claim another user's tag.

Response `201` for first registration, `200` for a repeat by the same owner with the same valid claim:

```json
{
  "device": {
    "id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
    "advertisement_id": "12345678-1234-4abc-8def-0123456789ab",
    "name": "Demo backpack tag",
    "verified_at": "2026-11-14T20:14:00+00:00"
  }
}
```

`verified_at` records completion of the operator-bound claim. It is not a cryptographic attestation by the ESP32. Keep the claim token out of BLE advertisements, analytics, screenshots, and normal request logs. This endpoint is for claiming a pre-enrolled device; it does not create an unrestricted tracking identifier or transfer ownership.

## `POST /sightings`

All six fields are required:

```json
{
  "advertisement_id": "12345678-1234-4abc-8def-0123456789ab",
  "observed_at": "2026-11-14T20:15:00Z",
  "latitude": 34.0205,
  "longitude": -118.2856,
  "accuracy_m": 20,
  "simulated": true
}
```

Use the phone's coordinates and the time of its BLE detection, not coordinates attributed to the ESP32. The ESP32 has neither GPS nor cellular connectivity. The backend records a participating phone's report that it was near the tag; neither the BLE UUID nor the GPS report is attested by this demo.

| Field | Validation |
|---|---|
| `advertisement_id` | Canonical lowercase UUID; explicitly enrolled, enabled, and registered |
| `observed_at` | RFC 3339 timestamp; no more than 5 minutes old or 30 seconds in the future at receipt |
| `latitude` | JSON number from `-90` through `90` |
| `longitude` | JSON number from `-180` through `180` |
| `accuracy_m` | JSON number from `0` through `1000` meters |
| `simulated` | JSON boolean; `true` for generated data, `false` for actual scan/location observations |

Stringified numbers, `null`, missing fields, extra fields, and invalid dates are rejected. The authenticated reporting account must be opted in. A tag need not belong to the reporter.

Response `202` for a valid newly accepted report:

```json
{"accepted": true, "duplicate": false}
```

Response `200` for another valid report within 30 seconds from the same reporter, device, and simulation stream:

```json
{"accepted": true, "duplicate": true}
```

The duplicate response does not update the stored location. Accepted reports older than the current newest observation do not move last-seen backward. The reporting response reveals no location, owner, database device ID, or other reporter. This endpoint is not a location lookup.

```bash
# SIMULATED: these coordinates are a fixed fixture, not a phone GPS reading.
OBSERVED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
curl "$BASE_URL/sightings" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $REPORTER_ACCESS_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"advertisement_id\":\"$ADVERTISEMENT_ID\",\"observed_at\":\"$OBSERVED_AT\",\"latitude\":34.0205,\"longitude\":-118.2856,\"accuracy_m\":20,\"simulated\":true}"
```

For the actual phone flow, supply scan callback data and a current location fix from the mobile app. Do not copy the fixture coordinates and relabel them as real.

## `GET /devices/{device_id}/last-seen?simulated=true|false`

The `simulated` query parameter is required. It selects one of two separate latest-sighting records, so simulated data cannot overwrite the real stream or silently appear in a real lookup. The identifier in the path is the internal `device.id` returned by registration, not the BLE advertisement UUID.

```bash
curl "$BASE_URL/devices/$DEVICE_ID/last-seen?simulated=true" \
  -H "apikey: $SUPABASE_PUBLISHABLE_KEY" \
  -H "Authorization: Bearer $OWNER_ACCESS_TOKEN"
```

Response `200` for the registered owner, with a current sighting:

```json
{
  "device_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
  "sighting": {
    "latitude": 34.021,
    "longitude": -118.286,
    "accuracy_m": 150,
    "observed_at": "2026-11-14T20:15:00+00:00",
    "received_at": "2026-11-14T20:15:02+00:00",
    "simulated": true
  }
}
```

Coordinates are rounded to three decimal places before storage. Returned accuracy is at least 150 meters and otherwise preserves the larger submitted accuracy. This is a coarse report of the phone's position, not a measured radius guaranteeing the tag's position. Use `observed_at` to show the age; `received_at` is backend receipt time.

Response `200` when an owned, enabled device has no non-expired report in the requested stream:

```json
{"device_id": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee", "sighting": null}
```

Missing devices, disabled devices, and devices owned by someone else all return `404`:

```json
{"error": {"code": "device_not_found", "message": "Device not found."}}
```

The owner need not be physically near the tag or opted into reporting to retrieve its location. Other authenticated users, including the reporting phone's account, cannot retrieve it unless they are the registered owner.

## Errors, limits, and retries

Application errors use this shape. Program against HTTP status and `error.code`; message text is for people and may change.

```json
{"error": {"code": "invalid_request", "message": "Invalid request."}}
```

| HTTP status | Client behavior |
|---|---|
| `400` | Correct invalid fields, query parameters, JSON, or timestamps; do not retry unchanged |
| `401` | Obtain a verified, non-anonymous user session; refresh an expired token once |
| `403` | Reporting consent or device claim authorization is missing; do not retry blindly |
| `404` | Resource unavailable to this caller; reveal no ownership inference in the UI |
| `405` | Use the documented HTTP method |
| `413` | Reduce request size |
| `415` | Send `Content-Type: application/json` for POST |
| `429` | Wait at least the advertised retry interval, then add random jitter |
| `500` / `503` | Retry with bounded backoff; do not log credentials or coordinate bodies |

Stable database application error codes:

| Code | Status | Meaning |
|---|---|---|
| `unauthorized` | `401` | Session/account is not an eligible verified, non-anonymous, unbanned user |
| `invalid_request` | `400` | Request shape, field value, or detection time is invalid |
| `device_not_claimable` | `403` | Identifier, expected owner, or claim token does not authorize registration |
| `scanner_opt_in_required` | `403` | Reporting account has not opted in or has opted out |
| `identifier_not_allowed` | `403` | Sighting identifier is unknown, unregistered, or disabled |
| `device_not_found` | `404` | Device is absent, disabled, or not owned by the caller |
| `rate_limited` | `429` | At least one account quota is exhausted |

Edge-specific codes are `invalid_json` (`400`), `origin_not_allowed` (`403`), `not_found` (`404`, unknown route), `method_not_allowed` (`405`), `body_too_large` (`413`), `unsupported_media_type` (`415`), and `unavailable` (`503`). Browser origins must be explicitly configured by the backend operator; native mobile requests do not require a browser origin. Responses use `Cache-Control: no-store`.

Rate limits are per authenticated user and use fixed UTC time windows in PostgreSQL. They apply across concurrent requests and across phones sharing an account.

| Operation | Limit |
|---|---|
| Set scanner consent | 10 requests per minute; valid withdrawal by an eligible authenticated account bypasses this quota |
| Register a device | 5 requests per minute |
| Submit a sighting | 30 requests per minute and 500 per UTC day |
| Retrieve last seen | 60 requests per minute |

Duplicate submissions and rejected requests that reach the authorized database operation consume quota. Malformed HTTP requests rejected before a database call are not part of this application quota. These quotas are not a general network denial-of-service defense.

Example `429` (the actual interval varies):

```http
Retry-After: 42
```

```json
{
  "error": {"code": "rate_limited", "message": "Rate limit exceeded."},
  "retry_after_seconds": 42
}
```

## Retention and privacy behavior

The backend keeps only the newest observation for each device and simulation stream. There is no location history API. An observation disappears from retrieval 24 hours after `observed_at`, even if cleanup has not run. Scheduled cleanup removes expired rows every 15 minutes; therefore normal physical table retention is at most approximately 24 hours 15 minutes. Duplicate records are removed after 24 hours and rate buckets after 48 hours. Do not promise immediate removal from infrastructure logs or backups; deployment retention needs a separate check.

Opting out removes the reporting account's retained sightings and duplicate records. Deleting an Auth account cascades through its linked backend data. Disabling a registry identifier through the operator RPC prevents new registration, reporting, and owner lookup and removes that device's retained sightings and duplicate records. See [security and deployment limits](SECURITY.md), including backup retention.

## Operator-only enrollment

Provisioning is separate from the mobile API. From a trusted backend script or Supabase SQL console, the operator calls `public.cg_provision_test_device(p_body jsonb)` with the service role, after verifying which owner controls the physical test tag:

```json
{
  "advertisement_id": "12345678-1234-4abc-8def-0123456789ab",
  "owner_id": "11111111-2222-4333-8444-555555555555",
  "claim_token": "<fresh randomly generated secret with at least 32 characters>",
  "enabled": true
}
```

The RPC response is an internal envelope:

```json
{"status": 200, "body": {"advertisement_id": "12345678-1234-4abc-8def-0123456789ab", "enabled": true}}
```

Only the token hash is stored. `enabled` defaults to `true`; setting it to `false` disables a test identifier and deletes its retained sightings/duplicate records. Reprovisioning for the same owner rotates the claim-token hash; pass a fresh secret privately to that owner. An existing identifier cannot be reassigned to another owner through this RPC (`409 identifier_already_provisioned`). An invalid owner returns `400 invalid_owner` for new enrollment or enabling a tag; an operator may still disable an existing tag after its owner is banned. Ordinary client sessions cannot call the provisioning RPC.

The four mobile operations also use internal PostgreSQL RPCs (`cg_set_scanner`, `cg_register_device`, `cg_submit_sighting`, `cg_last_seen`) with a single `p_body` argument. Their `{status, body}` envelope is unwrapped by the Edge Function into the HTTP status/body documented above. They independently enforce authorization, validation, limits, and consent, so bypassing the Edge Function via the Data API does not bypass these controls. The mobile integration should use the HTTP routes rather than depending on this internal wrapper.
