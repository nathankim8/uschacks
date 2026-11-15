import Foundation
@testable import TagKit

// Test cases shared by the Swift Testing suite (Xcode / `swift test`) and the
// toolchain-only runner (ios/scripts/verify.sh). `check` is defined by each harness.

final class FakeTransport: TagTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncThrowingStream<NtfyMessage, Error>.Continuation?
    private var _sent: [String] = []
    private var _sinces: [String?] = []
    var failSends = false
    /// Called after each send, e.g. to make the fake tag answer.
    var onSend: (@Sendable (String) -> Void)?

    var sent: [String] { lock.withLock { _sent } }
    var sinces: [String?] { lock.withLock { _sinces } }
    var hasSubscriber: Bool { lock.withLock { continuation != nil } }

    func send(_ line: String) async throws {
        if failSends { throw URLError(.notConnectedToInternet) }
        lock.withLock { _sent.append(line) }
        onSend?(line)
    }

    func reports(since: String?) -> AsyncThrowingStream<NtfyMessage, Error> {
        AsyncThrowingStream { c in
            lock.withLock {
                _sinces.append(since)
                continuation = c
            }
        }
    }

    func push(_ m: NtfyMessage) { _ = lock.withLock { continuation?.yield(m) } }
}

enum Msg {
    static func make(_ text: String, ago: TimeInterval = -1, tags: [String]? = nil, priority: Int? = nil) -> NtfyMessage {
        NtfyMessage(id: UUID().uuidString, time: Int64(Date().timeIntervalSince1970 - ago), message: text,
                           tags: tags, priority: priority)
    }
}

/// Timeouts scaled down 1000x so the 20 s confirmation window takes 20 ms.
let fastSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .milliseconds(Int($0))) }

@MainActor
func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
    let end = Date().addingTimeInterval(timeout)
    while !condition() && Date() < end { try? await Task.sleep(for: .milliseconds(2)) }
}

enum TagKitCases {
    // MARK: Parser

    static func legacyWording() {
        let cases: [(String, TagEvent, TagStatusBits)] = [
            ("ALARM: someone is taking or going through your bag! Siren is on.", .alarm, .init(armed: true, siren: true)),
            ("Armed. Your bag is protected.", .armed, .init(armed: true, siren: false)),
            ("Disarmed.", .disarmed, .init(armed: false, siren: false, lost: false)),
            ("Disarmed. Lost mode off - bag found.", .found, .init(armed: false, siren: false, lost: false)),
            ("Test alert from your Campus Guard Tag.", .test, .init()),
            ("Lost mode ON: Find My beacon starting. The tag checks in about every 3 min.", .lostModeOn, .init(lost: true)),
            ("Lost mode check-in: the tag is near your hotspot. Send FOUND to end lost mode.", .checkIn, .init(lost: true)),
            ("Something new", .info, .init()),
        ]
        for (text, event, status) in cases {
            let r = TagMessageParser.parse(Msg.make(text, tags: ["rotating_light"]))
            check(r.event == event, "\(text) -> \(r.event), expected \(event)")
            check(r.status == status, "\(text) status \(r.status)")
            check(!r.structured, "legacy push must not be structured")
        }
    }

    static func structuredTags() {
        let r = TagMessageParser.parse(Msg.make("Armed. Your bag is protected.",
            tags: ["rotating_light", "cg1", "fw-11", "ev-armed", "rid-ab12", "st-a1s0l0", "boot-normal"], priority: 3))
        check(r.structured)
        check(r.event == .armed)
        check(r.requestID == "ab12")
        check(r.firmware == "11")
        check(r.boot == .normal)
        check(r.status == TagStatusBits(armed: true, siren: false, lost: false))

        let noEvent = TagMessageParser.parse(Msg.make("ALARM: bag moving", tags: ["cg1", "st-a1s1l0"]))
        check(noEvent.event == .alarm, "cg1 push without ev- falls back to text")

        let unknown = TagMessageParser.parse(Msg.make("?", tags: ["cg1", "ev-teleport"]))
        check(unknown.event == .unknown)

        check(TagStatusBits(token: "a1s1l1") == TagStatusBits(armed: true, siren: true, lost: true))
        check(TagStatusBits(token: "a2") == nil)
        check(TagStatusBits(token: "") == nil)
        check(TagStatusBits(token: "x1") == nil)
    }

    static func commands() {
        check(TagCommand.arm.wire() == "ARM")
        check(TagCommand.arm.wire(requestID: "ab12") == "ARM ab12")
        check(TagCommand.ping.confirmingEvents(structured: false) == nil, "v10 PING answers over UDP only")
        check(TagCommand.ping.confirmingEvents(structured: true) == [.status])
        check(TagCommand.disarm.confirmingEvents(structured: false) == [.disarmed, .found])
        check(TagCommand.siren.confirmingEvents(structured: false) == nil)
    }

    // MARK: Snapshot

