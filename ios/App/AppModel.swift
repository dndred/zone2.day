import Foundation
import Zone2Kit

/// App-wide services. One instance, created in Zone2App.
@MainActor
final class AppModel: ObservableObject {
    let api: APIClient
    let auth: AuthSession
    let oauth: OAuthClient
    let health: HealthSync

    @Published private(set) var me: APIClient.Me?
    @Published private(set) var signedIn = false
    @Published var authError: String?

    init(baseURL: URL = AppEnvironment.serverURL()) {
        api = APIClient(baseURL: baseURL)
        oauth = OAuthClient(config: .app(baseURL: baseURL))
        auth = AuthSession(client: oauth, store: KeychainTokenStore(account: baseURL.host() ?? "default"))
        health = HealthSync(api: api, auth: auth)
        health.startObserving()
        Task { await refreshAccount() }
    }

    func signIn() async {
        authError = nil
        do {
            let tokens = try await SignIn().run(client: oauth)
            await auth.signedIn(with: tokens)
            await refreshAccount()
            await health.sync()
        } catch {
            authError = String(describing: error)
        }
    }

    func signOut() async {
        await auth.signOut()
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
