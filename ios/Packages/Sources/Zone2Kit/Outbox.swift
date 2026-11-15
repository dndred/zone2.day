import Foundation

/// Sends queued messages (docs/05-sync.md §3). Failures are retried with exponential backoff
/// (30 s … 6 h); 4xx other than 401/408/429 are not going to succeed by retrying → parked for a day.
public actor OutboxSender {
    public typealias Send = @Sendable (LocalStore.OutboxItem) async throws -> Void

    private let store: LocalStore
    private let send: Send

    public init(store: LocalStore, send: @escaping Send) {
        self.store = store
        self.send = send
    }

    /// Sends everything due; returns how many were sent.
    @discardableResult
    public func flush(now: Date = Date()) async -> Int {
        var sent = 0
        for item in (try? store.dueOutbox(now: now)) ?? [] {
            do {
                try await send(item)
                try? store.outboxSent(item.id)
                sent += 1
            } catch {
                try? store.outboxFailed(item.id, error: SyncEngine.describe(error), retryAt: now.addingTimeInterval(Self.delay(error, attempts: item.attempts)))
            }
        }
        return sent
    }

    static func delay(_ error: Error, attempts: Int) -> TimeInterval {
        if case APIError.status(let code, _) = error, (400..<500).contains(code), ![401, 408, 429].contains(code) {
            return 24 * 3600
        }
        return min(30 * pow(2, Double(attempts)), 6 * 3600)
    }
}

extension APIClient {
    /// POST JSON to the Sync API; the response body is ignored (outbox messages are fire-and-ack).
    public func postJSON(_ path: String, body: Data, auth: AuthSession) async throws {
        _ = try await authorized(auth, method: "POST", path: path, body: body, contentType: "application/json")
    }
}
