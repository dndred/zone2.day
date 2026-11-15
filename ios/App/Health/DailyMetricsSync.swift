import Foundation
import HealthKit
import Zone2Kit

/// Daily health metrics → server (docs/05-sync.md §8). Reads HealthKit aggregates per local day,
/// queues them in the outbox (`daily_metrics` → POST /v1/daily-metrics). First run sends the last
/// year (baseline for the coach), then the last 8 days on every sync — late watch data replaces
/// the day on the server. A sleep observer wakes the app in the background after the night.
@MainActor
final class DailyMetricsSync {
    static let readTypes: Set<HKObjectType> = [
        HKQuantityType(.restingHeartRate),
        HKQuantityType(.heartRateVariabilitySDNN),
        HKQuantityType(.respiratoryRate),
        HKQuantityType(.appleSleepingWristTemperature),
        HKQuantityType(.bodyMass),
        HKQuantityType(.vo2Max),
        HKCategoryType(.sleepAnalysis),
    ]

    private let store = HKHealthStore()
    private let local: LocalStore
    private var observer: HKObserverQuery?
    /// Called after a background sleep update (AppModel: collect + flush the outbox).
    var onChange: (@MainActor () async -> Void)?

    private static let backfillKey = "dailyMetrics.backfilled"
    static let backfillDays = 365
    static let recentDays = 8

    init(local: LocalStore) {
        self.local = local
    }

    private var healthAuthorized: Bool { UserDefaults.standard.bool(forKey: "health.authorized") }

    /// New read types (respiratory rate, wrist temperature) need one more permission sheet: only
    /// when the app is in front.
    func requestMissingAuthorization() async {
        guard healthAuthorized else { return }
        let status = try? await store.statusForAuthorizationRequest(toShare: [], read: Self.readTypes)
        if status == .shouldRequest {
            try? await store.requestAuthorization(toShare: [], read: Self.readTypes)
        }
    }

    func startObserving() {
        guard healthAuthorized, observer == nil else { return }
        let query = HKObserverQuery(sampleType: HKCategoryType(.sleepAnalysis), predicate: nil) { [weak self] _, done, _ in
            let completion = UncheckedSendable(done)
            Task { @MainActor in
                await self?.onChange?()
                completion.value()
            }
        }
        store.execute(query)
        observer = query
        store.enableBackgroundDelivery(for: HKCategoryType(.sleepAnalysis), frequency: .hourly) { _, _ in }
    }

    /// Aggregate and queue. Returns the number of days queued (0 when Health is locked or empty).
    @discardableResult
    func collect(now: Date = .now) async -> Int {
        guard healthAuthorized else { return 0 }
        let tz = TimeZone.current
        let backfilled = UserDefaults.standard.bool(forKey: Self.backfillKey)
        let to = LocalDate.today(in: tz, now: now)
        let from = to.adding(days: -(backfilled ? Self.recentDays - 1 : Self.backfillDays - 1))
        do {
            let days = try await read(from: from, to: to, tz: tz)
            guard !days.isEmpty else { return 0 }
            let payload = try JSONEncoder().encode(DailyMetricsPayload(deviceId: try? local.deviceId(), days: days))
            // Separate ids: a pending year-long backfill is never replaced by a one-week update.
            try local.enqueue(id: backfilled ? "daily-metrics" : "daily-metrics-backfill", kind: "daily_metrics", payload: payload)
            if !backfilled { UserDefaults.standard.set(true, forKey: Self.backfillKey) }
            return days.count
        } catch {
            return 0 // HealthKit is unreadable while the phone is locked: next wake-up
        }
    }

    private func read(from: LocalDate, to: LocalDate, tz: TimeZone) async throws -> [DailyMetricsDay] {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        let start = cal.date(from: Self.components(from))!.addingTimeInterval(-12 * 3600) // night before
        let end = cal.date(byAdding: .day, value: 1, to: cal.date(from: Self.components(to))!)!
        let window = HKQuery.predicateForSamples(withStart: start, end: end)

        func quantities(_ id: HKQuantityTypeIdentifier, _ unit: HKUnit) async throws -> [MetricSample] {
            let result = try await HKSampleQueryDescriptor(
                predicates: [.quantitySample(type: HKQuantityType(id), predicate: window)],
                sortDescriptors: [SortDescriptor(\.startDate)]
            ).result(for: store)
            return result.map { MetricSample(start: $0.startDate, end: $0.endDate, value: $0.quantity.doubleValue(for: unit)) }
        }
        let bpm = HKUnit.count().unitDivided(by: .minute())
        let restingHr = try await quantities(.restingHeartRate, bpm)
        let hrv = try await quantities(.heartRateVariabilitySDNN, .secondUnit(with: .milli))
        let resp = try await quantities(.respiratoryRate, bpm)
        let temp = try await quantities(.appleSleepingWristTemperature, .degreeCelsius())
        let weight = try await quantities(.bodyMass, .gramUnit(with: .kilo))
        let vo2 = try await quantities(.vo2Max, HKUnit(from: "ml/kg*min"))

        let sleepSamples = try await HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(.sleepAnalysis), predicate: window)],
            sortDescriptors: [SortDescriptor(\.startDate)]
        ).result(for: store)
        let segments: [SleepSegment] = sleepSamples.compactMap { s in
            guard let stage = Self.stage(s.value) else { return nil }
            return SleepSegment(start: s.startDate, end: s.endDate, stage: stage, source: s.sourceRevision.source.name)
        }

        return DailyAggregation.days(
            from: from, to: to,
            restingHr: DailyAggregation.byDay(restingHr, in: tz, reduce: .last),
            hrv: DailyAggregation.byDay(hrv, in: tz, reduce: .mean),
            sleep: DailyAggregation.sleep(segments, in: tz),
            // Overnight series belong to the wake-up day, like sleep.
            respiratory: DailyAggregation.byDay(resp, in: tz, reduce: .mean, byEnd: true),
            wristTemp: DailyAggregation.byDay(temp, in: tz, reduce: .last, byEnd: true),
            weight: DailyAggregation.byDay(weight, in: tz, reduce: .last),
            vo2max: DailyAggregation.byDay(vo2, in: tz, reduce: .last)
        )
    }

    private static func components(_ d: LocalDate) -> DateComponents {
        let p = d.iso.split(separator: "-").compactMap { Int($0) }
        return DateComponents(year: p[0], month: p[1], day: p[2])
    }

    private static func stage(_ raw: Int) -> SleepSegment.Stage? {
        switch HKCategoryValueSleepAnalysis(rawValue: raw) {
        case .inBed: return .inBed
        case .asleepUnspecified: return .asleep
        case .asleepCore: return .core
        case .asleepDeep: return .deep
        case .asleepREM: return .rem
        case .awake: return .awake
        default: return nil
        }
    }
}
