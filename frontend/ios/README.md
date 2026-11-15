# Campus Guard: native iOS app

SwiftUI app for the Campus Guard bag tag (native successor to the Capacitor/React app in
emmaxqy/campus-guard).

## Stack

| Layer | What |
|---|---|
| `Packages/CampusGuardKit/Sources/TagKit` | The tag protocol: commands, push parser (v9/v10 text and v11 `cg1` tags), `TagSnapshot` state, ntfy client (one streaming connection with resume and backoff), `TagLink` (send → wait for the tag's confirmation), Find My client. Foundation only, Swift 6 strict concurrency, unit-tested. |
| `Packages/CampusGuardKit/Sources/CampusGuardUI` | `AppModel` (`@Observable`), screens, and phone services: notifications (time-sensitive alarms), location pins (`CLLocationUpdate`), a synthesized phone siren (`AVAudioEngine`), haptics, Keychain. |
| `CampusGuard/` | Thin app shell: `@main`, background refresh (`BGAppRefresh`, one catch-up read), Siri/Shortcuts App Intents ("Protect my bag", "Ring my bag"). |
| `Config/` | `Info.plist`, entitlements, `Base.xcconfig`, `Secrets.example.xcconfig`. |

iOS 18+, iPhone, portrait. No third-party dependencies.

## Screens

- **Setup** (every launch, per product decision): search → notification and location permission → *Connect* (a real `PUSHTEST` round trip; the Trojan shield fills as it waits). If no tag is set up yet, it asks for the ntfy topic, or the link the tag prints on its Serial Monitor. "Continue without the tag" runs the app on its own.
- **Home**: "Your bag is with you" / "You've left your bag", Normal ↔ Alert (changes only when the tag confirms), a status line ("Tag in Alert · last message 2 min ago"), and *Mark as lost*. On the ESP32 lost-mode firmware this offers to start the tag's lost mode.
- **Alarm** (red) ↔ **Tracking** (white): swipe or use the arrows; dragging the map never switches. Red has the phone-siren bell, *It's me* (DISARM) and "close on this phone only" if the tag can't be reached. White has the map (Find My reports + where your phone was at each alarm, with walking directions), *Ring my bag* (SIREN/STOP), the lost-mode check-in card and *Found*.
- **Activity**: everything the tag said, grouped by day.
- **Settings**: tag card (Find it / Beep / Test alert, firmware), alarm trigger (automatic/manual phone sound), Find My toggle, Connection (topic, server, tokens, Find My helper URL) and protocol details.

The protocol is in [`docs/TAG_PROTOCOL.md`](../docs/TAG_PROTOCOL.md).

## Run it

1. Install **Xcode 16 or newer** (verified with Xcode 27.2, iOS 26 simulator and an iPhone 17 Pro Max).
2. Optional: `cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig` and fill in your team ID and tag topic. It's git-ignored. Without it, the app asks for the topic during setup.
3. `open frontend/ios/CampusGuard.xcodeproj` → scheme **CampusGuard** → pick an iPhone or simulator → ▶︎. Set **Signing & Capabilities → Team** if you didn't put it in `Secrets.xcconfig`.
4. **⌘U** runs the TagKit tests (Swift Testing).

**Free Personal Team** (no paid developer account): put these in `Config/Secrets.xcconfig` too. The bundle id must be unique to your team, and personal teams can't use Time Sensitive notifications:
```
CG_BUNDLE_ID = com.campusguard.app.<your-team-id-lowercase>
CG_ENTITLEMENTS = Config/PersonalTeam.entitlements
```
After the first install, trust the developer on the phone (Settings › General › VPN & Device Management). Personal-team builds expire after 7 days; rebuild to renew.

**Demo config:** `Secrets.xcconfig` can also preset the tag topic (`CG_NTFY_TOPIC`) and the Find My gateway (`CG_FINDMY_URL`, `CG_FINDMY_TOKEN`), so a fresh install needs no typing. See the gateway README on the backend branch (`backend/cloud-gateway/README.md`).

If the project file ever gets out of sync: `brew install xcodegen && cd frontend/ios && xcodegen` (uses `project.yml`).

### Without Xcode

`frontend/ios/scripts/verify.sh` builds TagKit and runs its tests, then compiles the SwiftUI module and app
shell for macOS **and Mac Catalyst**. Catalyst covers the iOS-only code paths (UIKit haptics,
`AVAudioSession`, full-screen covers). It uses only the Command Line Tools. It doesn't build the
`.xcodeproj` or run the app.

## Honest limits

- iOS suspends apps in the background, so live alarms arrive while the app is open. Background refresh catches up only occasionally. For lock-screen alerts when the app is closed, also subscribe to the alert topic in the **ntfy** app.
- The tag has no GPS. Pins are where your **phone** was when the alarm arrived. Find My reports need iPhones passing near the bag and arrive minutes later.
- Find My locations come from the Cloudflare gateway (`backend/cloud-gateway/`), which the laptop uploader feeds every 5 minutes. They stop updating when the laptop or the Find My Docker containers are off.
