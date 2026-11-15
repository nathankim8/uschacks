import Foundation

/// A decrypted Find My location report for the tag (from findmy/server.py `/api/locations`).
/// Nearby iPhones heard the tag's beacon and reported *their own* position, so `accuracy`
/// is the reporting phone's estimate, and reports arrive minutes after the fact.
public struct FindMyReport: Codable, Equatable, Sendable, Identifiable, Hashable {
    public var ts: Int64
    public var lat: Double
    public var lon: Double
    public var accuracy_m: Int?
    public var confidence: Int?

    public var id: String { "\(ts)-\(lat)-\(lon)" }
    public var date: Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    public init(ts: Int64, lat: Double, lon: Double, accuracy_m: Int? = nil, confidence: Int? = nil) {
        self.ts = ts
        self.lat = lat
        self.lon = lon
        self.accuracy_m = accuracy_m
        self.confidence = confidence
    }
}

public struct FindMyResponse: Codable, Equatable, Sendable {
    public var tag: String?
    public var fetched_at: Int64?
    public var count: Int?
    public var undecryptable: Int?
    public var reports: [FindMyReport]
}

public enum FindMyError: Error, Equatable, Sendable {
    case notConfigured
    case http(Int)
    case server(String)
}

public struct FindMyClient: Sendable {
    public var baseURL: URL
    public var token: String?
    public var session: URLSession

    public init(baseURL: URL, token: String? = nil, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    /// Accepts the server root (http://host:8000) or the full endpoint URL.
    public var endpoint: URL {
        baseURL.path.hasSuffix("/api/locations") ? baseURL : baseURL.appendingPathComponent("api/locations")
    }

    /// Newest first. The helper asks Apple for the last 7 days; it can take up to ~60 s.
    public func locations() async throws -> FindMyResponse {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 75
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            if let body = try? JSONDecoder().decode([String: String].self, from: data), let msg = body["error"] {
                throw FindMyError.server(msg)
            }
            throw FindMyError.http(http.statusCode)
        }
        var decoded = try JSONDecoder().decode(FindMyResponse.self, from: data)
        decoded.reports.sort { $0.ts > $1.ts }
        return decoded
    }
}
