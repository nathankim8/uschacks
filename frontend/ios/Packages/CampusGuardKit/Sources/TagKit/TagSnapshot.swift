import Foundation

/// What the tag is doing, as far as the app can tell from its pushes.
public enum TagMode: String, Sendable, Codable {
    case unknown, normal, alert, alarm
}

/// The app's best knowledge of the tag, rebuilt from its pushes. Pure value type: easy to test.
public struct TagSnapshot: Equatable, Sendable, Codable {
    public var armed: Bool?
    public var sirenOn = false
    public var lostMode = false
    public var lostModeSince: Date?
    public var lastReportAt: Date?
    public var lastCheckInAt: Date?
    public var lastAlarmAt: Date?
    public var firmware: String?
    /// The tag has sent `cg1` machine tags.
    public var structured = false
    /// The tag has shown it has a lost mode (ESP32 tag_lostmode). The Pico tag never does,
    /// so the app hides LOSTMODE/FOUND for it.
    public var supportsLostMode = false
    /// Trigger mode the tag last reported: true = automatic siren, false = manual, nil = unknown
    /// (firmware before the trigger feature always behaves as automatic).
    public var automaticTrigger: Bool?

    public init() {}

    public var mode: TagMode {
        if sirenOn && armed != false { return .alarm }
        switch armed {
        case .some(true): return .alert
        case .some(false): return .normal
        case .none: return .unknown
        }
    }

    /// Firmware that understands `VERB rid` (v11+).
    public var acceptsRequestIDs: Bool {
        guard structured, let firmware else { return false }
        let major = Int(firmware.prefix { $0.isNumber }) ?? 0
        return major >= 11
    }

    /// Lost mode on the ESP32 tag: Wi-Fi is off and commands are only picked up at check-ins.
    public var commandsWaitForCheckIn: Bool { lostMode && supportsLostMode }

    /// When the next lost-mode check-in should happen (tag_lostmode: every ~3 min + boot time).
    public func nextCheckInEstimate(interval: TimeInterval = TagTiming.checkInInterval) -> Date? {
        guard commandsWaitForCheckIn else { return nil }
        let base = [lastCheckInAt, lostModeSince].compactMap { $0 }.max()
        return base?.addingTimeInterval(interval)
    }

    public mutating func apply(_ report: TagReport) {
        if let firmware = report.firmware { self.firmware = firmware }
        if report.structured { structured = true }
        if report.event == .lostModeOn || report.event == .checkIn || report.boot == .checkin {
            supportsLostMode = true
        }

        // Out-of-order history (e.g. catch-up after a reconnect) must not roll state back.
        if let last = lastReportAt, report.date < last.addingTimeInterval(-1) { return }
        lastReportAt = report.date

        if let a = report.status.armed { armed = a }
        if let s = report.status.siren { sirenOn = s }
        if let l = report.status.lost { setLost(l, at: report.date) }

        switch report.event {
        case .alarm:
            if report.status.siren == nil { sirenOn = true }
            if armed == nil { armed = true }
            lastAlarmAt = report.date
        case .armed:
            armed = true
            if report.status.siren == nil { sirenOn = false }
        case .disarmed, .found:
            armed = false
            sirenOn = false
            setLost(false, at: report.date)
        case .lostModeOn:
            setLost(true, at: report.date)
        case .checkIn:
            setLost(true, at: report.date)
            lastCheckInAt = report.date
        case .stop:
            if report.status.siren == nil { sirenOn = false }
        case .siren:
            if report.status.siren == nil { sirenOn = true }
        case .trigger:
            automaticTrigger = report.text.lowercased().contains("automatic")
        case .status, .test, .chirp, .wifiBack, .boot, .unknown, .info:
            break
        }
    }

    private mutating func setLost(_ on: Bool, at date: Date) {
        if on && !lostMode { lostModeSince = date }
        if !on { lostModeSince = nil }
        lostMode = on
        if on { supportsLostMode = true }
    }
}

public enum TagTiming {
    /// Tag polls the command topic every 6 s; the push back takes a few seconds more.
    public static let confirmTimeout: TimeInterval = 20
    /// tag_lostmode: beacon for 3 min, then a ~20 s check-in window (+ boot + Wi-Fi join).
    public static let checkInInterval: TimeInterval = 200
    /// Wait for a check-in plus margin before giving up on a lost-mode command.
    public static let checkInTimeout: TimeInterval = 270
    /// An ALARM older than this is history, not a new alarm, when the app opens.
    public static let freshAlarmWindow: TimeInterval = 10 * 60
}
