import Foundation

/// Training zones from the profile, as the server builds them (backend/src/domain/zones.ts):
/// own zones → threshold model (LTHR: Friel; FTP: Coggan) → % of max HR. The app uses them to
/// colour plan profiles and to split an activity's heart rate into time per zone.
public struct ZoneSet: Sendable, Equatable {
    public enum Metric: Sendable { case hr, power }
    public let metric: Metric
    /// Lower bounds of zones 2…n (zone 1 is everything below `bounds[0]`).
    public let bounds: [Double]

    public init(metric: Metric, bounds: [Double]) {
        self.metric = metric
        self.bounds = bounds.sorted()
    }

    public var count: Int { bounds.count + 1 }

    /// Zone of a value, 1-based.
    public func zone(of value: Double) -> Int {
        (bounds.lastIndex { value >= $0 } ?? -1) + 2
    }

    /// Zone in the 5-step display scale: 7 power zones fold into 5 (Z6, Z7 → Z5).
    public func displayZone(of value: Double) -> Int { min(zone(of: value), 5) }

    /// "low–high" of a zone (1-based); the first has no low, the last no high.
    public func range(of zone: Int) -> (low: Double?, high: Double?) {
        let low = zone >= 2 ? bounds[zone - 2] : nil
        let high = zone - 1 < bounds.count ? bounds[zone - 1] - 1 : nil
        return (low, high)
    }

    /// Seconds per zone of a resampled curve (each value covers `bucketSec`); length = `count`.
    public func seconds(in values: [Double?], bucketSec: Double) -> [Double] {
        var out = [Double](repeating: 0, count: count)
        for v in values {
            guard let v, v > 0 else { continue }
            out[zone(of: v) - 1] += bucketSec
        }
        return out
    }
}

extension ZoneSet {
    /// Edwards TRIMP: minutes in HR zone k × k; 5-zone heart-rate models only, as on the server
    /// (backend/src/domain/zones.ts). The workout's load, like Strava's Relative Effort.
    public func edwardsTrimp(_ seconds: [Double]) -> Int? {
        guard metric == .hr, seconds.count == 5 else { return nil }
        return Int(seconds.enumerated().reduce(0) { $0 + $1.element / 60 * Double($1.offset + 1) }.rounded())
    }
}

extension Profile {
    /// Run zones serve every sport but the bike (the athlete's main HR model), as on the server.
    public func hrZones(for sport: Sport) -> ZoneSet? {
        let own = sport == .bike ? bike : run
        let other: SportProfile? = sport == .bike ? run : nil
        if let z = own.hrZones ?? other?.hrZones, !z.isEmpty { return ZoneSet(metric: .hr, bounds: z) }
        if let lthr = own.lthr ?? other?.lthr {
            // Friel: run 85/90/95/100 % LTHR; bike 81/90/94/100 (its own LTHR only).
            let pcts = sport == .bike && own.lthr != nil ? [0.81, 0.9, 0.94, 1] : [0.85, 0.9, 0.95, 1]
            return ZoneSet(metric: .hr, bounds: pcts.map { ($0 * lthr).rounded() })
        }
        if let max = own.maxHr ?? other?.maxHr {
            return ZoneSet(metric: .hr, bounds: [0.6, 0.7, 0.8, 0.9].map { ($0 * max).rounded() })
        }
        return nil
    }

    /// Bike power zones: own, else Coggan 7 zones from FTP. Run power has no threshold yet.
    public func powerZones(for sport: Sport) -> ZoneSet? {
        guard sport == .bike else { return nil }
        if let z = bike.powerZones, !z.isEmpty { return ZoneSet(metric: .power, bounds: z) }
        guard let ftp = bike.ftp else { return nil }
        return ZoneSet(metric: .power, bounds: [0.56, 0.76, 0.91, 1.06, 1.21, 1.51].map { ($0 * ftp).rounded() })
    }
}

/// How hard a planned step is, on the 1…5 zone scale: from its target against the athlete's zones
/// and thresholds, else from the step kind. Drives the height and colour of plan profiles.
public enum Intensity {
    public static func zone(of step: Step, sport: Sport, profile: Profile) -> Int {
        if step.kind == .rest { return 1 }
        // The main target as it is; a secondary one only as a range — a cap ("HR ≤ 140" on a
        // power step) says where not to go, not how hard the step is.
        let secondary = (step.secondary ?? []).filter { $0.low != nil && $0.high != nil }
        for t in [step.target].compactMap({ $0 }) + secondary where t.unresolved == nil {
            if let z = zone(of: t, sport: sport, profile: profile) { return z }
        }
        return byKind(step.kind)
    }

    static func byKind(_ kind: Step.Kind) -> Int {
        switch kind {
        case .rest, .recovery: 1
        case .warmup, .cooldown: 2
        case .work: 3
        case .drill: 4
        }
    }

    /// A representative value of a target: the middle of a range, just inside an open bound.
    static func value(_ t: Target, step: Double) -> Double? {
        switch (t.low, t.high) {
        case let (l?, h?): (l + h) / 2
        case let (nil, h?): h - step
        case let (l?, nil): l + step
        default: nil
        }
    }

    public static func zone(of t: Target, sport: Sport, profile: Profile) -> Int? {
        switch t.metric {
        case .hr:
            guard let v = value(t, step: 1), let z = profile.hrZones(for: sport) else { return nil }
            return z.displayZone(of: v)
        case .power:
            guard let v = value(t, step: 1) else { return nil }
            if let z = profile.powerZones(for: sport) { return z.displayZone(of: v) }
            return nil
        case .pace:
            // Share of threshold speed (pace low = faster): Z1 < 78 %, Z2 < 88, Z3 < 95, Z4 < 100.
            let threshold = sport == .swim ? profile.swim.cssSecPer100m : profile.run.thresholdPaceSecPerKm
            guard let threshold, let v = value(t, step: 0), v > 0 else { return nil }
            let share = threshold / v
            return share < 0.78 ? 1 : share < 0.88 ? 2 : share < 0.95 ? 3 : share < 1.0 ? 4 : 5
        case .rpe:
            guard let v = value(t, step: 0) else { return nil }
            return v <= 3 ? 1 : v <= 4 ? 2 : v <= 6 ? 3 : v <= 8 ? 4 : 5
        case .speed, .cadence:
            return nil
        }
    }
}
