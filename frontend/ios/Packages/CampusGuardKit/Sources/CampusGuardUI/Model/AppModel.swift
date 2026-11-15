import Foundation
import Observation
import CoreLocation
import TagKit

public enum AlertTrigger: String, Codable, CaseIterable, Sendable {
    /// The phone plays its siren as soon as an alarm arrives.
    case automatic
    /// The red screen opens silently; tap the bell to play the phone siren.
    case manual
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var trigger: AlertTrigger = .automatic
    public var phoneSound = true
    public var trojanNetwork = true
    public init() {}
}

/// Where the owner's PHONE was when an alarm arrived (the tag has no GPS).
public struct AlertPin: Codable, Equatable, Identifiable, Sendable {
    public var id = UUID()
    public var date: Date
    public var latitude: Double
    public var longitude: Double
    public var accuracy: Double
    public var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

/// An open alarm or lost report: the red (active) and white (passive tracking) screens.
public struct Incident: Codable, Equatable, Sendable {
    public enum Reason: String, Codable, Sendable { case motion, lost }
    public enum Page: String, Codable, Sendable, Hashable { case red, white }
    public var reason: Reason
    public var startedAt: Date
    public var page: Page
}

@MainActor
@Observable
public final class AppModel {
    public static let shared = AppModel()

    public enum Phase: Equatable { case welcome, ready }

    public let link: TagLink
    public var phase: Phase = .welcome
    public private(set) var configuration: TagConfiguration?
    /// False when the user chose "Continue without the tag" (the app then works on its own).
    public var tagLinked = false
    public var settings: AppSettings { didSet { persistSettings() } }
    public private(set) var incident: Incident? { didSet { persistIncident() } }
    public private(set) var pins: [AlertPin] { didSet { persistPins() } }
    /// Mode used when no tag is linked.
    public private(set) var localArmed = false
    public private(set) var phoneSirenOn = false
    public var banner: Banner?

    public private(set) var findMy = FindMyState()

    public struct Banner: Equatable, Identifiable {
        public enum Tone { case info, warning, error }
        public let id = UUID()
        public var text: String
        public var tone: Tone
    }

    public struct FindMyState: Equatable {
        public var reports: [FindMyReport] = []
        public var loading = false
        public var error: String?
        public var fetchedAt: Date?
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private var handledAlarmID: String? {
        get { defaults.string(forKey: Keys.handledAlarm) }
        set { defaults.set(newValue, forKey: Keys.handledAlarm) }
    }

    private enum Keys {
        static let settings = "cg.settings.v1"
        static let incident = "cg.incident.v1"
        static let pins = "cg.pins.v1"
        static let handledAlarm = "cg.handledAlarm.v1"
        static let configuration = "configuration.v1"
    }

    public init(link: TagLink = TagLink(), defaults: UserDefaults = .standard) {
        self.link = link
        self.defaults = defaults
        settings = Self.decode(AppSettings.self, defaults.data(forKey: Keys.settings)) ?? AppSettings()
        incident = Self.decode(Incident.self, defaults.data(forKey: Keys.incident))
        pins = Self.decode([AlertPin].self, defaults.data(forKey: Keys.pins)) ?? []
        configuration = SecureStore.load(TagConfiguration.self, Keys.configuration) ?? Self.bundledConfiguration()
        link.onReport = { [weak self] report, catchUp in self?.handle(report, catchUp: catchUp) }
        applyConfiguration()
    }

    // MARK: Derived state

    public var isConfigured: Bool { configuration?.isValid == true }
    /// Commands go to the real tag.
    public var usesTag: Bool { isConfigured && tagLinked }
    public var snapshot: TagSnapshot { link.snapshot }

    public var mode: TagMode {
        if usesTag { return link.snapshot.mode }
        if incident?.reason == .motion { return .alarm }
        return localArmed ? .alert : .normal
    }

    public var isProtected: Bool { mode == .alert || mode == .alarm }
    public var lostModeAvailable: Bool { usesTag && link.snapshot.supportsLostMode }
    public var busy: Bool { link.pending != nil }

    // MARK: Configuration

