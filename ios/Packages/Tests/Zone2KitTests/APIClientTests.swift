import Foundation
import Testing
@testable import Zone2Kit

private struct FakeTransport: HTTPTransport {
    let status: Int
    let body: String
    let onRequest: @Sendable (URLRequest) -> Void

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        onRequest(request)
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

private final class Box<T: Sendable>: @unchecked Sendable {
    var value: T?
}

@Test func healthDecodesServerResponse() async throws {
    let seen = Box<URLRequest>()
    let client = APIClient(
        baseURL: URL(string: "https://api-staging.zone2.day")!,
        transport: FakeTransport(
            status: 200,
            body: #"{"ok":true,"service":"zone2-api","env":"staging","version":"abc123","time":"2026-11-14T13:18:09.160Z"}"#,
            onRequest: { seen.value = $0 }
        )
    )

    let health = try await client.health()

    #expect(health.ok)
    #expect(health.env == "staging")
    #expect(health.version == "abc123")
    #expect(seen.value?.url?.absoluteString == "https://api-staging.zone2.day/health")
    #expect(seen.value?.value(forHTTPHeaderField: "X-Request-Id") != nil)
}

@Test func non2xxBecomesStatusError() async {
    let client = APIClient(
        baseURL: URL(string: "https://example.test")!,
        transport: FakeTransport(status: 404, body: #"{"error":"not_found"}"#, onRequest: { _ in })
    )
    await #expect(throws: APIError.status(404, body: #"{"error":"not_found"}"#)) {
        _ = try await client.health()
    }
}

@Test func serverURLComesFromTheAppCopyAndHonorsOverride() throws {
    let defaults = try #require(UserDefaults(suiteName: "zone2-test-\(UUID())"))
    #expect(AppEnvironment.serverURL(defaults: defaults, info: nil) == AppEnvironment.stagingURL)
    let prod: [String: Any] = ["Zone2ServerURL": "https://api.zone2.day", "Zone2WatchDeliveryDefault": "YES"]
    let stg: [String: Any] = ["Zone2ServerURL": "https://api-staging.zone2.day", "Zone2WatchDeliveryDefault": "NO"]
    #expect(AppEnvironment.serverURL(defaults: defaults, info: prod) == AppEnvironment.prodURL)
    #expect(AppEnvironment.serverURL(defaults: defaults, info: stg) == AppEnvironment.stagingURL)
    #expect(AppEnvironment.watchDelivery(defaults: defaults, info: prod))
    #expect(!AppEnvironment.watchDelivery(defaults: defaults, info: stg))
    defaults.set(true, forKey: AppEnvironment.watchDeliveryKey) // the athlete turned it on in stg
    #expect(AppEnvironment.watchDelivery(defaults: defaults, info: stg))
    defaults.set("http://localhost:8787", forKey: "ServerURL")
    #expect(AppEnvironment.serverURL(defaults: defaults, info: prod).absoluteString == "http://localhost:8787")
}
