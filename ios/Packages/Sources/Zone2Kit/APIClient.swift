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