    /// Debug/TestFlight builds can embed a topic through Info.plist (CG_NTFY_TOPIC in Secrets.xcconfig).
    static func bundledConfiguration() -> TagConfiguration? {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let topic = (info["CGNtfyTopic"] as? String)?.trimmingCharacters(in: .whitespaces),
              TagConfiguration.isValidTopic(topic) else { return nil }
        let server = (info["CGNtfyServer"] as? String).flatMap(URL.init(string:)) ?? TagConfiguration.defaultServer
        let findMy = (info["CGFindMyURL"] as? String).flatMap { $0.isEmpty ? nil : URL(string: $0) }
        let findMyToken = (info["CGFindMyToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return TagConfiguration(server: server, alertTopic: topic, findMyURL: findMy, findMyToken: findMyToken)
    }

    public func updateConfiguration(_ config: TagConfiguration?) {
        configuration = config
        SecureStore.save(config, Keys.configuration)
        findMy = FindMyState()
        applyConfiguration()
    }

    private func applyConfiguration() {
        if let configuration, configuration.isValid {
            link.configure(transport: NtfyTransport(configuration: configuration), topic: configuration.alertTopic)
        } else {
            link.configure(transport: nil, topic: nil)
            tagLinked = false
        }
    }

    // MARK: Lifecycle

    public func becameActive() {
        Notifier.shared.activate()
        if isConfigured { link.start() }
    }

    public func enteredBackground() {
        link.stop()
        if !phoneSirenOn { SirenPlayer.shared.stop() }
    }

    /// One catch-up read while in the background (BGAppRefresh). Never loops.
    public func backgroundRefresh() async {
        guard let configuration, configuration.isValid else { return }
        let client = NtfyClient(server: configuration.server, accessToken: configuration.accessToken)
        guard let messages = try? await client.poll(configuration.alertTopic, since: link.cursor ?? "1h") else { return }
        for message in messages.sorted(by: { $0.time < $1.time }) { link.ingest(message) }
    }

    // MARK: Onboarding

    /// Connect screen: a real round trip. PUSHTEST makes the tag push "Test alert…" without beeping.
    public func connect() async -> TagLink.Outcome {
        guard isConfigured else { return .failed(.notConfigured) }
        link.start()
        // ESP32 lost mode: the tag is offline for minutes, so don't block setup on it.
        if link.snapshot.commandsWaitForCheckIn {
            finishSetup(linked: true)
            return .sent
        }
        let outcome = await link.send(.pushTest)
        if case .confirmed = outcome { finishSetup(linked: true) }
        return outcome
    }

    public func finishSetup(linked: Bool) {
        tagLinked = linked && isConfigured
        phase = .ready
        // Setup always lands on Home; an alarm that is still sounding re-opens itself below.
        if tagLinked, link.snapshot.mode == .alarm, let at = link.snapshot.lastAlarmAt,
           Date().timeIntervalSince(at) < TagTiming.freshAlarmWindow {
            openIncident(.motion, page: .red)
        }
    }

    public func restartSetup() {
        stopPhoneSiren()
        tagLinked = false
        phase = .welcome
    }

    // MARK: Tag events

    private func handle(_ report: TagReport, catchUp: Bool) {
        guard tagLinked else { return }
        switch report.event {
        case .alarm:
            let fresh = Date().timeIntervalSince(report.date) < TagTiming.freshAlarmWindow
            guard handledAlarmID != report.id, !catchUp || fresh else { return }
            handledAlarmID = report.id
            onAlarm(report)
        case .disarmed, .found:
            if !catchUp { closeIncident() }
        case .lostModeOn:
            if !catchUp {
                if incident == nil { openIncident(.lost, page: .white) }
                Notifier.shared.post("Lost mode on", "Your tag switched to its Find My beacon and checks in about every 3 minutes.", kind: .lost)
            }
        case .checkIn:
            if !catchUp, report.status.siren == true || link.snapshot.sirenOn {
                Notifier.shared.post("Your bag checked in", "Lost mode is still on and the tag's siren is sounding.", kind: .lost)
            }
        case .wifiBack, .boot:
            if !catchUp, report.status.siren == true {
                Notifier.shared.post("Your tag is back online", "Its siren is on. Open Campus Guard to stop it.", kind: .alarm)
            }
        default:
            break
        }
    }

    private func onAlarm(_ report: TagReport) {
        openIncident(.motion, page: .red)
        Haptics.alarm()
        Notifier.shared.post("Campus Guard: ALARM",
                             settings.trigger == .manual
                                ? "Someone is taking or going through your bag. Open to sound the alarm on your phone."
                                : "Someone is taking or going through your bag! The tag's siren is on.",
                             kind: .alarm, id: "alarm-\(report.id)")
        if settings.trigger == .automatic && settings.phoneSound { startPhoneSiren() }
        Task { await dropPin(at: report.date) }
    }

    private func dropPin(at date: Date) async {
        guard let location = await LocationService.shared.currentLocation() else { return }
        pins.insert(AlertPin(date: date, latitude: location.coordinate.latitude,
                             longitude: location.coordinate.longitude,
                             accuracy: location.horizontalAccuracy), at: 0)
        if pins.count > 50 { pins.removeLast(pins.count - 50) }
    }

    // MARK: Incident

    public func openIncident(_ reason: Incident.Reason, page: Incident.Page) {
        if var current = incident {
            current.page = page
            if reason == .motion { current.reason = .motion }
            incident = current
        } else {
            incident = Incident(reason: reason, startedAt: Date(), page: page)
        }
    }

    public func show(_ page: Incident.Page) {
        incident?.page = page
        if page == .white { stopPhoneSiren() }
    }

    private func closeIncident() {
        stopPhoneSiren()
        incident = nil
        Notifier.shared.clearAlarms()
    }

    /// Close the alarm on this phone only (when the tag can't be reached).
    public func dismissLocally() {
        closeIncident()
        localArmed = false
    }

    // MARK: Phone siren

    public func startPhoneSiren() {
        SirenPlayer.shared.start()
        phoneSirenOn = true
    }

    public func stopPhoneSiren() {
        SirenPlayer.shared.stop()
        phoneSirenOn = false
    }

    public func togglePhoneSiren() {
        phoneSirenOn ? stopPhoneSiren() : startPhoneSiren()
    }

    // MARK: User actions

    public func setProtected(_ on: Bool) async {
        guard usesTag else {
            localArmed = on
            on ? Haptics.success() : Haptics.tap()
            return
        }
        await run(on ? .arm : .disarm)
    }

    /// "It's me" on the red screen: stop the tag's siren (DISARM), close once it confirms.
    public func itsMe() async {
        stopPhoneSiren()
        guard usesTag else { return closeIncident() }
        await run(.disarm)
    }

    /// Mark as lost: open tracking. On the ESP32 tag this also starts its lost mode (Find My beacon).
    /// The Pico tag's beacon is always on, so it only needs tracking.
    public func markLost(startTagLostMode: Bool) async {
        openIncident(.lost, page: .white)
        guard startTagLostMode, lostModeAvailable, !link.snapshot.lostMode else { return }
        await run(.lostMode)
    }

    public func found() async {
        stopPhoneSiren()
        guard usesTag else { return closeIncident() }
        let snap = link.snapshot
        if snap.lostMode && snap.supportsLostMode {
            await run(.found)
        } else if snap.armed != false || snap.sirenOn {
            await run(.disarm)
        } else {
            closeIncident()
        }
        closeIncident()
    }

    public func ring(_ on: Bool) async {
        guard usesTag else { return on ? SirenPlayer.shared.start(nearby: true) : SirenPlayer.shared.stop() }
        await run(on ? .siren : .stop)
    }

    public func run(_ command: TagCommand) async {
        let outcome = await link.send(command)
        switch outcome {
        case .confirmed(let report):
            Haptics.success()
            if report.event == .disarmed || report.event == .found { closeIncident() }
            banner = nil
        case .sent:
            banner = Banner(text: sentText(command), tone: .info)
        case .failed(let failure):
            Haptics.warning()
            banner = Banner(text: failureText(failure, command), tone: failure == .busy ? .warning : .error)
        }
    }

    public func sentText(_ command: TagCommand) -> String {
        let wait = link.snapshot.commandsWaitForCheckIn ? " It reaches the tag at its next check-in (≤ 3 min)." : ""
        switch command {
        case .siren: return "Sent. Listen for your bag's siren (up to ~7 s).\(wait)"
        case .stop: return "Sent stop.\(wait)"
        case .chirp: return "Sent. Listen for three short beeps.\(wait)"
        case .test: return "Sent. The tag beeps once for a second.\(wait)"
        case .ping: return "Sent. This tag answers PING on USB only."
        default: return "Sent.\(wait)"
        }
    }

    public func failureText(_ failure: TagLink.Failure, _ command: TagCommand) -> String {
        switch failure {
        case .notConfigured: return "No tag is set up. Add your tag in Settings › Connection."
        case .busy: return "Still waiting for the tag to answer the last command."
        case .network: return "Couldn't reach ntfy. Check your internet connection."
        case .unauthorized: return "ntfy refused the topic. Check the access token in Settings › Connection."
        case .rateLimited: return "ntfy is rate-limiting this network. Try again in a minute."
        case .noConfirmation:
            return link.snapshot.commandsWaitForCheckIn
                ? "No check-in yet. The tag may be out of hotspot range; the command stays queued on ntfy."
                : "The tag didn't answer. Is it powered on and on the hotspot?"
        }
    }

    // MARK: Find My

    public var findMyConfigured: Bool { configuration?.findMyURL != nil && settings.trojanNetwork }

    public func refreshFindMy() async {
        guard let url = configuration?.findMyURL, !findMy.loading else { return }
        findMy.loading = true
        findMy.error = nil
        do {
            let response = try await FindMyClient(baseURL: url, token: configuration?.findMyToken).locations()
            findMy.reports = response.reports
            findMy.fetchedAt = Date()
        } catch let error as FindMyError {
            findMy.error = switch error {
            case .server(let msg): msg
            case .http(401), .http(403): "The Find My helper refused the token."
            case .http(let code): "Find My helper error (HTTP \(code))."
            case .notConfigured: "Find My isn't set up."
            }
        } catch {
            findMy.error = "Couldn't reach the Find My helper. Is it running and reachable from this phone?"
        }
        findMy.loading = false
    }

    // MARK: Persistence

    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data?) -> T? {
        data.flatMap { try? JSONDecoder().decode(T.self, from: $0) }
    }

    private func persistSettings() { defaults.set(try? JSONEncoder().encode(settings), forKey: Keys.settings) }
    private func persistIncident() { defaults.set(incident.flatMap { try? JSONEncoder().encode($0) }, forKey: Keys.incident) }
    private func persistPins() { defaults.set(try? JSONEncoder().encode(pins), forKey: Keys.pins) }

    public func clearPins() { pins = [] }
}
