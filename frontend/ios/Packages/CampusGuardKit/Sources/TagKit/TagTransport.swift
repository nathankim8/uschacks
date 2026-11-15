import Foundation

/// How TagLink reaches the tag. Production uses ntfy; tests use an in-memory fake.
public protocol TagTransport: Sendable {
    /// Sends one command line to the tag's command topic.
    func send(_ line: String) async throws
    /// Tag pushes newer than `since` (ntfy id or duration), then live ones until the connection drops.
    func reports(since: String?) -> AsyncThrowingStream<NtfyMessage, Error>
}

public struct NtfyTransport: TagTransport {
    public let client: NtfyClient
    public let configuration: TagConfiguration

    public init(configuration: TagConfiguration, session: URLSession = .shared) {
        self.configuration = configuration
        self.client = NtfyClient(server: configuration.server, accessToken: configuration.accessToken, session: session)
    }

    public func send(_ line: String) async throws {
        try await client.publish(line, to: configuration.commandTopic)
    }

    public func reports(since: String?) -> AsyncThrowingStream<NtfyMessage, Error> {
        client.subscribe(configuration.alertTopic, since: since)
    }
}

/// What TagLink keeps between launches (per alert topic).
public struct TagLinkMemory: Codable, Equatable, Sendable {
    public var topic: String
    /// Last ntfy message id seen, so a reconnect resumes exactly where it stopped.
    public var cursor: String?
    public var snapshot = TagSnapshot()
    public var history: [TagReport] = []

    public init(topic: String) { self.topic = topic }
}

public protocol TagLinkPersistence: Sendable {
    func load() -> TagLinkMemory?
    func save(_ memory: TagLinkMemory)
}

/// Small JSON file in Application Support. Excluded from backups; contains no topic secrets
/// beyond the topic name, which is already in the Keychain-backed configuration.
public struct FileTagLinkPersistence: TagLinkPersistence {
    public let url: URL

    public init(fileName: String = "tag-link.json") {
        let dir = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        url = dir.appendingPathComponent(fileName)
    }

    public init(url: URL) { self.url = url }

    public func load() -> TagLinkMemory? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(TagLinkMemory.self, from: data)
    }

    public func save(_ memory: TagLinkMemory) {
        guard let data = try? JSONEncoder().encode(memory) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var u = url
        try? u.setResourceValues(values)
    }
}

public final class InMemoryTagLinkPersistence: TagLinkPersistence, @unchecked Sendable {
    private let lock = NSLock()
    private var memory: TagLinkMemory?
    public init(_ memory: TagLinkMemory? = nil) { self.memory = memory }
    public func load() -> TagLinkMemory? { lock.withLock { memory } }
    public func save(_ memory: TagLinkMemory) { lock.withLock { self.memory = memory } }
}
