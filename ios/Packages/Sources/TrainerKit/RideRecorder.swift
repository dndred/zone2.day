import Foundation
import Zone2Kit

/// One ride on the trainer: collects raw readings, keeps live values for the screen, and samples
/// 1 Hz for the record. The record is a HealthKitDump (indoor cycling) so the server and
/// `dumpToFit` treat it like any other workout (docs/11-trainer.md §4, D50).
public struct RideRecorder: Sendable {
    public struct Second: Codable, Equatable, Sendable {
        public var t: Int
        public var powerW: Int?
        public var cadenceRpm: Double?
        public var speedKmh: Double?
        public var heartRate: Int?
    }

    public private(set) var start: Date?
    public private(set) var seconds: [Second] = []
    public private(set) var distanceM: Double = 0

    // Latest readings with their time; stale readings are not recorded.
    private var power: (Int, Date)?
    private var cadence: (Double, Date)?
    private var speed: (Double, Date)?
    private var heart: (Int, Date)?
    private var recentPower: [(Date, Int)] = []

    /// Readings older than this are "no data". Trainer sends ~4 Hz; HeartCast every 3–5 s.
    public static let trainerStale: TimeInterval = 3
    public static let heartStale: TimeInterval = 10

    public init() {}

    public var isRecording: Bool { start != nil }

    public mutating func trainer(_ d: IndoorBikeData, at now: Date) {
        if let p = d.powerW {
            power = (p, now)
            recentPower.append((now, p))
            recentPower.removeAll { now.timeIntervalSince($0.0) > 3 }
        }
        if let c = d.cadenceRpm { cadence = (c, now) }
        if let s = d.speedKmh { speed = (s, now) }
    }

    public mutating func heartRate(_ bpm: Int?, at now: Date) {
        if let bpm { heart = (bpm, now) } else { heart = nil }
    }

    // MARK: Live values

    public func powerNow(_ now: Date) -> Int? { fresh(power, now, Self.trainerStale) }
    public func cadenceNow(_ now: Date) -> Double? { fresh(cadence, now, Self.trainerStale) }
    public func speedNow(_ now: Date) -> Double? { fresh(speed, now, Self.trainerStale) }
    public func heartNow(_ now: Date) -> Int? { fresh(heart, now, Self.heartStale) }

    /// 3-second average power (what the screen shows big).
    public func power3s(_ now: Date) -> Int? {
        let xs = recentPower.filter { now.timeIntervalSince($0.0) <= 3 }.map(\.1)
        guard !xs.isEmpty, powerNow(now) != nil else { return nil }
        return Int((Double(xs.reduce(0, +)) / Double(xs.count)).rounded())
    }

    public var elapsed: Int { seconds.count }

    public var averagePower: Int? {
        let xs = seconds.compactMap(\.powerW)
        return xs.isEmpty ? nil : xs.reduce(0, +) / xs.count
    }

    public var averageHeartRate: Int? {
        let xs = seconds.compactMap(\.heartRate)
        return xs.isEmpty ? nil : xs.reduce(0, +) / xs.count
    }

    /// Normalized power: 30 s rolling mean, ^4, mean, ^¼ (missing seconds count as 0 W).
    public var normalizedPower: Int? {
        let p = seconds.map { Double($0.powerW ?? 0) }
        guard p.count >= 30 else { return nil }
        var sum = p[0..<30].reduce(0, +), acc = pow(sum / 30, 4), n = 1.0
        for i in 30..<p.count {
            sum += p[i] - p[i - 30]
            acc += pow(sum / 30, 4)
            n += 1
        }
        return Int(pow(acc / n, 0.25).rounded())
    }

    // MARK: Recording

    public mutating func begin(at now: Date) {
        start = now
        seconds = []
        distanceM = 0
    }

    /// Call once a second while recording.
    public mutating func tick(at now: Date) {
        guard start != nil else { return }
        let s = Second(t: seconds.count, powerW: powerNow(now), cadenceRpm: cadenceNow(now),
                       speedKmh: speedNow(now), heartRate: heartNow(now))
        distanceM += (s.speedKmh ?? 0) / 3.6
        seconds.append(s)
    }

    /// The ride as a HealthKit-shaped dump: one sample per second per metric.
    public func dump(trainer: String?, heartSource: String?, appVersion: String) -> HealthKitDump? {
        guard let start, !seconds.isEmpty else { return nil }
        let end = start.addingTimeInterval(Double(seconds.count))
        func series(_ unit: String, _ value: (Second) -> Double?) -> HealthKitDump.SampleSeries? {
            let vs = seconds.compactMap { s in value(s).map { [Double(s.t), Double(s.t + 1), $0] } }
            return vs.isEmpty ? nil : .init(unit: unit, values: vs)
        }
        var samples: [String: HealthKitDump.SampleSeries] = [:]
        samples["heartRate"] = series("count/min") { $0.heartRate.map(Double.init) }
        samples["cyclingPower"] = series("W") { $0.powerW.map(Double.init) }
        samples["cyclingCadence"] = series("count/min") { $0.cadenceRpm }
        samples["cyclingSpeed"] = series("m/s") { $0.speedKmh.map { $0 / 3.6 } }
        samples["distanceCycling"] = series("m") { $0.speedKmh.map { $0 / 3.6 } }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var meta: [String: HealthKitDump.MetaValue] = [
            "HKIndoorWorkout": .bool(true),
            "HKTimeZone": .string(TimeZone.current.identifier),
        ]
        if let trainer { meta["zone2.trainer"] = .string(trainer) }
        if let heartSource { meta["zone2.heartRateSource"] = .string(heartSource) }
        let id = "zone2-ride-\(Int(start.timeIntervalSince1970))"
        return HealthKitDump(
            exportedAt: iso.string(from: Date()),
            app: .init(version: appVersion),
            workout: .init(
                uuid: id, activityType: 13, start: iso.string(from: start), end: iso.string(from: end),
                durationSec: Double(seconds.count), totalDistanceM: distanceM > 0 ? distanceM : nil,
                totalEnergyKcal: energyKcal, source: .init(name: "zone2 Ride (Mac)", bundleId: "day.zone2.ride"),
                device: .init(name: trainer, model: nil, hardwareVersion: nil, softwareVersion: nil),
                metadata: meta, activities: [], events: []),
            samples: samples, route: [])
    }

    /// Mechanical work in kJ ≈ kcal burned (gross efficiency ~24 % cancels the 4.184 factor).
    public var energyKcal: Double? {
        let j = seconds.compactMap(\.powerW).reduce(0, +)
        return j > 0 ? Double(j) / 1000 : nil
    }

    private func fresh<T>(_ v: (T, Date)?, _ now: Date, _ maxAge: TimeInterval) -> T? {
        guard let v, now.timeIntervalSince(v.1) <= maxAge else { return nil }
        return v.0
    }
}
