import CryptoKit
import Foundation

/// OAuth 2.1 + PKCE against our own authorization server (docs/02-architecture.md §6).
public struct OAuthConfig: Sendable {
    public let baseURL: URL
    public let clientId: String
    public let redirectURI: String
    public let scope: String

    public static func app(baseURL: URL) -> OAuthConfig {
        OAuthConfig(baseURL: baseURL, clientId: "zone2-ios", redirectURI: "zone2://oauth/callback", scope: "app")
    }

    public init(baseURL: URL, clientId: String, redirectURI: String, scope: String) {
        self.baseURL = baseURL
        self.clientId = clientId
        self.redirectURI = redirectURI
        self.scope = scope
    }
}

public enum PKCE {
    public static func verifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        for i in bytes.indices { bytes[i] = UInt8.random(in: 0...255) }
        return base64url(Data(bytes))
    }

    public static func challenge(for verifier: String) -> String {
        base64url(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

public struct TokenSet: Codable, Sendable, Equatable {
    public let accessToken: String
    public let refreshToken: String
    public let expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    func expiresSoon(now: Date = .now) -> Bool { expiresAt.timeIntervalSince(now) < 60 }
}

public protocol TokenStore: Sendable {
    func load() -> TokenSet?
    func save(_ tokens: TokenSet?)
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: TokenSet?
    private let lock = NSLock()
    public init(_ tokens: TokenSet? = nil) { self.tokens = tokens }
    public func load() -> TokenSet? { lock.withLock { tokens } }
    public func save(_ tokens: TokenSet?) { lock.withLock { self.tokens = tokens } }
}

public enum AuthError: Error, Equatable, Sendable {
    case signedOut
    case callback(String)
    case token(Int, String)
}

public struct OAuthClient: Sendable {
    public let config: OAuthConfig
    private let transport: HTTPTransport

    public init(config: OAuthConfig, transport: HTTPTransport = URLSessionTransport()) {
        self.config = config
        self.transport = transport
    }

    public func authorizeURL(state: String, challenge: String) -> URL {
        var c = URLComponents(url: config.baseURL.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        c.queryItems = [
            .init(name: "response_type", value: "code"),
            .init(name: "client_id", value: config.clientId),
            .init(name: "redirect_uri", value: config.redirectURI),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
            .init(name: "scope", value: config.scope),
            .init(name: "state", value: state),
        ]
        return c.url!
    }

    /// Extracts the code from the redirect, verifying `state`.
    public func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") { throw AuthError.callback(value("error_description") ?? error) }
        guard value("state") == expectedState else { throw AuthError.callback("state mismatch") }
        guard let code = value("code") else { throw AuthError.callback("no code") }
        return code
    }

    public func exchange(code: String, verifier: String, now: Date = .now) async throws -> TokenSet {
        try await token([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": config.redirectURI,
            "client_id": config.clientId,
            "code_verifier": verifier,
        ], now: now)
    }

    public func refresh(_ refreshToken: String, now: Date = .now) async throws -> TokenSet {
        try await token(["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientId], now: now)
    }

    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String
        let expires_in: Double
    }

    private func token(_ form: [String: String], now: Date) async throws -> TokenSet {
        var request = URLRequest(url: config.baseURL.appending(path: "oauth/token"))
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var c = URLComponents()
        c.queryItems = form.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((c.percentEncodedQuery ?? "").utf8)
        let (data, response) = try await transport.data(for: request)
        guard response.statusCode == 200 else {
            throw AuthError.token(response.statusCode, String(decoding: data, as: UTF8.self))
        }
        let t = try JSONDecoder().decode(TokenResponse.self, from: data)
        return TokenSet(accessToken: t.access_token, refreshToken: t.refresh_token, expiresAt: now.addingTimeInterval(t.expires_in))
    }
}

/// Holds tokens, refreshes them when needed. One refresh at a time: the actor alone is not enough
/// (it is reentrant — a second caller runs while the first awaits the network and would send the
/// same, already rotated refresh token, which the server treats as reuse and revokes the family),
/// so concurrent callers share one in-flight refresh task.
public actor AuthSession {
    private let client: OAuthClient
    private let store: TokenStore
    private let now: @Sendable () -> Date
    private var refreshing: Task<TokenSet, Error>?

    public init(client: OAuthClient, store: TokenStore, now: @escaping @Sendable () -> Date = { .now }) {
        self.client = client
        self.store = store
        self.now = now
    }

    public var isSignedIn: Bool { store.load() != nil }

    public func signedIn(with tokens: TokenSet) { store.save(tokens) }

    public func signOut() { store.save(nil) }

    public func accessToken(forceRefresh: Bool = false) async throws -> String {
        if let running = refreshing { return try await running.value.accessToken }
        guard let tokens = store.load() else { throw AuthError.signedOut }
        if !forceRefresh && !tokens.expiresSoon(now: now()) { return tokens.accessToken }
        let task = Task { [client, now] in try await client.refresh(tokens.refreshToken, now: now()) }
        refreshing = task
        defer { refreshing = nil }
        do {
            let fresh = try await task.value
            store.save(fresh)
            return fresh.accessToken
        } catch AuthError.token(let status, let body) where status == 400 || status == 401 {
            store.save(nil) // refresh token revoked/expired → sign in again
            throw AuthError.token(status, body)
        }
    }
}
