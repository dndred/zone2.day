import AppKit
import AuthenticationServices
import Foundation
import Observation
import TrainerKit
import Zone2Kit

/// The overlay's slice of the iOS client: sign-in, the plan (bike workouts from the sync feed,
/// kept offline in GRDB) and uploading finished rides. Server: prod by default
/// (`Zone2ServerURL` in Info.plist); `defaults write day.zone2.ride ServerURL https://api-staging.zone2.day`
/// switches it.
@MainActor @Observable
final class RideAccount {
    let baseURL: URL
    @ObservationIgnored let api: APIClient
    @ObservationIgnored let oauth: OAuthClient
    @ObservationIgnored let auth: AuthSession
    @ObservationIgnored let store: LocalStore
    @ObservationIgnored let engine: SyncEngine
    @ObservationIgnored private var signInSession: SignInSession?

    private(set) var signedIn = false
    private(set) var name: String?
    private(set) var syncing = false
    private(set) var error: String?
    /// Bike workouts from yesterday to a week ahead, in date order.
    private(set) var workouts: [PlannedItem] = []
    private(set) var today = LocalDate.today(in: .current)
    /// Upload of the last ride: nil — nothing to say.
    private(set) var upload: UploadState?

    enum UploadState: Equatable {
        case sending
        case sent(planned: String?)
        case failed(String)
    }

    init(baseURL: URL = AppEnvironment.serverURL()) {
        self.baseURL = baseURL
        api = APIClient(baseURL: baseURL)
        oauth = OAuthClient(config: .app(baseURL: baseURL))
        let host = baseURL.host() ?? "default"
        auth = AuthSession(client: oauth, store: KeychainTokenStore(account: host, service: "day.zone2.ride.oauth"))
        let dir = URL.applicationSupportDirectory.appending(path: "day.zone2.ride/\(host)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = (try? LocalStore(directory: dir)) ?? (try! LocalStore())
        engine = SyncEngine(store: store, source: APISyncSource(api: api, auth: auth))
        reload()
        Task { await start() }
    }

    var isStaging: Bool { baseURL.host()?.contains("staging") == true }

    private func start() async {
        signedIn = await auth.isSignedIn
        await refresh()
        await uploadPending()
    }

    // MARK: Plan

    func refresh() async {
        guard await auth.isSignedIn, !syncing else { return }
        syncing = true
        defer { syncing = false }
        switch await engine.pull() {
        case .synced: error = nil
        case .failed(let message): error = message
        }
        if !(await auth.isSignedIn) { signedIn = false }
        reload()
        if name == nil { name = try? await api.me(auth: auth).name }
    }

    private func reload() {
        let local = LocalDate.today(in: .current)
        guard let snap = try? store.snapshot(from: local.adding(days: -1), to: local.adding(days: 7)) else { return }
        today = snap.today
        workouts = snap.days.flatMap(\.planned).filter { $0.workout.sport == .bike && $0.workout.skipped == nil }
    }

    /// What to ride now: today's first bike workout not done yet.
    var suggested: PlannedItem? {
        workouts.first { $0.workout.date == today && $0.status != .done }
    }

    // MARK: Sign-in

    func signIn() async {
        error = nil
        do {
            let session = SignInSession()
            signInSession = session
            defer { signInSession = nil }
            let tokens = try await session.run(client: oauth)
            await auth.signedIn(with: tokens)
            signedIn = true
            name = try? await api.me(auth: auth).name
            await refresh()
            await uploadPending()
        } catch {
            self.error = String(describing: error)
        }
    }

    func signOut() async {
        await auth.signOut()
        try? store.reset()
        signedIn = false
        name = nil
        reload()
    }

    // MARK: Uploads

    /// Rides shorter than this stay on the Mac (test spins, false starts).
    static let minUploadSec = 300.0

    /// Ride files already on this server: file name → activity id.
    private var uploaded: [String: String] {
        get { UserDefaults.standard.dictionary(forKey: "uploaded.\(baseURL.host() ?? "")") as? [String: String] ?? [:] }
        set { UserDefaults.standard.set(newValue, forKey: "uploaded.\(baseURL.host() ?? "")") }
    }

    /// Sends one ride; the result shows under the overlay.
    func upload(_ file: URL) async {
        guard await auth.isSignedIn else {
            upload = .failed(String(localized: "Sign in to send the ride"))
            return
        }
        upload = .sending
        do {
            let result = try await send(file)
            upload = .sent(planned: result.flatMap { r in workouts.first { $0.workout.id == r.plannedWorkoutId }?.workout.title })
            await refresh()
        } catch {
            upload = .failed(SyncFailure.describe(error))
        }
    }

    /// Everything recorded while signed out or offline. Idempotent on the server (workout uuid).
    func uploadPending() async {
        guard await auth.isSignedIn else { return }
        let files = (try? FileManager.default.contentsOfDirectory(at: RideModel.ridesFolder, includingPropertiesForKeys: nil)) ?? []
        for file in files.filter({ $0.lastPathComponent.hasSuffix("-ride.json") }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where uploaded[file.lastPathComponent] == nil {
            _ = try? await send(file)
        }
        await refresh()
    }

    /// nil result: too short, kept on the Mac only.
    private func send(_ file: URL) async throws -> APIClient.UploadResult? {
        let data = try Data(contentsOf: file)
        let dump = try JSONDecoder().decode(HealthKitDump.self, from: data)
        guard dump.workout.durationSec >= Self.minUploadSec else {
            uploaded[file.lastPathComponent] = "" // never retried
            return nil
        }
        let result = try await api.uploadHealthKit(data, auth: auth)
        uploaded[file.lastPathComponent] = result.activityId
        return result
    }
}

enum SyncFailure {
    static func describe(_ error: Error) -> String {
        switch error {
        case let e as URLError: e.localizedDescription
        case APIError.status(let code, let body): "HTTP \(code) \(body.prefix(120))"
        case AuthError.signedOut: String(localized: "Signed out")
        default: String(describing: error)
        }
    }
}

/// Sign-in through our OAuth page (passkey) in the system web auth window.
@MainActor
private final class SignInSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(client: OAuthClient) async throws -> TokenSet {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let url = client.authorizeURL(state: state, challenge: PKCE.challenge(for: verifier))
        NSApp.activate()
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            // macOS calls this off the main thread: a non-isolated closure, or Swift traps.
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("zone2")) { @Sendable url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? AuthError.callback("cancelled")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
        session = nil
        let code = try client.code(from: callback, expectedState: state)
        return try await client.exchange(code: code, verifier: verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated { NSApp.windows.first { $0.isVisible } ?? ASPresentationAnchor() }
    }
}
