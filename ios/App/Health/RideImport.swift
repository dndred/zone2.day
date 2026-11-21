import Foundation
import HealthKit
import Zone2Kit

/// Rides recorded by zone2 Ride on the Mac (no HealthKit there) → Apple Health, so the Fitness app
/// has every workout (docs/11-trainer.md §2a). The server keeps the ride; the phone fetches its
/// dump and writes an indoor-cycling HKWorkout with heart rate, power, cadence, speed, distance and
/// the plan's steps as segments. The written workout carries `zone2.activityId`: HealthSync skips
/// it on export (it is already on the server) and the next run sees it is done.
@MainActor
final class RideImport {
    static let bundle = "day.zone2.ride"
    static let activityKey = "zone2.activityId"

    private let store = HKHealthStore()
    private let api: APIClient
    private let auth: AuthSession
    private(set) var lastError: String?
    /// Activity ids written (or found) in Health; the HealthKit query stays the source of truth.
    private var written: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "rideImport.written") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "rideImport.written") }
    }

    init(api: APIClient, auth: AuthSession) {
        self.api = api
        self.auth = auth
    }

    static let shareTypes: Set<HKSampleType> = [
        .workoutType(),
        HKQuantityType(.heartRate),
        HKQuantityType(.cyclingPower),
        HKQuantityType(.cyclingCadence),
        HKQuantityType(.cyclingSpeed),
        HKQuantityType(.distanceCycling),
        HKQuantityType(.activeEnergyBurned),
    ]

    /// Asks for write access once (only from the foreground: the sheet needs the app on screen).
    func requestAuthorizationIfNeeded() async {
        guard store.authorizationStatus(for: .workoutType()) == .notDetermined else { return }
        try? await store.requestAuthorization(toShare: Self.shareTypes, read: [.workoutType()])
    }

    /// Rides of the last two weeks not yet in Health.
    func run(local: LocalStore) async {
        guard store.authorizationStatus(for: .workoutType()) == .sharingAuthorized else { return }
        let today = LocalDate.today(in: .current)
        guard let snap = try? local.snapshot(from: today.adding(days: -14), to: today) else { return }
        let rides = snap.days.flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }
            .filter { $0.summary.sourceBundle == Self.bundle && !written.contains($0.id) }
        for ride in rides {
            do {
                if try await !inHealth(Self.activityKey, ride.id) {
                    let dump = try await api.activityDump(ride.id, auth: auth)
                    // The other copy of the app (prod / staging) may have written the same ride.
                    if try await !inHealth(HKMetadataKeyExternalUUID, dump.workout.uuid) {
                        try await write(dump, activityId: ride.id, plannedWorkoutId: ride.plannedWorkoutId)
                    }
                }
                written.insert(ride.id)
                lastError = nil
            } catch {
                lastError = "ride \(ride.id.prefix(8)): \(error.localizedDescription)"
            }
        }
    }

    private func inHealth(_ key: String, _ value: String) async throws -> Bool {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: key, allowedValues: [value])
        let found = try await HKSampleQueryDescriptor(predicates: [.workout(predicate)], sortDescriptors: [], limit: 1)
            .result(for: store)
        return !found.isEmpty
    }

    private func write(_ dump: HealthKitDump, activityId: String, plannedWorkoutId: String?) async throws {
        guard let start = Self.date(dump.workout.start), let end = Self.date(dump.workout.end) else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .cycling
        config.locationType = .indoor
        let builder = HKWorkoutBuilder(healthStore: store, configuration: config, device: nil)
        try await builder.beginCollection(at: start)

        var samples: [HKSample] = []
        let at = { (offset: Double) in start.addingTimeInterval(offset) }
        func add(_ key: String, _ id: HKQuantityTypeIdentifier, _ unit: HKUnit, instant: Bool) {
            for v in dump.samples[key]?.values ?? [] where v.count == 3 {
                let s = at(v[0]), e = instant ? s : max(at(v[1]), s)
                samples.append(HKQuantitySample(type: HKQuantityType(id), quantity: HKQuantity(unit: unit, doubleValue: v[2]), start: s, end: e))
            }
        }
        let perMin = HKUnit.count().unitDivided(by: .minute())
        // Heart rate from HeartCast repeats for ~5 s: one sample per change is enough.
        let hr = dump.samples["heartRate"]?.values.filter { $0.count == 3 } ?? []
        for (i, v) in hr.enumerated() where i == 0 || v[2] != hr[i - 1][2] {
            samples.append(HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: perMin, doubleValue: v[2]), start: at(v[0]), end: at(v[0])))
        }
        add("cyclingPower", .cyclingPower, .watt(), instant: true)
        add("cyclingCadence", .cyclingCadence, perMin, instant: true)
        add("cyclingSpeed", .cyclingSpeed, HKUnit.meter().unitDivided(by: .second()), instant: true)
        samples += Self.chunks(dump.samples["distanceCycling"], seconds: 10, start: start) { s, e, m in
            HKQuantitySample(type: HKQuantityType(.distanceCycling), quantity: HKQuantity(unit: .meter(), doubleValue: m), start: s, end: e)
        }
        if let kcal = dump.workout.totalEnergyKcal, kcal > 0 {
            samples.append(HKQuantitySample(type: HKQuantityType(.activeEnergyBurned), quantity: HKQuantity(unit: .kilocalorie(), doubleValue: kcal), start: start, end: end))
        }
        for batch in stride(from: 0, to: samples.count, by: 2000) {
            try await builder.addSamples(Array(samples[batch..<min(batch + 2000, samples.count)]))
        }

        let events: [HKWorkoutEvent] = dump.workout.events.compactMap { e in
            guard let s = Self.date(e.start), let t = Self.date(e.end) else { return nil }
            let type: HKWorkoutEventType
            switch e.type {
            case "pause": type = .pause
            case "resume": type = .resume
            case "segment": type = .segment
            default: return nil
            }
            var meta: [String: Any] = [:]
            if case .string(let label)? = e.metadata["zone2.step"] { meta["zone2.step"] = label }
            return HKWorkoutEvent(type: type, dateInterval: DateInterval(start: s, end: max(s, t)), metadata: meta.isEmpty ? nil : meta)
        }
        if !events.isEmpty { try await builder.addWorkoutEvents(events) }

        var meta: [String: Any] = [HKMetadataKeyIndoorWorkout: true, Self.activityKey: activityId,
                                   HKMetadataKeyExternalUUID: dump.workout.uuid]
        if let plannedWorkoutId { meta["zone2.plannedWorkoutId"] = plannedWorkoutId }
        if case .string(let tz)? = dump.workout.metadata["HKTimeZone"] { meta[HKMetadataKeyTimeZone] = tz }
        if case .string(let trainer)? = dump.workout.metadata["zone2.trainer"] { meta["zone2.trainer"] = trainer }
        try await builder.addMetadata(meta)
        try await builder.endCollection(at: end)
        _ = try await builder.finishWorkout()
    }

    /// 1-second distance samples → one per `seconds` (fewer objects in Health, same total).
    static func chunks(_ series: HealthKitDump.SampleSeries?, seconds: Double, start: Date,
                       make: (Date, Date, Double) -> HKQuantitySample) -> [HKQuantitySample] {
        var out: [HKQuantitySample] = []
        var from: Double?, to = 0.0, sum = 0.0
        for v in series?.values ?? [] where v.count == 3 {
            if let f = from, v[0] - f >= seconds || v[0] > to + 1 {
                if sum > 0 { out.append(make(start.addingTimeInterval(f), start.addingTimeInterval(to), sum)) }
                from = nil
                sum = 0
            }
            if from == nil { from = v[0] }
            to = v[1]
            sum += v[2]
        }
        if let f = from, sum > 0 { out.append(make(start.addingTimeInterval(f), start.addingTimeInterval(to), sum)) }
        return out
    }

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
