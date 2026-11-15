import Foundation

// Daily health metrics (docs/05-sync.md §7): the app reads HealthKit, aggregates each local day
// here (pure, testable) and sends days through the outbox to POST /v1/daily-metrics, where the
// coach compares them with the athlete's own baseline. Each day is sent whole and replaces the
// server's copy, so late watch syncs are fixed by resending the last week.

public struct SleepSummary: Codable, Sendable, Equatable {
    public var asleepMin: Double
    public var deepMin: Double?
    public var remMin: Double?
    public var coreMin: Double?
    public var awakeMin: Double?
    public var inBedStart: String?
    public var inBedEnd: String?
    public var source: String?
}

public struct DailyMetricsDay: Codable, Sendable, Equatable {
    public let date: LocalDate
    public var restingHr: Double?
    public var hrvSdnnMs: Double?
    public var hrvSamples: Int?
    public var sleep: SleepSummary?
    public var respiratoryRate: Double?
    public var wristTempC: Double?
    public var weightKg: Double?
    public var vo2max: Double?

    public init(date: LocalDate) { self.date = date }

    public var isEmpty: Bool {
        restingHr == nil && hrvSdnnMs == nil && sleep == nil && respiratoryRate == nil
            && wristTempC == nil && weightKg == nil && vo2max == nil
    }
}

public struct DailyMetricsPayload: Codable, Sendable, Equatable {
    public let deviceId: String?
    public let days: [DailyMetricsDay]

    public init(deviceId: String?, days: [DailyMetricsDay]) {
        self.deviceId = deviceId
        self.days = days
    }
}

/// One HealthKit sleep-analysis sample, already mapped from HKCategoryValueSleepAnalysis.
public struct SleepSegment: Sendable, Equatable {
    public enum Stage: Sendable, Equatable { case inBed, asleep, core, deep, rem, awake }
    public let start: Date
    public let end: Date
    public let stage: Stage
    public let source: String

    public init(start: Date, end: Date, stage: Stage, source: String) {
        self.start = start
        self.end = end
        self.stage = stage
        self.source = source
    }
}

/// A quantity sample reduced to its time and value (in the unit the server expects).
public struct MetricSample: Sendable, Equatable {
    public let start: Date
    public let end: Date
    public let value: Double

    public init(start: Date, end: Date, value: Double) {
        self.start = start
        self.end = end
        self.value = value
    }
}

public enum DailyAggregation {
    /// Local calendar date of an instant in `tz`.
    public static func localDate(_ d: Date, in tz: TimeZone) -> LocalDate {
        LocalDate.today(in: tz, now: d)
    }

    /// A gap longer than this between sleep samples starts a new sleep session.
    static let sessionGap: TimeInterval = 3 * 3600

    /// Sleep per wake-up date. Several apps may write sleep (watch, phone, a third-party ring):
    /// per night we keep the one source with the most time asleep, so nothing is counted twice.
    public static func sleep(_ segments: [SleepSegment], in tz: TimeZone) -> [LocalDate: SleepSummary] {
        var out: [LocalDate: SleepSummary] = [:]
        let bySource = Dictionary(grouping: segments, by: \.source)
        var candidates: [LocalDate: [(source: String, summary: SleepSummary)]] = [:]
        for (source, segs) in bySource {
            for session in sessions(segs.sorted { $0.start < $1.start }) {
                guard let last = session.map(\.end).max(), let first = session.map(\.start).min() else { continue }
                let date = localDate(last, in: tz)
                var s = summarize(session, source: source)
                s.inBedStart = iso(first, tz)
                s.inBedEnd = iso(last, tz)
                guard s.asleepMin > 0 else { continue }
                // Naps and the night of one source on one date add up.
                if let i = candidates[date]?.firstIndex(where: { $0.source == source }) {
                    candidates[date]![i].summary = merge(candidates[date]![i].summary, s)
                } else {
                    candidates[date, default: []].append((source, s))
                }
            }
        }
        for (date, list) in candidates {
            out[date] = list.max { $0.summary.asleepMin < $1.summary.asleepMin }?.summary
        }
        return out
    }

