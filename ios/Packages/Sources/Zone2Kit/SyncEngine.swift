import Foundation

/// Where pages come from: the real API, or a fake in tests.
public protocol SyncSource: Sendable {
    func page(cursor: String?) async throws -> SyncPage
}

public struct APISyncSource: SyncSource {
    let api: APIClient
    let auth: AuthSession

    public init(api: APIClient, auth: AuthSession) {
        self.api = api
        self.auth = auth
    }

    public func page(cursor: String?) async throws -> SyncPage {
        try await api.sync(cursor: cursor, auth: auth)
    }
}

/// Pull side of sync (docs/05-sync.md §2): pages until `hasMore` is false, each page applied in
/// one GRDB transaction. 410 → forget everything and take a fresh snapshot. Calls overlap
/// safely: a pull already in flight is awaited instead of starting a second one.
public actor SyncEngine {
    public enum Outcome: Sendable, Equatable {
        case synced(changes: Int, pages: Int)
        case failed(String)
    }

    private let store: LocalStore
    private let source: SyncSource
    private var inFlight: Task<Outcome, Never>?

    public init(store: LocalStore, source: SyncSource) {
        self.store = store
        self.source = source
    }

    @discardableResult
    public func pull() async -> Outcome {
        if let inFlight { return await inFlight.value }
        let task = Task { await run() }
        inFlight = task
        let outcome = await task.value
        inFlight = nil
        return outcome
    }

    private func run() async -> Outcome {
        var changes = 0
        var pages = 0
        var resynced = false
        do {
            var cursor = try store.cursor()
            while true {
                let page: SyncPage
                do {
                    page = try await source.page(cursor: cursor)
                } catch APIError.status(410, _) where !resynced {
                    resynced = true
                    try store.reset()
                    cursor = nil
                    continue
                }
                try store.apply(page)
                changes += page.changes.count
                pages += 1
                cursor = page.cursor
                if !page.hasMore || pages >= 100 { break }
            }
            return .synced(changes: changes, pages: pages)
        } catch {
            let message = Self.describe(error)
            try? store.recordError(message)
            return .failed(message)
        }
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost:
            "offline"
        case let e as URLError: "network: \(e.code.rawValue)"
        case APIError.status(let code, _): "server: \(code)"
        case AuthError.signedOut: "signed out"
        default: String(describing: error)
        }
    }
}
