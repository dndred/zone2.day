import Foundation

/// Minimal transport abstraction so the client can be tested without network.
public protocol HTTPTransport: Sendable {
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.notHTTP }
        return (data, http)
    }
}

public enum APIError: Error, Equatable, Sendable {
    case notHTTP
    case status(Int, body: String)
    case decoding(String)
}

/// zone2.day Sync API client. Grows with docs/05-sync.md; generated from OpenAPI later (`just gen`).
public struct APIClient: Sendable {
    public let baseURL: URL
    private let transport: HTTPTransport

    public init(baseURL: URL, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.transport = transport
    }

    public func health() async throws -> ServerHealth {
        try await get("health")
    }

    // MARK: - Authorized Sync API (scope "app")

    public struct Me: Decodable, Sendable, Equatable {
        public let userId: String
        public let name: String?
    }

    public struct UploadResult: Decodable, Sendable, Equatable {
        public let activityId: String
        public let created: Bool
        public let sport: String
        public let localDate: String
        public let plannedWorkoutId: String?
        public let duplicateOf: String?
    }

    public func me(auth: AuthSession) async throws -> Me {
        let data = try await authorized(auth, method: "GET", path: "v1/me", body: nil, contentType: nil)
        return try JSONDecoder().decode(Me.self, from: data)
    }

    public func uploadHealthKit(_ json: Data, auth: AuthSession) async throws -> UploadResult {
        let data = try await authorized(auth, method: "POST", path: "v1/activities/healthkit", body: json, contentType: "application/json")
        return try JSONDecoder().decode(UploadResult.self, from: data)
    }

    /// One page of the sync feed; nil cursor → snapshot. Throws `.status(410, …)` for a cursor
    /// the server does not know (→ full resync).
    public func sync(cursor: String?, limit: Int = 500, auth: AuthSession) async throws -> SyncPage {
        var path = "v1/sync?limit=\(limit)"
        if let cursor { path += "&cursor=\(cursor)" }
        let data = try await authorized(auth, method: "GET", path: path, body: nil, contentType: nil)
        do {
            return try JSONDecoder().decode(SyncPage.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    /// Curves of an activity for charts; nil when the activity has no raw samples (e.g. Strava copy).
    public func streams(activityId: String, maxPoints: Int = 300, auth: AuthSession) async throws -> ActivityStreams? {
        do {
            let data = try await authorized(auth, method: "GET", path: "v1/activities/\(activityId)/streams?maxPoints=\(maxPoints)", body: nil, contentType: nil)
            return try JSONDecoder().decode(ActivityStreams.self, from: data)
        } catch APIError.status(404, _) {
            return nil
        }
    }

    /// The whole recording (HealthKit dump): the phone writes zone2 Ride rides into Apple Health.
    public func activityDump(_ activityId: String, auth: AuthSession) async throws -> HealthKitDump {
        let data = try await authorized(auth, method: "GET", path: "v1/activities/\(activityId)/dump", body: nil, contentType: nil)
        do {
            return try JSONDecoder().decode(HealthKitDump.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }

    public func reportHealthDeletions(_ uuids: [String], auth: AuthSession) async throws {
        let body = try JSONEncoder().encode(["uuids": uuids])
        _ = try await authorized(auth, method: "POST", path: "v1/health-deletions", body: body, contentType: "application/json")
    }

    /// Adds the bearer token; on 401 refreshes once and retries.
    func authorized(_ auth: AuthSession, method: String, path: String, body: Data?, contentType: String?) async throws -> Data {
        for attempt in 0..<2 {
            let token = try await auth.accessToken(forceRefresh: attempt > 0)
            var request = URLRequest(url: Self.url(baseURL, path))
            request.httpMethod = method
            request.httpBody = body
            request.timeoutInterval = 60
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
            if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
            let (data, response) = try await transport.data(for: request)
            if response.statusCode == 401 && attempt == 0 { continue }
            guard (200..<300).contains(response.statusCode) else {
                throw APIError.status(response.statusCode, body: String(decoding: data, as: UTF8.self))
            }
            return data
        }
        throw AuthError.signedOut
    }

    /// `path` may carry a query ("v1/sync?cursor=1"); appending(path:) would escape the "?".
    static func url(_ base: URL, _ path: String) -> URL {
        let parts = path.split(separator: "?", maxSplits: 1).map(String.init)
        var url = base.appending(path: parts[0])
        if parts.count == 2, var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            c.percentEncodedQuery = parts[1]
            url = c.url!
        }
        return url
    }

    func get<T: Decodable>(_ path: String) async throws -> T {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(UUID().uuidString.lowercased(), forHTTPHeaderField: "X-Request-Id")
        request.timeoutInterval = 20

        let (data, response) = try await transport.data(for: request)
        guard (200..<300).contains(response.statusCode) else {
            throw APIError.status(response.statusCode, body: String(decoding: data, as: UTF8.self))
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw APIError.decoding(String(describing: error))
        }
    }
}
