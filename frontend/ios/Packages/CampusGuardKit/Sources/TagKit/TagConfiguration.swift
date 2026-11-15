import Foundation

/// Where the tag lives on ntfy, and where its Find My locations come from.
/// The topic names are secrets: anyone who knows them can arm or disarm the tag.
public struct TagConfiguration: Equatable, Sendable, Codable {
    public var server: URL
    public var alertTopic: String
    /// Defaults to `<alertTopic>-cmd`, which is what the firmware polls.
    public var commandTopic: String
    /// Optional ntfy access token (for reserved/protected topics).
    public var accessToken: String?
    /// Find My helper (findmy/server.py): base URL that serves `/api/locations`.
    public var findMyURL: URL?
    public var findMyToken: String?

    public static let defaultServer = URL(string: "https://ntfy.sh")!

    public init(server: URL = TagConfiguration.defaultServer, alertTopic: String, commandTopic: String? = nil,
                accessToken: String? = nil, findMyURL: URL? = nil, findMyToken: String? = nil) {
        let topic = alertTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        self.server = server
        self.alertTopic = topic
        let cmd = commandTopic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        self.commandTopic = cmd.isEmpty ? "\(topic)-cmd" : cmd
        self.accessToken = accessToken
        self.findMyURL = findMyURL
        self.findMyToken = findMyToken
    }

    public var isValid: Bool {
        Self.isValidTopic(alertTopic) && Self.isValidTopic(commandTopic) && alertTopic != commandTopic
    }

    /// ntfy topic names: 1-64 chars of letters, digits, `-` and `_`.
    public static func isValidTopic(_ topic: String) -> Bool {
        guard (1...64).contains(topic.count) else { return false }
        return topic.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || $0 == "-" || $0 == "_" }
    }

    /// Accepts the formats people paste: a bare topic, `ntfy.sh/topic`, or a full URL
    /// (`https://ntfy.sh/topic`, also from the firmware's Serial Monitor hint).
    public static func parse(_ input: String) -> (server: URL, topic: String)? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("/") {
            return isValidTopic(text) ? (defaultServer, text) : nil
        }
        if !text.contains("://") { text = "https://" + text }
        guard let comps = URLComponents(string: text), let host = comps.host else { return nil }
        let parts = comps.path.split(separator: "/").map(String.init)
        guard var topic = parts.first else { return nil }
        if topic.hasSuffix("-cmd") { topic.removeLast(4) }
        guard isValidTopic(topic) else { return nil }
        var base = URLComponents()
        base.scheme = comps.scheme ?? "https"
        base.host = host
        base.port = comps.port
        guard let server = base.url else { return nil }
        return (server, topic)
    }
}
