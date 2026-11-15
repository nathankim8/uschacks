import Foundation

// Campus Guard tag <-> app contract. See docs/TAG_PROTOCOL.md.
//
// Transport: ntfy.sh. The app POSTs one command per message to `<topic>-cmd`; the tag
// publishes human-readable pushes to `<topic>`. Firmware v9 / v10-pico / v10 (ESP32 lost
// mode) are matched by message text. Firmware that adds the `cg1` tag (proposed v11) is
// read from its machine tags instead, and gets request ids for exact confirmation.

/// A command the app can send to the tag.
public enum TagCommand: String, CaseIterable, Sendable, Codable {
    case arm = "ARM"
    case disarm = "DISARM"
    case lostMode = "LOSTMODE"
    case found = "FOUND"
    case pushTest = "PUSHTEST"
    case test = "TEST"
    case stop = "STOP"
    case siren = "SIREN"
    case chirp = "CHIRP"
    case ping = "PING"

    /// Text POSTed to the command topic. Request ids are only sent to firmware that
    /// understands them (v10 and earlier treat "ARM ab12" as an unknown command).
    public func wire(requestID: String? = nil) -> String {
        guard let requestID, !requestID.isEmpty else { return rawValue }
        return "\(rawValue) \(requestID)"
    }

    /// Events that confirm this command, or nil when the firmware can't confirm it.
    public func confirmingEvents(structured: Bool) -> Set<TagEvent>? {
        switch self {
        case .arm: return [.armed]
        case .disarm, .found: return [.disarmed, .found]
        case .lostMode: return structured ? [.lostModeOn, .status] : [.lostModeOn]
        case .pushTest: return [.test]
        case .test: return structured ? [.test] : nil
        case .ping: return structured ? [.status] : nil
        case .chirp: return structured ? [.chirp] : nil
        case .siren: return structured ? [.siren] : nil
        case .stop: return structured ? [.stop] : nil
        }
    }
}

/// What a push from the tag means.
public enum TagEvent: String, Sendable, Codable, CaseIterable {
    case armed, disarmed, found, alarm
    case lostModeOn = "lost_on"
    case checkIn = "checkin"
    case status, test, chirp, siren, stop
    case wifiBack = "wifi_back"
    case boot, unknown
    /// Text the app could not classify (still shown in the activity log).
    case info
}

/// Partial machine state carried by a push. `nil` = this push doesn't say.
public struct TagStatusBits: Equatable, Sendable, Codable {
    public var armed: Bool?
    public var siren: Bool?
    public var lost: Bool?

    public init(armed: Bool? = nil, siren: Bool? = nil, lost: Bool? = nil) {
        self.armed = armed
        self.siren = siren
        self.lost = lost
    }

    /// Parses the v11 `st-a1s0l0` token body (`a1s0l0`). Unknown letters are ignored.
    public init?(token: String) {
        var bits = TagStatusBits()
        var chars = Array(token.lowercased())
        guard chars.count >= 2 else { return nil }
        var found = false
        while chars.count >= 2 {
            let key = chars.removeFirst()
            let value = chars.removeFirst()
            guard value == "0" || value == "1" else { return nil }
            let on = value == "1"
            switch key {
            case "a": bits.armed = on; found = true
            case "s": bits.siren = on; found = true
            case "l": bits.lost = on; found = true
            default: break
            }
        }
        guard found else { return nil }
        self = bits
    }
}

public enum TagBootKind: String, Sendable, Codable {
    case normal, checkin, beacon
}

/// One push from the tag, classified.
public struct TagReport: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let date: Date
    public let event: TagEvent
    public let status: TagStatusBits
    public let text: String
    /// ntfy priority 1 (min) ... 5 (urgent).
    public let priority: Int
    /// True when the push carried the `cg1` machine tags.
    public let structured: Bool
    public let requestID: String?
    public let firmware: String?
    public let boot: TagBootKind?

    public init(id: String, date: Date, event: TagEvent, status: TagStatusBits = .init(), text: String,
                priority: Int = 3, structured: Bool = false, requestID: String? = nil,
                firmware: String? = nil, boot: TagBootKind? = nil) {
        self.id = id
        self.date = date
        self.event = event
        self.status = status
        self.text = text
        self.priority = priority
        self.structured = structured
        self.requestID = requestID
        self.firmware = firmware
        self.boot = boot
    }
}

public enum TagMessageParser {
    public static let protocolTag = "cg1"

    public static func parse(_ message: NtfyMessage) -> TagReport {
        let text = (message.message ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (message.tags ?? []).map { $0.lowercased() }
        let priority = message.priority ?? 3
        let date = Date(timeIntervalSince1970: TimeInterval(message.time))

        if tags.contains(protocolTag) {
            var event: TagEvent?
            var status = TagStatusBits()
            var rid: String?
            var firmware: String?
            var boot: TagBootKind?
            for tag in tags {
                if let v = tag.dropPrefix("ev-") { event = TagEvent(rawValue: v) ?? .unknown }
                else if let v = tag.dropPrefix("st-") { status = TagStatusBits(token: v) ?? status }
                else if let v = tag.dropPrefix("rid-") { rid = v }
                else if let v = tag.dropPrefix("fw-") { firmware = v }
                else if let v = tag.dropPrefix("boot-") { boot = TagBootKind(rawValue: v) }
            }
            // A cg1 push without an ev- tag still gets classified from its text.
            let resolved = event ?? classify(text).event
            return TagReport(id: message.id, date: date, event: resolved, status: status, text: text,
                             priority: priority, structured: true, requestID: rid, firmware: firmware, boot: boot)
        }

        let legacy = classify(text)
        return TagReport(id: message.id, date: date, event: legacy.event, status: legacy.status, text: text,
                         priority: priority, structured: false)
    }

    /// Wording used by firmware v9, v10-pico and tag_lostmode v10. Prefix match, case-insensitive,
    /// so small wording changes after the first word keep working.
    public static func classify(_ text: String) -> (event: TagEvent, status: TagStatusBits) {
        let m = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if m.hasPrefix("alarm") { return (.alarm, .init(armed: true, siren: true)) }
        if m.hasPrefix("armed") { return (.armed, .init(armed: true, siren: false)) }
        if m.hasPrefix("disarmed") {
            if m.contains("lost mode off") || m.contains("found") {
                return (.found, .init(armed: false, siren: false, lost: false))
            }
            // v10 DISARM also ends lost mode, so a plain "Disarmed." means lost mode is off.
            return (.disarmed, .init(armed: false, siren: false, lost: false))
        }
        if m.hasPrefix("test alert") { return (.test, .init()) }
        if m.hasPrefix("lost mode on") { return (.lostModeOn, .init(lost: true)) }
        if m.hasPrefix("lost mode check-in") || m.hasPrefix("lost mode check in") {
            return (.checkIn, .init(lost: true))
        }
        return (.info, .init())
    }
}

extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
