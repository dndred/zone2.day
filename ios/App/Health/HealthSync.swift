import Foundation
import HealthKit
import UIKit
import Zone2Kit

/// Workout upload pipeline (docs/05-sync.md §6):
///   anchored query → pending → export (HealthKit, needs unlocked device) → gzip file →
///   background URLSession upload (continues while the app is suspended) → done.
/// First run = backfill of the whole history, newest first. Deletions are reported too.
@MainActor
final class HealthSync: ObservableObject {
    enum Stage: String, Codable { case queued, exported, uploading }

    struct Pending: Codable, Hashable {
        let uuid: String
        let start: Date
        var attempts: Int = 0
        var stage: Stage? = .queued
    }

    struct State: Codable {
        var anchor: Data?
        var pending: [Pending] = []
        var deletions: [String] = []
        var uploaded: Int = 0
        var lastSync: Date?
        var lastError: String?
    }

    @Published private(set) var state = State()
    @Published private(set) var running = false
    @Published private(set) var authorized = false

    /// Cap on exported-but-not-uploaded files (disk use while backfilling).
    private let maxExportedAhead = 150

    private let store = HKHealthStore()
    private let api: APIClient
    private let auth: AuthSession
    private let appVersion: String
    private var observer: HKObserverQuery?
    let uploader = BackgroundUploader()

    init(api: APIClient, auth: AuthSession) {
        self.api = api
        self.auth = auth
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        state = Self.loadState()
        authorized = UserDefaults.standard.bool(forKey: "health.authorized")
        try? FileManager.default.createDirectory(at: Self.filesDir, withIntermediateDirectories: true)
        uploader.start { [weak self] uuid, status, body, error in
            Task { @MainActor in self?.uploadFinished(uuid: uuid, status: status, body: body, error: error) }
        }
        Task { await reconcileInFlight() }
    }

    var queuedCount: Int { state.pending.filter { ($0.stage ?? .queued) == .queued }.count }
    var exportedCount: Int { state.pending.filter { $0.stage == .exported }.count }
    var uploadingCount: Int { state.pending.filter { $0.stage == .uploading }.count }

    // MARK: - Setup

    func requestAuthorization() async {
        do {
            try await store.requestAuthorization(toShare: [], read: HealthExporter.readTypes.union(DailyMetricsSync.readTypes))
            try await store.enableBackgroundDelivery(for: .workoutType(), frequency: .immediate)
            authorized = true
            UserDefaults.standard.set(true, forKey: "health.authorized")
            startObserving()
        } catch {
            state.lastError = "HealthKit: \(error.localizedDescription)"
        }
    }

    /// New/changed workouts wake the app (background delivery) → sync.
    func startObserving() {
        guard authorized, observer == nil else { return }
        let query = HKObserverQuery(sampleType: .workoutType(), predicate: nil) { [weak self] _, done, _ in
            let completion = UncheckedSendable(done)
            Task { @MainActor in
                await self?.sync(budget: 20)
                completion.value()
            }
        }
        store.execute(query)
        observer = query
    }

    // MARK: - Sync