    static func snapshotTransitions() {
        var s = TagSnapshot()
        check(s.mode == .unknown)
        s.apply(TagMessageParser.parse(Msg.make("Armed. Your bag is protected.", ago: 50)))
        check(s.mode == .alert)
        s.apply(TagMessageParser.parse(Msg.make("ALARM: someone is taking your bag", ago: 40)))
        check(s.mode == .alarm)
        check(s.lastAlarmAt != nil)
        s.apply(TagMessageParser.parse(Msg.make("Lost mode ON: beacon", ago: 30)))
        check(s.lostMode && s.supportsLostMode && s.commandsWaitForCheckIn)
        check(s.nextCheckInEstimate() != nil)
        s.apply(TagMessageParser.parse(Msg.make("Lost mode check-in: near hotspot", ago: 20)))
        check(s.lastCheckInAt != nil)
        // Older push replayed after a newer one must not roll state back.
        s.apply(TagMessageParser.parse(Msg.make("Disarmed.", ago: 300)))
        check(s.lostMode, "stale Disarmed ignored")
        s.apply(TagMessageParser.parse(Msg.make("Disarmed. Lost mode off - bag found.", ago: 10)))
        check(s.mode == .normal && !s.lostMode && !s.sirenOn)
        check(s.supportsLostMode, "capability is remembered")

        var pico = TagSnapshot()
        pico.apply(TagMessageParser.parse(Msg.make("Armed. Your bag is protected.")))
        check(!pico.supportsLostMode, "Pico never shows lost mode UI")
        check(!pico.acceptsRequestIDs)

        var v11 = TagSnapshot()
        v11.apply(TagMessageParser.parse(Msg.make("Status", tags: ["cg1", "fw-11", "ev-status", "st-a0s0l0"])))
        check(v11.acceptsRequestIDs && v11.mode == .normal)
        var v10s = TagSnapshot()
        v10s.apply(TagMessageParser.parse(Msg.make("Status", tags: ["cg1", "fw-10-pico", "ev-status"])))
        check(!v10s.acceptsRequestIDs)
    }

    // MARK: Configuration

    static func configurationParsing() {
        check(TagConfiguration.parse("campusguard-0000demo")?.topic == "campusguard-0000demo")
        let full = TagConfiguration.parse("https://ntfy.sh/campusguard-0000demo-cmd/publish?message=ARM")
        check(full?.topic == "campusguard-0000demo")
        check(full?.server.absoluteString == "https://ntfy.sh")
        let selfHosted = TagConfiguration.parse("ntfy.example.edu:8080/cg-bag")
        check(selfHosted?.server.absoluteString == "https://ntfy.example.edu:8080")
        check(TagConfiguration.parse("bad topic!") == nil)
        check(TagConfiguration.parse("") == nil)
        let c = TagConfiguration(alertTopic: " cg-1 ")
        check(c.commandTopic == "cg-1-cmd" && c.isValid)
        check(!TagConfiguration(alertTopic: "a", commandTopic: "a").isValid)
    }

    // MARK: Find My

    static func findMyDecoding() throws {
        let json = #"{"tag":"CGTAG","fetched_at":1794700000,"count":2,"undecryptable":0,"reports":[{"ts":1794690000,"lat":34.02,"lon":-118.28,"accuracy_m":12,"confidence":2},{"ts":1794695000,"lat":34.03,"lon":-118.29,"accuracy_m":30,"confidence":1}]}"#
        let r = try JSONDecoder().decode(FindMyResponse.self, from: Data(json.utf8))
        check(r.reports.count == 2 && r.tag == "CGTAG")
        let client = FindMyClient(baseURL: URL(string: "http://192.168.1.5:8000")!)
        check(client.endpoint.absoluteString == "http://192.168.1.5:8000/api/locations")
        let direct = FindMyClient(baseURL: URL(string: "https://x.example/api/locations")!)
        check(direct.endpoint.absoluteString == "https://x.example/api/locations")
    }

    // MARK: TagLink

