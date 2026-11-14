import Foundation
import HealthKit
import Zone2Kit

/// Workout upload queue on top of an HKAnchoredObjectQuery anchor (docs/05-sync.md §6).
/// First run = backfill of the whole history (newest first). Deletions are reported too.
@MainActor
final class HealthSync: ObservableObject {
    struct Pending: Codable, Hashable {
        let uuid: String
        let start: Date
        var attempts: Int = 0
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

    private let store = HKHealthStore()
    private let api: APIClient
    private let auth: AuthSession
    private let appVersion: String
    private var observer: HKObserverQuery?

    init(api: APIClient, auth: AuthSession) {
        self.api = api
        self.auth = auth
        self.appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        state = Self.loadState()
        authorized = UserDefaults.standard.bool(forKey: "health.authorized")
    }

    // MARK: - Setup

    func requestAuthorization() async {
        do {
            try await store.requestAuthorization(toShare: [], read: HealthExporter.readTypes)
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

    /// Runs until the queue is empty or `budget` seconds pass (background time is limited).
    func sync(budget: TimeInterval = 120) async {
        guard authorized, !running, await auth.isSignedIn else { return }
        running = true
        defer { running = false; save() }
        let deadline = Date.now.addingTimeInterval(budget)
        do {
            try await pullChanges()
            if !state.deletions.isEmpty {
                try await api.reportHealthDeletions(state.deletions, auth: auth)
                state.deletions = []
                save()
            }
            state.pending.sort { $0.start > $1.start } // newest first: useful history arrives first
            while let next = state.pending.first, Date.now < deadline {
                do {
                    try await upload(next.uuid)
                    state.pending.removeFirst()
                    state.uploaded += 1
                    state.lastError = nil
                } catch let error as APIError {
                    // Server rejected this workout → move it to the back, give up after 3 tries.
                    var item = state.pending.removeFirst()
                    item.attempts += 1
                    if item.attempts < 3 { state.pending.append(item) }
                    state.lastError = "\(next.uuid.prefix(8)): \(error)"
                }
                save()
            }
            state.lastSync = .now
        } catch {
            state.lastError = error.localizedDescription // network/auth: try again next wake-up
        }
    }

    private func pullChanges() async throws {
        let anchor = state.anchor.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: HKQueryAnchor.self, from: $0)
        }
        let descriptor = HKAnchoredObjectQueryDescriptor(predicates: [.workout()], anchor: anchor)
        let result = try await descriptor.result(for: store)
        let known = Set(state.pending.map(\.uuid))
        for w in result.addedSamples where !known.contains(w.uuid.uuidString) {
            state.pending.append(Pending(uuid: w.uuid.uuidString, start: w.startDate))
        }
        let deleted = result.deletedObjects.map(\.uuid.uuidString)
        state.pending.removeAll { deleted.contains($0.uuid) }
        state.deletions += deleted
        state.anchor = try? NSKeyedArchiver.archivedData(withRootObject: result.newAnchor, requiringSecureCoding: true)
        save()
    }

    private func upload(_ uuid: String) async throws {
        guard let id = UUID(uuidString: uuid) else { return }
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.workout(HKQuery.predicateForObject(with: id))], sortDescriptors: []
        )
        guard let workout = try await descriptor.result(for: store).first else { return } // deleted meanwhile
        let dump = try await HealthExporter(store: store).dump(workout, appVersion: appVersion)
        _ = try await api.uploadHealthKit(try dump.encoded(), auth: auth)
    }

    // MARK: - Persistence

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