    /// Pull changes, export what we can within `budget`, hand files to the background session.
    func sync(budget: TimeInterval = 300) async {
        guard authorized, !running, await auth.isSignedIn else { return }
        running = true
        // Keep running a little after the user leaves the app.
        let bgTask = UIApplication.shared.beginBackgroundTask(withName: "health-sync")
        defer {
            running = false
            save()
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask) }
        }
        let deadline = Date.now.addingTimeInterval(budget)
        do {
            try await pullChanges()
            if !state.deletions.isEmpty {
                try await api.reportHealthDeletions(state.deletions, auth: auth)
                state.deletions = []
                save()
            }
            try await enqueueExported()
            state.pending.sort { $0.start > $1.start } // newest first
            while Date.now < deadline,
                  exportedCount + uploadingCount < maxExportedAhead,
                  let i = state.pending.firstIndex(where: { ($0.stage ?? .queued) == .queued })
            {
                let uuid = state.pending[i].uuid
                do {
                    if try await export(uuid) {
                        state.pending[i].stage = .exported
                    } else {
                        state.pending.remove(at: i) // deleted from Health meanwhile
                    }
                } catch {
                    // HealthKit is unreadable while locked: stop and retry on the next wake-up.
                    state.lastError = "export: \(error.localizedDescription)"
                    break
                }
                if exportedCount >= 10 { try await enqueueExported() } // start uploads early
            }
            try await enqueueExported()
            state.lastSync = .now
        } catch {
            state.lastError = error.localizedDescription // network/auth: next wake-up
        }
    }

    private func pullChanges() async throws {
        let anchor = state.anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let result = try await HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: anchor)
            .result(for: store)
        let known = Set(state.pending.map(\.uuid))
        for w in result.addedSamples where !known.contains(w.uuid.uuidString) {
            state.pending.append(Pending(uuid: w.uuid.uuidString, start: w.startDate))
        }
        let deleted = Set(result.deletedObjects.map(\.uuid.uuidString))
        for p in state.pending where deleted.contains(p.uuid) { removeFile(p.uuid) }
        state.pending.removeAll { deleted.contains($0.uuid) }
        state.deletions += deleted
        state.anchor = try? NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        save()
    }

    /// HealthKit → gzip file. Returns false if the workout no longer exists.
    private func export(_ uuid: String) async throws -> Bool {
        guard let id = UUID(uuidString: uuid) else { return false }
        let found = try await HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: []
        ).result(for: store)
        guard let workout = found.first else { return false }
        let dump = try await HealthExporter(store: store).dump(workout, appVersion: appVersion)
        try Gzip.compress(try dump.encoded()).write(to: Self.file(uuid), options: .atomic)
        return true
    }

    /// Hands every exported file to the background session with a fresh token.
    private func enqueueExported() async throws {
        let ready = state.pending.indices.filter { state.pending[$0].stage == .exported }
        guard !ready.isEmpty else { return }
        let token = try await auth.accessToken()
        let url = api.baseURL.appending(path: "v1/activities/healthkit")
        for i in ready {
            let uuid = state.pending[i].uuid
            guard FileManager.default.fileExists(atPath: Self.file(uuid).path) else {
                state.pending[i].stage = .queued
                continue
            }
            uploader.enqueue(file: Self.file(uuid), uuid: uuid, url: url, token: token)
            state.pending[i].stage = .uploading
        }
        save()
    }

    private func uploadFinished(uuid: String, status: Int, body: Data, error: Error?) {
        guard let i = state.pending.firstIndex(where: { $0.uuid == uuid }) else { return }
        switch status {
        case 200..<300:
            state.pending.remove(at: i)
            removeFile(uuid)
            state.uploaded += 1
            state.lastError = nil
        case 401:
            state.pending[i].stage = .exported // token expired while queued → re-enqueue
        case 400..<500:
            state.pending[i].attempts += 1
            state.lastError = "\(uuid.prefix(8)): HTTP \(status) \(String(decoding: body.prefix(200), as: UTF8.self))"
            if state.pending[i].attempts >= 3 {
                state.pending.remove(at: i)
                removeFile(uuid)
            } else {
                state.pending[i].stage = .exported
            }
        default:
            state.pending[i].stage = .exported // network / 5xx: retry later
            if let error { state.lastError = error.localizedDescription }
        }
        save()
        if state.pending.allSatisfy({ $0.stage != .uploading }) && exportedCount > 0 {
            Task { try? await enqueueExported() }
        }
    }

    /// After a relaunch: uploads the session no longer knows about go back to "exported".
    private func reconcileInFlight() async {
        let live = await uploader.inFlight()
        for i in state.pending.indices where state.pending[i].stage == .uploading && !live.contains(state.pending[i].uuid) {
            state.pending[i].stage = .exported
        }
        save()
    }

    // MARK: - Persistence

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    }
    private static var filesDir: URL { supportDir.appending(path: "health-uploads") }
    private static func file(_ uuid: String) -> URL { filesDir.appending(path: "\(uuid).json.gz") }
    private func removeFile(_ uuid: String) { try? FileManager.default.removeItem(at: Self.file(uuid)) }

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appending(path: "health-sync.json")
    }

    private static func loadState() -> State {
        guard let data = try? Data(contentsOf: url) else { return State() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? encoder.encode(state).write(to: Self.url, options: .atomic)
    }
}

/// Wraps non-Sendable callbacks that are called exactly once.
struct UncheckedSendable<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}
