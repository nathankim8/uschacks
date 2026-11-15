# Controlled-demo BLE identifier proposal

**Status: proposed for ESP32 and mobile engineer confirmation.** This document specifies the bytes the backend integration expects. It does not claim firmware or a phone scan has been tested. Record both engineers' acceptance in the contract-change PR before freezing the wire format.

## Identifier

Each controlled test tag receives a randomly generated 128-bit UUID, explicitly entered in the backend's enabled test-identifier registry. The tag advertises this UUID as its sole 128-bit service UUID. The mobile app submits its canonical lowercase representation as `advertisement_id`:

```text
12345678-1234-4abc-8def-0123456789ab
```

This is an example test vector, not an automatically authorized identifier. Use a separate random value for each actual test tag. There is no shared catch-all identifier that authorizes arbitrary tags. The operator supplies the controlled set of service UUIDs to participating demo phones out of band; there is no public endpoint exposing every tag or its owner.

The UUID is public over the air and can be copied. It is neither a password nor proof of physical ownership. The private ownership claim token is never advertised. Do not broadcast owner account IDs, names, emails, coordinates, or the phone's Bluetooth address as the backend identifier.

## Advertisement bytes

Use ordinary legacy BLE advertisements, with the identifier in the primary advertisement rather than only in a scan response. No pairing, connection, or GATT characteristic read is required by the protocol. The proposed service UUID list uses AD type `0x07`, the complete list of 128-bit service UUIDs. The Bluetooth SIG defines this data type in its [Assigned Numbers](https://www.bluetooth.com/wp-content/uploads/Files/Specification/HTML/Assigned_Numbers/out/en/index-en.html).

| Bytes (hex) | Meaning |
|---|---|
| `02 01 06` | Length 2; Flags AD type `0x01`; LE general discoverable and BR/EDR not supported |
| `11 07` | Length 17, including AD type `0x07` and the 16 UUID bytes |
| `ab 89 67 45 23 01 ef 8d bc 4a 34 12 78 56 34 12` | Example UUID, least-significant byte first |

Complete 21-byte example advertising data:

```text
02 01 06 11 07 ab 89 67 45 23 01 ef 8d bc 4a 34 12 78 56 34 12
```

The length field does not include itself. These 21 bytes fit the legacy 31-byte advertising-data budget, without a local name. Espressif documents the advertising data structure and budget in [ESP32 device discovery](https://docs.espressif.com/projects/esp-idf/en/stable/esp32/api-guides/ble/get-started/ble-device-discovery.html). Multibyte UUID data is sent in reverse byte order relative to the printed UUID, as illustrated in the vendor's [advertising data examples](https://docs.silabs.com/bluetooth/8.3.0/bluetooth-fundamentals-advertising-scanning/advertising-data-basics).

If the firmware BLE library accepts UUID text, give it the canonical UUID and let the library serialize it. Do not reverse the text and then let the library reverse it again. If implementing raw advertising bytes, reverse all 16 bytes, not each printed UUID group independently. Phone BLE libraries typically return parsed UUID strings; normalize those to lowercase rather than reversing already parsed values.

The format has no on-air version byte in this demo; its scope is this approved test registry. Any future payload layout needs a new documented version and agreement among backend, mobile, and firmware owners.

## Handoff between firmware, phone, and backend

| Owner | Responsibility |
|---|---|
| ESP32 engineer | Confirm chip supports BLE; program the assigned UUID; keep it in the primary advertisement; verify the byte vector; choose a reliable demo advertising interval |
| Mobile engineer | Scan for the assigned service UUIDs; parse the detection callback without pairing; request location with explicit permission and reporting consent; submit the canonical UUID, detection time, phone coordinates, accuracy, and `simulated: false` |
| Backend operator | Enroll only controlled test UUIDs; bind the intended verified owner and secret claim token; check authorized retrieval and disable identifiers after the demo |

The tag has no GPS or cellular modem. A reporting phone sends its own position through its internet connection. The returned last-seen location approximates where a participating phone heard the tag, not a GPS measurement from the tag. Bluetooth range and phone location uncertainty both matter.

Start with foreground phone scanning. Lock-screen, background execution, power saving, app termination, and OS permission behaviors require separate device-specific tests; this backend does not establish that those modes work. Motion detection may change the firmware's advertising behavior, but it does not change the identifier or API fields in this proposal.

## Before public use

Static service UUIDs are suitable only for this bounded, consented demo. A public deployment needs rotating ephemeral identifiers, a reviewed cryptographic scheme and authorized resolution process, and a strategy for scanner discovery without publishing a permanent per-owner identifier list. UUID rotation alone is insufficient if an unchanging BLE address or other advertisement fields remain linkable.

Unwanted-tracking protections must cover alerts to people carrying an unknown tag, actionable ways to identify and disable it, abuse reporting and response, and the behavior of accessories around nonparticipating phones. Coordinate those protections with the firmware and mobile teams before public deployment. The current backend's allowlist, authenticated reporting, and owner restrictions do not replace them. See [SECURITY.md](SECURITY.md).