    @MainActor
    static func linkConfirmsOnTagPush() async {
        let fake = FakeTransport()
        let link = TagLink(persistence: InMemoryTagLinkPersistence(), sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        link.start()
        await waitUntil { fake.hasSubscriber }
        fake.onSend = { line in
            if line == "ARM" { fake.push(Msg.make("Armed. Your bag is protected.", ago: 0)) }
        }
        // A stale "Armed." from before the command must not count, so make it old.
        fake.push(Msg.make("Armed. Your bag is protected.", ago: 120))
        let outcome = await link.send(.arm)
        guard case .confirmed(let report) = outcome else { return check(false, "expected confirmed, got \(outcome)") }
        check(report.event == .armed)
        check(fake.sent == ["ARM"])
        check(link.snapshot.mode == .alert)
        check(link.pending == nil)
        check(fake.sinces.first == "1h", "first connect catches up on the last hour")
        link.stop()
    }

    @MainActor
    static func linkTimesOutWithoutAnswer() async {
        let fake = FakeTransport()
        let link = TagLink(persistence: InMemoryTagLinkPersistence(), sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        let outcome = await link.send(.disarm)
        check(outcome == .failed(.noConfirmation), "got \(outcome)")
        check(link.lastFailure == .noConfirmation)
        link.stop()
    }

    @MainActor
    static func linkUnconfirmableAndBusy() async {
        let fake = FakeTransport()
        let link = TagLink(persistence: InMemoryTagLinkPersistence(), sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        let ring = await link.send(.siren)
        check(ring == .sent, "legacy SIREN can't be confirmed")
        check(link.lastSent?.command == .siren)

        let first = Task { await link.send(.arm) }
        await waitUntil { link.pending != nil }
        let second = await link.send(.disarm)
        check(second == .failed(.busy))
        _ = await first.value

        fake.failSends = true
        let offline = await link.send(.stop)
        check(offline == .failed(.network))
        link.stop()
    }

    @MainActor
    static func linkMatchesRequestIDs() async {
        let fake = FakeTransport()
        let link = TagLink(persistence: InMemoryTagLinkPersistence(), sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        link.start()
        await waitUntil { fake.hasSubscriber }
        fake.push(Msg.make("Status", ago: 30, tags: ["cg1", "fw-11", "ev-status", "st-a0s0l0"]))
        await waitUntil { link.snapshot.acceptsRequestIDs }
        fake.onSend = { line in
            let rid = line.split(separator: " ").last.map(String.init) ?? ""
            // Someone else's DISARM answer first, then ours.
            fake.push(Msg.make("Disarmed.", ago: 0, tags: ["cg1", "fw-11", "ev-disarmed", "rid-zzzz", "st-a0s0l0"]))
            fake.push(Msg.make("Disarmed.", ago: 0, tags: ["cg1", "fw-11", "ev-disarmed", "rid-\(rid)", "st-a0s0l0"]))
        }
        let outcome = await link.send(.disarm)
        guard case .confirmed(let r) = outcome else { return check(false, "expected confirmed, got \(outcome)") }
        check(r.requestID != "zzzz", "confirmation matched by request id")
        check(fake.sent.first?.hasPrefix("DISARM ") == true, "v11 gets a request id: \(fake.sent)")
        // v11 confirms PING with a status push.
        fake.onSend = { line in
            let rid = line.split(separator: " ").last.map(String.init) ?? ""
            fake.push(Msg.make("Status: normal.", ago: 0, tags: ["cg1", "fw-11", "ev-status", "rid-\(rid)", "st-a0s0l0"]))
        }
        let ping = await link.send(.ping)
        if case .confirmed = ping {} else { check(false, "PING should be confirmed on v11, got \(ping)") }
        link.stop()
    }

    @MainActor
    static func linkPersistsAndDedupes() async {
        let store = InMemoryTagLinkPersistence()
        let fake = FakeTransport()
        let link = TagLink(persistence: store, sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        link.start()
        await waitUntil { fake.hasSubscriber }
        let m = Msg.make("Lost mode ON: beacon", ago: 0)
        fake.push(m)
        fake.push(m)
        await waitUntil { !link.history.isEmpty }
        try? await Task.sleep(for: .milliseconds(20))
        check(link.history.count == 1, "duplicate ids dropped")
        check(link.snapshot.commandsWaitForCheckIn)
        link.stop()

        let reopened = TagLink(persistence: store, sleep: fastSleep)
        reopened.configure(transport: FakeTransport(), topic: "t")
        check(reopened.snapshot.lostMode, "snapshot restored")
        check(reopened.history.count == 1)
        let other = TagLink(persistence: store, sleep: fastSleep)
        other.configure(transport: FakeTransport(), topic: "different")
        check(other.history.isEmpty, "another topic starts clean")

        // Resume from the saved cursor.
        let fake2 = FakeTransport()
        let resumed = TagLink(persistence: store, sleep: fastSleep)
        resumed.configure(transport: fake2, topic: "t")
        resumed.start()
        await waitUntil { fake2.hasSubscriber }
        check(fake2.sinces.first == m.id, "reconnect resumes after the last id")
        resumed.stop()
    }

    @MainActor
    static func linkCatchUpDoesNotConfirm() async {
        let fake = FakeTransport()
        var catchUps: [Bool] = []
        let link = TagLink(persistence: InMemoryTagLinkPersistence(), sleep: fastSleep)
        link.configure(transport: fake, topic: "t")
        link.onReport = { _, catchUp in catchUps.append(catchUp) }
        link.start()
        await waitUntil { fake.hasSubscriber }
        fake.push(Msg.make("ALARM: old", ago: 3600))
        fake.push(Msg.make("ALARM: new", ago: 0))
        await waitUntil { catchUps.count == 2 }
        check(catchUps == [true, false], "\(catchUps)")
        link.stop()
    }
}
