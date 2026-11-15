# Real phone and ESP32 acceptance checklist

This checklist is intentionally uncompleted. Passing the simulator proves only the backend path. Claim real crowdsourced tracking only after the real BLE detection, phone location report, and remote owner's retrieval below have all been demonstrated together and their evidence recorded.

## Preparation

- [ ] Human approves the [API proposal](API_PROPOSAL.md) and both firmware/mobile engineers confirm the [BLE byte format](BLE_PROTOCOL.md).
- [ ] Use a dedicated demo Supabase project or local stack; migrations and Edge Function are deployed and tests pass against that same target.
- [ ] Confirm retention cleanup is scheduled and its latest run succeeded. Confirm expired sightings cannot be retrieved even before physical cleanup.
- [ ] Enroll one random test UUID for a consenting owner's physical tag; record who verified that association. Deliver the claim token privately to that owner.
- [ ] Sign in separate verified owner, reporting-phone, and unrelated-user accounts. Confirm none uses anonymous Auth or service/secret keys in the app.
- [ ] Owner successfully registers the tag and saves the returned internal device ID.
- [ ] Explain what the reporting phone shares, obtain explicit opt-in, and confirm `POST /scanner-consent` reports `opted_in: true`.
- [ ] Record phone model, OS version, app build, firmware commit, ESP32 model, project identifier, and test time. Omit passwords, session tokens, claim tokens, and precise location histories from shared evidence.

## BLE and phone location

- [ ] Start in the foreground on a phone separate from the owner's phone. Enable the necessary Bluetooth and location permissions.
- [ ] Capture the phone's actual scan callback for the enrolled service UUID. Confirm no pairing or GATT connection is needed and the primary advertising bytes match the documented vector.
- [ ] Power off the ESP32 and verify fresh scan callbacks stop; power it on and verify they resume. A cached device list is insufficient evidence.
- [ ] Confirm the parsed UUID is canonical lowercase and matches the enrolled value; detect and reject byte-order mistakes.
- [ ] Read a fresh GPS/location fix from the reporting phone, record its measurement time and accuracy, and ensure it is temporally close to the BLE callback. Do not reuse the simulator's fixed coordinates.
- [ ] Ensure phone clock is correct and detection timestamps fall within the API's 5-minute past / 30-second future limits. Do not replace old detection times with upload times to bypass freshness checks.
- [ ] Submit the real callback UUID, callback timestamp, phone coordinates and accuracy with `simulated: false`; capture the `202` result without logging the access token.

## Owner retrieval from elsewhere

- [ ] Place the owner's phone outside BLE range of the tag and confirm the reporting phone still has internet connectivity.
- [ ] Retrieve `/devices/{device_id}/last-seen?simulated=false` using the owner's normal session; confirm `simulated: false`, correct detection time, rounded phone location, and expected coarse accuracy.
- [ ] Confirm the result arrived through the backend rather than a direct owner-to-tag scan or hardcoded/mock UI state.
- [ ] Request the same device with the unrelated user's session; expect `404 device_not_found` and no location. Repeat with the reporting account if it is not the owner.
- [ ] Request without authentication or with an expired token; expect denial and no location.
- [ ] Request `simulated=true` and confirm it is a separate record. Prior simulated fixtures must not appear in the real stream.
- [ ] Move the reporting phone and tag together, wait beyond duplicate suppression, collect another actual scan/location pair, and verify the later observation becomes last seen.

## Failure cases and data controls

- [ ] Submit another report from the same account/device/stream within 30 seconds; expect `200` with `duplicate: true` and unchanged stored location.
- [ ] Submit an older but still valid observation from another reporting account; it must not move last-seen backward.
- [ ] Try a random unenrolled identifier, another owner's claim token, malformed coordinates, extra fields, missing fields, stale time, and a future time. Expect rejection without exposing anyone's location.
- [ ] Exercise the per-user quota with a disposable test account; expect `429` and a retry interval. Concurrent submissions must not bypass it. Do not flood the shared demo owner's account.
- [ ] Opt the reporting account out. New reports must be denied and its retained sightings removed; re-enabling requires an explicit opt-in action.
- [ ] Disable the test identifier as operator. New reports, claims, and last-seen requests must be denied for that identifier.
- [ ] Verify no public/anonymous Data API table query or RPC bypass reveals the data.
- [ ] Verify expired observations return `sighting: null` for an otherwise valid owner and enabled device. Use controlled database test fixtures rather than waiting 24 hours during the demo.
- [ ] Check failures never print access tokens, claim tokens, service keys, or raw coordinate request bodies to shared logs.

## Scope and completion record

- [ ] Separately test background/locked-phone behavior if the team wants to claim it. Record tested OS/app states and failures; foreground success alone does not establish background operation.
- [ ] End the session by disabling demo tags, opting demo scanners out, and deleting temporary test accounts or fixtures according to the runbook.
- [ ] Save a concise result with the date, firmware/app versions, tested foreground/background states, backend test run link, actual BLE callback evidence, accepted real report, owner result, and unrelated-user denial. Keep sensitive credentials out.

Until those core checks pass, use this demo description: **“The simulated detection path reaches the authenticated backend and supports owner-authorized retrieval; phone BLE/location integration is pending.”** After completion, describe only the hardware, phone, and operating conditions actually tested.
