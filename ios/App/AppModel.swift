import Foundation
import Zone2Kit

/// App-wide services. One instance, created in Zone2App.
@MainActor
final class AppModel: ObservableObject {
    let api: APIClient
    let auth: AuthSession
    let oauth: OAuthClient
    let health: HealthSync
    /// Offline store: every screen reads from here; only `sync` writes (via SyncEngine).
    let store: LocalStore
    let syncEngine: SyncEngine

    @Published private(set) var me: APIClient.Me?
    @Published private(set) var syncing = false
    @Published private(set) var signedIn = false
    @Published var authError: String?

    init(baseURL: URL = AppEnvironment.serverURL()) {
        api = APIClient(baseURL: baseURL)
        oauth = OAuthClient(config: .app(baseURL: baseURL))
        auth = AuthSession(client: oauth, store: KeychainTokenStore(account: baseURL.host() ?? "default"))
        health = HealthSync(api: api, auth: auth)
        // A broken database file must not brick the app: fall back to memory, resync from server.
        store = Self.demoStore() ?? (try? LocalStore.appDefault()) ?? (try! LocalStore())
        syncEngine = SyncEngine(store: store, source: APISyncSource(api: api, auth: auth))
        health.startObserving()
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
        let before = health.state.uploaded
        await health.sync(budget: budget)
        if health.state.uploaded != before { await syncEngine.pull() }
    }

    /// Pull only (pull-to-refresh, background wake): quick, no HealthKit export.
    func pull() async {
        guard !isDemo, await auth.isSignedIn else { return }
        syncing = true
        defer { syncing = false }
        await syncEngine.pull()
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
