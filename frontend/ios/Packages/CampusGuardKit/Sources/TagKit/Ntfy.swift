import Foundation

/// One line of ntfy's JSON stream (https://docs.ntfy.sh/subscribe/api/#json-message-format).
public struct NtfyMessage: Codable, Equatable, Sendable {
    public var id: String
    public var time: Int64
    public var event: String
    public var topic: String?
    public var message: String?
    public var title: String?
    public var tags: [String]?
    public var priority: Int?

    public init(id: String, time: Int64, event: String = "message", topic: String? = nil, message: String? = nil,
                title: String? = nil, tags: [String]? = nil, priority: Int? = nil) {
        self.id = id
        self.time = time
        self.event = event
        self.topic = topic
        self.message = message
        self.title = title
        self.tags = tags
        self.priority = priority
    }

    public var isMessage: Bool { event == "message" }
}

public enum NtfyError: Error, Equatable, Sendable {
    case badURL
    case http(Int)
    case rateLimited
    case unauthorized
}

/// Minimal ntfy client: publish, and one long-lived JSON stream per topic.
/// Never polls in a loop: ntfy rate-limits per IP and the tag shares the hotspot's IP.
public struct NtfyClient: Sendable {
    public var server: URL
    public var accessToken: String?
    public var session: URLSession

    public init(server: URL, accessToken: String? = nil, session: URLSession = .shared) {
        self.server = server
        self.accessToken = accessToken
        self.session = session
    }

    func url(_ topic: String, _ suffix: String = "", query: [URLQueryItem] = []) throws -> URL {
        var c = URLComponents(url: server.appendingPathComponent(topic + suffix), resolvingAgainstBaseURL: false)
        if !query.isEmpty { c?.queryItems = query }
        guard let url = c?.url else { throw NtfyError.badURL }
        return url
    }

    private func authorize(_ request: inout URLRequest) {
        if let accessToken, !accessToken.isEmpty {
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        }
    }

    private static func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300: return
        case 401, 403: throw NtfyError.unauthorized
        case 429: throw NtfyError.rateLimited
        default: throw NtfyError.http(http.statusCode)
        }
    }

    public func publish(_ body: String, to topic: String) async throws {
        var request = URLRequest(url: try url(topic))
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.timeoutInterval = 10
        authorize(&request)
        let (_, response) = try await session.data(for: request)
        try Self.check(response)
    }

    /// Streams messages newer than `since` (an id, a duration like "1h", or "all"), then live ones.
    /// The request's idle timeout (70 s) is longer than ntfy's 45 s keepalive, so a dead connection
    /// ends the stream and the caller reconnects.
    public func subscribe(_ topic: String, since: String?) -> AsyncThrowingStream<NtfyMessage, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var query: [URLQueryItem] = []
                    if let since { query.append(URLQueryItem(name: "since", value: since)) }
                    var request = URLRequest(url: try url(topic, "/json", query: query))
                    request.timeoutInterval = 70
                    authorize(&request)
                    let (bytes, response) = try await session.bytes(for: request)
                    try Self.check(response)
                    let decoder = JSONDecoder()
                    for try await line in bytes.lines {
                        guard let data = line.data(using: .utf8),
                              let message = try? decoder.decode(NtfyMessage.self, from: data) else { continue }
                        continuation.yield(message)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// One-shot read (used by background refresh only, never in a loop).
    public func poll(_ topic: String, since: String) async throws -> [NtfyMessage] {
        var request = URLRequest(url: try url(topic, "/json", query: [
            URLQueryItem(name: "poll", value: "1"), URLQueryItem(name: "since", value: since),
        ]))
        request.timeoutInterval = 15
        authorize(&request)
        let (data, response) = try await session.data(for: request)
        try Self.check(response)
        let decoder = JSONDecoder()
        return String(decoding: data, as: UTF8.self)
            .split(separator: "\n")
            .compactMap { try? decoder.decode(NtfyMessage.self, from: Data($0.utf8)) }
            .filter(\.isMessage)
    }
}
