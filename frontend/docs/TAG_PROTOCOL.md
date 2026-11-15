# Campus Guard tag ↔ app protocol

How the iOS app (`frontend/ios/`, `TagKit`) and the tag firmware talk.
Status: **v9 / v10 baseline is implemented on both sides**. **v11** (machine tags + request ids)
is a proposal: the app already understands it, and it is waiting on a firmware decision.

| Firmware | Board | Lost mode | Find My beacon | Speaks |
|---|---|---|---|---|
| `tag_onchip` v9 | ESP32 | none | none | baseline |
| `tag_lostmode` v10 | ESP32 | LOSTMODE/FOUND, beacon boots + 3-min check-ins | only in lost mode | baseline + lost-mode wording |
| `tag_pico` v10-pico | Pico 2 W | none | always on | baseline |
| v11 (proposed) | either | as the board supports | as the board supports | baseline + `cg1` tags |

The app detects what the tag can do from its pushes. It shows LOSTMODE/FOUND only after the
tag has sent a lost-mode or check-in push, so with the Pico those controls stay hidden. It sends
request ids only after a push says `fw-11` or newer.

## Transport (all versions)

ntfy.sh (or a self-hosted ntfy), two topics:

| Direction | Topic | How |
|---|---|---|
| app → tag | `<topic>-cmd` | `POST` one command per message (plain text body) |
| tag → app | `<topic>` | tag `POST`s human-readable pushes; the app keeps **one** streaming `GET /<topic>/json?since=<last id>` |

- The tag polls `<topic>-cmd` every 6 s. Expect 2–8 s from tap to confirmation.
- **Never poll ntfy in a loop from the app.** ntfy rate-limits per IP, and the tag shares the
  hotspot's IP. The app opens one stream while it's in the foreground, resumes from the last
  message id after a reconnect (backoff 2 → 30 s), and does one catch-up read when iOS gives
  it background time.
- Topic names are secrets: anyone who knows them can arm/disarm the tag. The app stores them in
  the Keychain. ntfy access tokens (`Authorization: Bearer …`) are supported for reserved topics.

## Commands (app → tag)

| Command | Effect | Baseline confirmation push | v11 `ev-` |
|---|---|---|---|
| `ARM` | Alert mode (AI watches for theft) | `Armed. Your bag is protected.` | `armed` |
| `DISARM` | Normal mode, siren off (v10: also ends lost mode) | `Disarmed.` (or `Disarmed. Lost mode off - bag found.`) | `disarmed` / `found` |
| `LOSTMODE` | ESP32 v10: Wi-Fi off, Find My beacon on | `Lost mode ON: …` | `lost_on` (or `status` if already on) |
| `FOUND` | ESP32 v10: DISARM + end lost mode | `Disarmed. Lost mode off - bag found.` | `found` |
| `PUSHTEST` | Push only, no beep (used by the app's Connect screen) | `Test alert from your Campus Guard Tag.` | `test` |
| `TEST` | 1 s beep | none (UDP/Serial only) | `test` |
| `CHIRP` | 3 short beeps ("Find it") | none | `chirp` |
| `SIREN` | Siren on ("Ring my bag") | none | `siren` |
| `STOP` | Siren off | none | `stop` |
| `PING` | Version | none (`PONG v10…` on UDP/Serial only) | `status` |

The app changes screens **only when the confirmation arrives** (timeout 20 s, or 270 s while
the ESP32 is in lost mode and only reads commands at check-ins). Commands without a baseline
confirmation are reported as "Sent, listen for the tag". The app sends one command at a time,
because `tag_lostmode` v10 keeps only the last command per poll (the Pico has an 8-entry queue).

## Pushes (tag → app), baseline

The app matches the first words, case-insensitively, so later wording can change freely:

| Starts with | Meaning | State the app infers |
|---|---|---|
| `ALARM` | theft detected, siren on (priority urgent) | armed, siren on |
| `Armed` | ARM done | armed, siren off |
| `Disarmed` + `lost mode off` / `found` | FOUND (or DISARM while lost) | normal, siren off, lost off |
| `Disarmed` | DISARM done | normal, siren off, lost off |
| `Test alert` | PUSHTEST done | – |
| `Lost mode ON` | LOSTMODE done, or armed + Wi-Fi gone 15 s | lost on |
| `Lost mode check-in` | ESP32 lost-mode check-in (~every 3 min, priority low) | lost on, last check-in |

An `ALARM` older than 10 minutes when the app opens is history, not a new alarm, and each
alarm id opens the red screen at most once.

## v11 proposal: machine tags (backward compatible)

The human text stays the same (so the ntfy app still reads well). Machine state goes in the
ntfy `Tags` header, so it costs no extra traffic. The app reads these whenever `cg1` is present:

```
Tags: rotating_light,cg1,fw-11,ev-armed,rid-ab12,st-a1s0l0,boot-normal
```

| Tag | Meaning |
|---|---|
| `cg1` | protocol marker |
| `fw-<version>` | firmware version (`11`, `11-pico`, …). Request ids are used when the leading number is ≥ 11 |
| `ev-<event>` | `armed disarmed found alarm lost_on checkin status test chirp siren stop wifi_back boot unknown` |
| `rid-<id>` | echo of the command's request id |
| `st-a<0/1>s<0/1>l<0/1>` | armed / siren latched / lost mode |
| `boot-<normal/checkin>` | boot kind (ESP32 lost mode only) |

Firmware changes in v11:

- **A. Request ids.** Accept `VERB` or `VERB <rid>` (rid: 1–8 chars `[a-z0-9]`). Use the first token as the verb and echo the second as `rid-`.
- **B. Every command answers on ntfy**, including PING (`ev-status`), TEST, CHIRP, SIREN, STOP and unknown commands.
- **C. Tags** as above on every push. Priority: urgent = alarm, high = lost_on, default = armed/disarmed/found, low = check-in/status/acks.
- **D. Wi-Fi back / boot**: when online again, push `ev-wifi_back` / `ev-boot` with `st-`, so the app learns about a siren that started offline.
- **E. Check-in pushes carry `st-`**, so the app knows the siren is still on while lost (ESP32 only).
- **F. (Optional) heartbeat**: `ev-status` at priority min every 10 min while armed.
- **G. Command queue** in the poller (the Pico already has one; `tag_lostmode` v10 keeps only the last command per poll).

On the Pico (no lost mode), `lost_on`, `checkin` and `boot-checkin` don't apply.

## Find My locations

Nearby iPhones report the tag's beacon to Apple. `findmy/server.py` fetches and decrypts those
reports and serves `GET /api/locations`:

```json
{"tag":"CGTAG","fetched_at":1794700000,"count":2,"undecryptable":0,
 "reports":[{"ts":1794690000,"lat":34.02,"lon":-118.28,"accuracy_m":12,"confidence":2}]}
```

The app's tracking screen shows these (newest first) next to its own "phone at the alert" pins.
Set the URL in **Settings › Connection**. The app sends `Authorization: Bearer <token>` if one is set.
`server.py` stays on `127.0.0.1`. For the demo, the phone reads the same JSON from the Cloudflare
gateway (`https://campus-guard-gateway.ryan-bohan-chen.workers.dev/api/locations`, app token required),
which a laptop uploader feeds. The private key never leaves the laptop. See `backend/cloud-gateway/README.md`.
