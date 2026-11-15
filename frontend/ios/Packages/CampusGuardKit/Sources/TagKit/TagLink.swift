import Foundation
import Observation

/// The live link to the tag: one ntfy stream in, one command at a time out.
///
/// - The UI changes state only when the tag confirms (its push arrives), never optimistically.
/// - One command at a time: older firmware runs only the last command in each 6 s poll.
/// - In ESP32 lost mode, commands wait for the next check-in (~3 min), so the wait is longer.
@MainActor
@Observable
public final class TagLink {
    public enum StreamState: Equatable, Sendable { case off, connecting, live, reconnecting }

    public struct Pending: Equatable, Sendable {
        public let command: TagCommand
        public let sentAt: Date
        public let requestID: String?
        public let deadline: Date
        /// The tag is in lost mode: it reads commands only at its next check-in.
        public let waitsForCheckIn: Bool
    }

    public struct Sent: Equatable, Sendable {
        public let command: TagCommand
        public let at: Date
    }

    public enum Failure: Error, Equatable, Sendable {
        case notConfigured, busy, network, unauthorized, rateLimited, noConfirmation
    }

    public enum Outcome: Equatable, Sendable {
        /// The tag answered with this push.
        case confirmed(TagReport)
        /// Delivered to ntfy; this firmware can't confirm the command, so listen for the tag.
        case sent
        case failed(Failure)
    }

    /// `catchUp` = the push is older than this connection (history replayed on connect).
    public typealias ReportHandler = @MainActor (TagReport, _ catchUp: Bool) -> Void

    public private(set) var stream: StreamState = .off
    public private(set) var snapshot = TagSnapshot()
    public private(set) var history: [TagReport] = []
    public private(set) var pending: Pending?
    public private(set) var lastSent: Sent?
    public private(set) var lastFailure: Failure?
    public private(set) var isConfigured = false

    @ObservationIgnored public var onReport: ReportHandler?

    @ObservationIgnored private var transport: TagTransport?
    @ObservationIgnored private var persistence: TagLinkPersistence
    @ObservationIgnored private var memory: TagLinkMemory?
    @ObservationIgnored private var streamTask: Task<Void, Never>?
    @ObservationIgnored private var waiter: CheckedContinuation<Outcome, Never>?
    @ObservationIgnored private var timeoutTask: Task<Void, Never>?
    @ObservationIgnored private var seen = Set<String>()
    @ObservationIgnored private var connectedAt = Date.distantPast
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let sleep: @Sendable (TimeInterval) async throws -> Void
    @ObservationIgnored private let historyLimit = 300

