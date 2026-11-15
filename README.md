# Campus Guard

**A smart anti-theft tag for your bag.** A small device rides inside a 3D-printed
Trojan-shield case, watches for the motion of someone actually walking off with your
bag, sounds an alarm, and — if it's taken anyway — helps you find where it went.

> _Protection, disguised as a crest._ · USC Hacks 2026

## The problem

Students leave bags unattended dozens of times a day — libraries, dining halls, gyms.
Trackers tell you where your stuff went *after* it's gone. Campus Guard reacts the
moment the bag is carried off, and the hard part it solves is telling a real theft
apart from a harmless bump.

## How it works

```
  ESP32 tag (in the shield case)          Apple Find My              Your iPhone
  ├─ IMU senses motion ──┐                 nearby iPhones       ┌─ Campus Guard app
  │  bump vs. carry       │  ntfy.sh        report the beacon   │  (SwiftUI)
  ├─ buzzer alarm         ├───────────────────────────────────▶├─ Normal / Alert
  └─ BLE Find My beacon ──┘  commands + pushes                  ├─ red alarm + siren
                              │                                 └─ map of last-seen
                     laptop decrypts Find My reports ──▶ Cloudflare Worker ──▶ app
```

- **The tag** (ESP32 + motion sensor) decides on its own whether motion looks like a
  theft, and sounds its buzzer. It keeps running even when your phone isn't nearby.
- **Commands and alerts** travel over [ntfy](https://ntfy.sh) — the app arms/disarms
  the tag and receives alarms in real time.
- **Location** comes from Apple's Find My network: nearby iPhones report the tag's
  beacon, a laptop decrypts those reports, and a Cloudflare Worker serves them to the
  app's map. (This is an unofficial Find My integration — see *Honest limits*.)

## Modes

| Mode | What the tag does |
|---|---|
| **Normal** | Watches, stays quiet. Your bag is with you. |
| **Alert** (armed) | Theft-like motion triggers the buzzer and a push to your phone. |
| **Lost mode** | Turns on the Find My beacon so you can track where the bag goes. |

## Hardware

| Part | Role |
|---|---|
| ESP32 dev board | Controller + BLE Find My beacon |
| SparkFun ISM330DHCX (6-axis IMU) | Motion sensing (`GPIO21` SDA / `GPIO22` SCL) |
| HW-512 buzzer + IRLZ34N MOSFET | Audible alarm (`GPIO23`) |
| 3D-printed Trojan-shield case | Enclosure with a removable lid and side sound ports |

A machine-learning classifier that separates *still / bump / pickup / carry* is in
development; a motion-threshold rule is the demo fallback.

## Repository layout

| Path | What's there |
|---|---|
| [`frontend/ios/`](frontend/ios/) | Native SwiftUI app (iOS 18+, no third-party deps). `TagKit` is the protocol + ntfy + Find My client; `CampusGuardUI` is the screens. |
| [`frontend/docs/TAG_PROTOCOL.md`](frontend/docs/TAG_PROTOCOL.md) | **The tag ↔ app contract** — commands, pushes, firmware versions. Source of truth. |
| [`backend/cloud-gateway/`](backend/cloud-gateway/) | Cloudflare Worker: relays tag commands/pushes and serves Find My locations. |
| [`backend/findmy-uploader/`](backend/findmy-uploader/) | Laptop script that uploads decrypted Find My coordinates to the gateway. |
| [`TrojanGuard/opening/`](TrojanGuard/opening/) | Animated opening sequence for the demo video. |
| [`AGENTS.md`](AGENTS.md) · [`docs/`](docs/) | Team rules and workflow for humans and AI agents. |

## Status

| Piece | State |
|---|---|
| Motion sensing + buzzer on the tag | ✅ Working on the bench |
| iOS app (arm/disarm, alarm, tracking, siren) | ✅ Built, 12/12 tests pass, runs on device |
| Tag ↔ app over ntfy | ✅ Working |
| Find My locations in the app | ⚠️ Works, but depends on a laptop running the decrypt containers |
| ML bump-vs-theft classifier | 🚧 In development (threshold fallback for the demo) |

## Honest limits

- **Not an official Find My accessory.** Campus Guard does **not** appear in Apple's
  Find My app as a certified item, and we don't claim it does. It uses an experimental,
  unofficial integration that can break when Apple changes things.
- **No GPS on the tag.** Find My locations come from nearby iPhones and arrive minutes
  later; alarm-time map pins are where *your* phone was, not the bag.
- **Find My tracking is laptop-dependent** right now — it stops updating when the
  decrypt service is off.

## Team

Built at USC Hacks 2026 by [@nathankim8](https://github.com/nathankim8),
[@emmaxqy](https://github.com/emmaxqy), and [@boqibama](https://github.com/boqibama).

New here? Read [`AGENTS.md`](AGENTS.md), then [`frontend/docs/TAG_PROTOCOL.md`](frontend/docs/TAG_PROTOCOL.md)
and [`docs/WORKFLOW.md`](docs/WORKFLOW.md).
