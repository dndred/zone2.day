import Foundation

/// Response of `GET /health` (backend/src/app.ts).
public struct ServerHealth: Decodable, Sendable, Equatable {
    public let ok: Bool
    public let service: String
    public let env: String
    public let version: String
    public let time: String

    public init(ok: Bool, service: String, env: String, version: String, time: String) {
        self.ok = ok
        self.service = service
        self.env = env
        self.version = version
        self.time = time
    }
}