    public init(persistence: TagLinkPersistence = FileTagLinkPersistence(),
                now: @escaping @Sendable () -> Date = Date.init,
                sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }) {
        self.persistence = persistence
        self.now = now
        self.sleep = sleep
    }

    // MARK: Configuration and lifecycle

    /// Points the link at a tag. A different topic starts with a clean history.
    public func configure(transport: TagTransport?, topic: String?) {
        stop()
        cancelPending(with: .failed(.notConfigured))
        self.transport = transport
        isConfigured = transport != nil
        guard let topic, transport != nil else {
            memory = nil
            snapshot = TagSnapshot()
            history = []
            return
        }
        let saved = persistence.load()
        memory = saved?.topic == topic ? saved! : TagLinkMemory(topic: topic)
        snapshot = memory!.snapshot
        history = memory!.history
        seen = Set(history.map(\.id))
    }

    /// Opens the stream (idempotent). Call when the app becomes active.
    public func start() {
        guard transport != nil, streamTask == nil else { return }
        streamTask = Task { [weak self] in await self?.runStream() }
    }

    /// Closes the stream. Call when the app goes to the background (iOS would suspend it anyway).
    public func stop() {
        streamTask?.cancel()
        streamTask = nil
        if stream != .off { stream = .off }
    }

    /// Last ntfy id seen (for a one-shot background catch-up).
    public var cursor: String? { memory?.cursor }

    public func clearHistory() {
        history = []
        memory?.history = []
        save()
    }

    private func runStream() async {
        var attempt = 0
        while !Task.isCancelled, let transport {
            stream = attempt == 0 ? .connecting : .reconnecting
            connectedAt = now()
            // First launch: catch up on the last hour so the app knows the tag's current state.
            let since = memory?.cursor ?? "1h"
            do {
                for try await message in transport.reports(since: since) {
                    if Task.isCancelled { break }
                    if stream != .live { stream = .live }
                    attempt = 0
                    if message.isMessage { ingest(message) }
                }
            } catch {
                if let e = error as? NtfyError, e == .unauthorized { lastFailure = .unauthorized }
            }
            if Task.isCancelled { break }
            attempt += 1
            stream = .reconnecting
            let backoff = min(30, pow(2, Double(min(attempt, 5)))) * Double.random(in: 0.8...1.2)
            do { try await sleep(backoff) } catch { break }
        }
        if !Task.isCancelled { stream = .off }
    }

    // MARK: Incoming

    /// Feeds one ntfy message through the protocol (also used by background refresh).
    @discardableResult
    public func ingest(_ message: NtfyMessage) -> TagReport? {
        guard message.isMessage, !seen.contains(message.id) else { return nil }
        seen.insert(message.id)
        let report = TagMessageParser.parse(message)
        let catchUp = report.date < connectedAt.addingTimeInterval(-5)

        snapshot.apply(report)
        history.insert(report, at: 0)
        if history.count > historyLimit { history.removeLast(history.count - historyLimit) }
        memory?.cursor = message.id
        memory?.snapshot = snapshot
        memory?.history = history
        save()

        if !catchUp { resolvePending(with: report) }
        onReport?(report, catchUp)
        return report
    }

    private func resolvePending(with report: TagReport) {
        guard let pending,
              let events = pending.command.confirmingEvents(structured: snapshot.structured),
              events.contains(report.event) else { return }
        if let rid = pending.requestID {
            guard report.requestID == rid else { return }
        } else {
            // ntfy times are whole seconds.
            guard report.date >= pending.sentAt.addingTimeInterval(-2) else { return }
        }
        finish(.confirmed(report))
    }

    // MARK: Outgoing

    /// Sends a command and waits for the tag's answer when the firmware can give one.
    public func send(_ command: TagCommand) async -> Outcome {
        guard let transport else { return .failed(.notConfigured) }
        guard pending == nil else { return .failed(.busy) }
        start()

        let structured = snapshot.structured
        let rid = snapshot.acceptsRequestIDs ? Self.makeRequestID() : nil
        let line = command.wire(requestID: rid)
        let sentAt = now()
        let confirmable = command.confirmingEvents(structured: structured) != nil

        lastFailure = nil
        if !confirmable {
            do {
                try await transport.send(line)
                lastSent = Sent(command: command, at: sentAt)
                return .sent
            } catch {
                return fail(Self.failure(for: error))
            }
        }

        let waits = snapshot.commandsWaitForCheckIn
        let timeout = waits ? TagTiming.checkInTimeout : TagTiming.confirmTimeout
        pending = Pending(command: command, sentAt: sentAt, requestID: rid,
                          deadline: sentAt.addingTimeInterval(timeout), waitsForCheckIn: waits)

        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            waiter = continuation
            timeoutTask = Task { [weak self, sleep] in
                try? await sleep(timeout)
                guard !Task.isCancelled else { return }
                self?.finish(.failed(.noConfirmation))
            }
            Task { [weak self] in
                do {
                    try await transport.send(line)
                    self?.lastSent = Sent(command: command, at: sentAt)
                } catch {
                    self?.finish(.failed(Self.failure(for: error)))
                }
            }
        }
    }

    /// Stops waiting for the current command (the command itself may still reach the tag).
    public func cancelPending(with outcome: Outcome = .failed(.noConfirmation)) {
        finish(outcome)
    }

    private func finish(_ outcome: Outcome) {
        guard let waiter else { return }
        self.waiter = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        pending = nil
        if case .failed(let f) = outcome { lastFailure = f } else { lastFailure = nil }
        waiter.resume(returning: outcome)
    }

    private func fail(_ failure: Failure) -> Outcome {
        lastFailure = failure
        return .failed(failure)
    }

    private func save() {
        if let memory { persistence.save(memory) }
    }

    static func failure(for error: Error) -> Failure {
        switch error as? NtfyError {
        case .unauthorized?: return .unauthorized
        case .rateLimited?: return .rateLimited
        default: return .network
        }
    }

    static func makeRequestID() -> String {
        let alphabet = Array("abcdefghijkmnpqrstuvwxyz23456789")
        return String((0..<4).map { _ in alphabet.randomElement()! })
    }
}
