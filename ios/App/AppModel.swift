import Foundation
import Zone2Kit

/// App-wide services. One instance, created in Zone2App.
@MainActor
final class AppModel: ObservableObject {
    let api: APIClient
    let auth: AuthSession
    let oauth: OAuthClient
    let health: HealthSync
    let metrics: DailyMetricsSync
    /// Offline store: every screen reads from here; only `sync` writes (via SyncEngine).
    let store: LocalStore
    let syncEngine: SyncEngine
    let outbox: OutboxSender
    let storeInMemory: Bool

    @Published private(set) var me: APIClient.Me?
    @Published private(set) var syncing = false
    @Published private(set) var signedIn = false
    @Published var authError: String?

    init(baseURL: URL = AppEnvironment.serverURL()) {
        EnvironmentReset.ifServerChanged(baseURL)
        api = APIClient(baseURL: baseURL)
        oauth = OAuthClient(config: .app(baseURL: baseURL))
        auth = AuthSession(client: oauth, store: KeychainTokenStore(account: baseURL.host() ?? "default"))
        health = HealthSync(api: api, auth: auth)
        // A broken database file must not brick the app: fall back to memory, resync from server.
        // The fallback is visible: Profile → Plan sync shows "in memory".
        if let demo = Self.demoStore() {
            store = demo
            storeInMemory = true
        } else if let file = try? LocalStore.appDefault() {
            store = file
            storeInMemory = false
        } else {
            store = try! LocalStore()
            storeInMemory = true
        }
        syncEngine = SyncEngine(store: store, source: APISyncSource(api: api, auth: auth))
        outbox = OutboxSender(store: store) { [api, auth] item in
            switch item.kind {
            case "delivery": try await api.postJSON("v1/deliveries", body: item.payload, auth: auth)
            case "strength": try await api.postJSON("v1/strength-sessions", body: item.payload, auth: auth)
            case "daily_metrics": try await api.postJSON("v1/daily-metrics", body: item.payload, auth: auth)
            default: break // unknown kinds from a newer build: drop
            }
        }
        metrics = DailyMetricsSync(local: store)
        health.startObserving()
        metrics.onChange = { [weak self] in await self?.sendMetrics() }
        metrics.startObserving()
        Task { await refreshAccount() }
    }

    /// Debug: `-DemoFeed <path to fixtures/sync/demo-feed.json>` → in-memory store with that page,
    /// no network pulls. For screenshots and UI checks in the simulator.
    private static func demoStore() -> LocalStore? {
        #if DEBUG
        guard let path = UserDefaults.standard.string(forKey: "DemoFeed"),
              let data = FileManager.default.contents(atPath: path),
              let page = try? JSONDecoder().decode(SyncPage.self, from: data),
              let store = try? LocalStore() else { return nil }
        try? store.apply(page)
        return store
        #else
        return nil
        #endif
    }

    var isDemo: Bool { UserDefaults.standard.string(forKey: "DemoFeed") != nil }

    /// Full cycle: pull the plan, upload new workouts, pull again if uploads changed anything.
    func sync(budget: TimeInterval = 300) async {
        guard !isDemo, await auth.isSignedIn else { return }
        syncing = true
        defer { syncing = false }
        await syncEngine.pull()
        await WatchSync.run(store: store, interactive: budget > 60)
        if budget > 60 { await metrics.requestMissingAuthorization() }
        await metrics.collect()
        await outbox.flush()
        let before = health.state.uploaded
        await health.sync(budget: budget)
        if health.state.uploaded != before {
            await syncEngine.pull()
            await WatchSync.run(store: store, interactive: false) // done workouts leave the watch
            await outbox.flush()
        }
    }

    /// Curves for an activity: fetched once into the offline cache (screens read the cache).
    func loadStreams(_ activityId: String) async {
        if (try? store.hasStreams(activityId)) == true { return }
        if isDemo {
            try? store.saveStreams(Self.demoStreams(), activityId: activityId)
            return
        }
        guard await auth.isSignedIn else { return }
        if let s = try? await api.streams(activityId: activityId, auth: auth) {
            try? store.saveStreams(s, activityId: activityId)
        }
    }

    /// Demo curve: warm-up, a 25-minute effort, cool-down (matches the demo parkrun intervals).
    private static func demoStreams() -> ActivityStreams {
        let n = 300, dur = 5191.0
        let t = (0..<n).map { Double($0) * dur / Double(n) }
        func effort(_ x: Double) -> Bool { x >= 2408 && x < 3934 }
        let hr: [Double?] = t.map { x in effort(x) ? 150 + 10 * min((x - 2408) / 600, 1) + 2 * sin(x / 60) : 115 + 8 * sin(x / 300) + (x > 3934 ? 15 : 0) }
        let speed: [Double?] = t.map { x in x < 600 ? 0.2 : effort(x) ? 3.33 + 0.1 * sin(x / 90) : 2.7 + 0.2 * sin(x / 200) }
        let power: [Double?] = speed.map { $0.map { $0 * 75 } }
        return ActivityStreams(bucketSec: dur / Double(n), columns: ["t": t, "heartRate": hr, "speed": speed, "runningPower": power])
    }

    /// Health metrics changed (sleep observer, background): aggregate the recent days and send.
    func sendMetrics() async {
        guard !isDemo, await auth.isSignedIn else { return }
        await metrics.collect()
        await outbox.flush()
    }

    /// Sends queued local changes (gym log) right away; no-op offline or signed out.
    func sendQueued() async {
        guard !isDemo, await auth.isSignedIn else { return }
        await outbox.flush()
    }

    /// Pull only (pull-to-refresh, background wake): quick, no HealthKit export.
    func pull() async {
        guard !isDemo, await auth.isSignedIn else { return }
        syncing = true
        defer { syncing = false }
        await syncEngine.pull()
        await WatchSync.run(store: store, interactive: true)
        await metrics.collect()
        await outbox.flush()
    }

    func signIn() async {
        authError = nil
        do {
            let tokens = try await SignIn().run(client: oauth)
            await auth.signedIn(with: tokens)
            await refreshAccount()
            await sync()
        } catch {
            authError = String(describing: error)
        }
    }

    func signOut() async {
        await auth.signOut()
        try? store.reset()
        me = nil
        signedIn = false
    }

    func refreshAccount() async {
        signedIn = await auth.isSignedIn
        guard signedIn else { return }
        do {
            me = try await api.me(auth: auth)
        } catch AuthError.signedOut, AuthError.token {
            signedIn = false
        } catch {
            authError = String(describing: error) // offline is fine: tokens stay
        }
    }
}
