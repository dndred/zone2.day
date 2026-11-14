import Foundation
import Testing
@testable import Zone2Kit

private final class ScriptedTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

private let base = URL(string: "https://api-staging.zone2.day")!
private let tokenJSON = #"{"access_token":"A2","refresh_token":"R2","expires_in":3600,"token_type":"Bearer","scope":"app"}"#

@Test func pkceMatchesRFC7636() {
    #expect(PKCE.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    #expect(PKCE.verifier().count == 43)
}

@Test func authorizeURLAndCallback() throws {
    let client = OAuthClient(config: .app(baseURL: base), transport: ScriptedTransport([]))
    let url = client.authorizeURL(state: "st", challenge: "ch")
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
    #expect(url.path == "/oauth/authorize")
    #expect(items.contains(.init(name: "client_id", value: "zone2-ios")))
    #expect(items.contains(.init(name: "scope", value: "app")))
    #expect(try client.code(from: URL(string: "zone2://oauth/callback?code=C&state=st")!, expectedState: "st") == "C")
    #expect(throws: AuthError.callback("state mismatch")) {
        try client.code(from: URL(string: "zone2://oauth/callback?code=C&state=x")!, expectedState: "st")
    }
}

@Test func sessionRefreshesExpiringToken() async throws {
    let transport = ScriptedTransport([(200, tokenJSON)])
    let store = MemoryTokenStore(TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: 10)))
    let session = AuthSession(client: OAuthClient(config: .app(baseURL: base), transport: transport), store: store)
    #expect(try await session.accessToken() == "A2")
    #expect(store.load()?.refreshToken == "R2")
    let body = String(decoding: transport.requests[0].httpBody!, as: UTF8.self)
    #expect(body.contains("grant_type=refresh_token"))
}

@Test func apiRetriesOnceAfter401() async throws {
    let transport = ScriptedTransport([(401, "{}"), (200, tokenJSON), (200, #"{"userId":"u","name":"Andrei"}"#)])
    let store = MemoryTokenStore(TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: Date(timeIntervalSinceNow: 3600)))
    let session = AuthSession(client: OAuthClient(config: .app(baseURL: base), transport: transport), store: store)
    let api = APIClient(baseURL: base, transport: transport)
    let me = try await api.me(auth: session)
    #expect(me.name == "Andrei")
    #expect(transport.requests.last?.value(forHTTPHeaderField: "Authorization") == "Bearer A2")
}

@Test func revokedRefreshSignsOut() async {
    let transport = ScriptedTransport([(400, #"{"error":"invalid_grant"}"#)])
    let store = MemoryTokenStore(TokenSet(accessToken: "A1", refreshToken: "R1", expiresAt: .distantPast))
    let session = AuthSession(client: OAuthClient(config: .app(baseURL: base), transport: transport), store: store)
    await #expect(throws: AuthError.self) { _ = try await session.accessToken() }
    #expect(store.load() == nil)
}