    static func sessions(_ segs: [SleepSegment]) -> [[SleepSegment]] {
        var out: [[SleepSegment]] = []
        var cur: [SleepSegment] = []
        var curEnd = Date.distantPast
        for s in segs {
            if !cur.isEmpty, s.start.timeIntervalSince(curEnd) > sessionGap {
                out.append(cur)
                cur = []
            }
            cur.append(s)
            curEnd = max(curEnd, s.end)
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    static func summarize(_ segs: [SleepSegment], source: String) -> SleepSummary {
        var mins: [SleepSegment.Stage: Double] = [:]
        for s in segs { mins[s.stage, default: 0] += s.end.timeIntervalSince(s.start) / 60 }
        let staged = (mins[.core] ?? 0) + (mins[.deep] ?? 0) + (mins[.rem] ?? 0)
        let hasStages = staged > 0
        return SleepSummary(
            asleepMin: round1(staged + (mins[.asleep] ?? 0)),
            deepMin: hasStages ? round1(mins[.deep] ?? 0) : nil,
            remMin: hasStages ? round1(mins[.rem] ?? 0) : nil,
            coreMin: hasStages ? round1(mins[.core] ?? 0) : nil,
            awakeMin: mins[.awake].map(round1),
            source: source
        )
    }

    static func merge(_ a: SleepSummary, _ b: SleepSummary) -> SleepSummary {
        func add(_ x: Double?, _ y: Double?) -> Double? { x == nil && y == nil ? nil : round1((x ?? 0) + (y ?? 0)) }
        return SleepSummary(
            asleepMin: round1(a.asleepMin + b.asleepMin),
            deepMin: add(a.deepMin, b.deepMin), remMin: add(a.remMin, b.remMin),
            coreMin: add(a.coreMin, b.coreMin), awakeMin: add(a.awakeMin, b.awakeMin),
            inBedStart: [a.inBedStart, b.inBedStart].compactMap { $0 }.min(),
            inBedEnd: [a.inBedEnd, b.inBedEnd].compactMap { $0 }.max(),
            source: a.source
        )
    }

    public enum Reduce: Sendable { case mean, last }

    /// Samples per local date (of the sample's start, or end for overnight series), reduced.
    public static func byDay(_ xs: [MetricSample], in tz: TimeZone, reduce: Reduce, byEnd: Bool = false)
        -> [LocalDate: (value: Double, count: Int)]
    {
        let groups = Dictionary(grouping: xs) { localDate(byEnd ? $0.end : $0.start, in: tz) }
        return groups.mapValues { g in
            switch reduce {
            case .mean: return (g.map(\.value).reduce(0, +) / Double(g.count), g.count)
            case .last: return (g.max { $0.start < $1.start }!.value, g.count)
            }
        }
    }

    static func round1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    static func iso(_ d: Date, _ tz: TimeZone) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = tz
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: d)
    }

    /// Assemble days in [from, to] from per-metric aggregates; days without any data are dropped.
    public static func days(
        from: LocalDate, to: LocalDate,
        restingHr: [LocalDate: (value: Double, count: Int)],
        hrv: [LocalDate: (value: Double, count: Int)],
        sleep: [LocalDate: SleepSummary],
        respiratory: [LocalDate: (value: Double, count: Int)],
        wristTemp: [LocalDate: (value: Double, count: Int)],
        weight: [LocalDate: (value: Double, count: Int)],
        vo2max: [LocalDate: (value: Double, count: Int)]
    ) -> [DailyMetricsDay] {
        var out: [DailyMetricsDay] = []
        var d = from
        while d <= to {
            var day = DailyMetricsDay(date: d)
            day.restingHr = restingHr[d].map { round1($0.value) }
            if let h = hrv[d] {
                day.hrvSdnnMs = round1(h.value)
                day.hrvSamples = h.count
            }
            day.sleep = sleep[d]
            day.respiratoryRate = respiratory[d].map { round1($0.value) }
            day.wristTempC = wristTemp[d].map { ($0.value * 100).rounded() / 100 }
            day.weightKg = weight[d].map { round1($0.value) }
            day.vo2max = vo2max[d].map { round1($0.value) }
            if !day.isEmpty { out.append(day) }
            d = d.adding(days: 1)
        }
        return out
    }
}
