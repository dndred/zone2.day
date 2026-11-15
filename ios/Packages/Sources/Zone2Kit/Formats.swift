import Foundation

/// Unit labels. `.current` follows the app language (String Catalog of this package); tests use
/// `.english` so they do not depend on the Mac's language.
public struct Units: Sendable {
    public var km, m, perKm, per100m, bpm, watt, spm, rpm, kmh, sec, min, hour, kcal, cm, ms, kg: String

    public static let english = Units(
        km: "km", m: "m", perKm: "/km", per100m: "/100m", bpm: "bpm", watt: "W", spm: "spm", rpm: "rpm",
        kmh: "km/h", sec: "s", min: "min", hour: "h", kcal: "kcal", cm: "cm", ms: "ms", kg: "kg"
    )

    public static var current: Units {
        func l(_ k: String.LocalizationValue) -> String { String(localized: k, bundle: .module) }
        return Units(
            km: l("km"), m: l("m"), perKm: l("/km"), per100m: l("/100m"), bpm: l("bpm"), watt: l("W"),
            spm: l("spm"), rpm: l("rpm"), kmh: l("km/h"), sec: l("s"), min: l("min"), hour: l("h"),
            kcal: l("kcal"), cm: l("cm"), ms: l("ms"), kg: l("kg")
        )
    }
}

/// Number formatting for plan and activity screens. Units follow SI in data (rule 5); here they
/// become what an athlete reads: m:ss /km, km with one decimal, h:mm:ss.
public enum Formats {
    /// 75 → "1:15", 3725 → "1:02:05".
    public static func clock(_ sec: Double) -> String {
        let s = Int(sec.rounded())
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
    }

    /// Step length: under a minute in seconds ("12 s"), whole minutes as "10 min", else clock.
    public static func stepTime(_ sec: Int, units u: Units = .current) -> String {
        if sec < 60 { return "\(sec) \(u.sec)" }
        if sec % 60 == 0 && sec < 3600 { return "\(sec / 60) \(u.min)" }
        return clock(Double(sec))
    }

    /// Totals for a week: "45 min", "3 h 05 min".
    public static func hoursMinutes(_ sec: Double, units u: Units = .current) -> String {
        let total = Int((sec / 60).rounded())
        return total < 60 ? "\(total) \(u.min)" : String(format: "%d %@ %02d %@", total / 60, u.hour, total % 60, u.min)
    }

    /// 400 → "400 m", 1000 → "1 km", 5063 → "5.06 km", 12345 → "12.3 km".
    public static func distance(_ m: Double, locale: Locale = .current, units u: Units = .current) -> String {
        if m < 1000 { return "\(Int(m.rounded())) \(u.m)" }
        let km = m / 1000
        let digits = km.rounded() == km ? 0 : km < 10 ? 2 : 1
        return km.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " " + u.km
    }

    /// Seconds per km → "5:01 /km".
    public static func pace(_ secPerKm: Double, units u: Units = .current) -> String { clock(secPerKm) + " " + u.perKm }

    public static func pace100(_ secPer100: Double, units u: Units = .current) -> String { clock(secPer100) + " " + u.per100m }

    /// "low–high unit", with ≤/≥ when one bound is open.
    static func range(_ low: Double?, _ high: Double?, _ f: (Double) -> String) -> String {
        switch (low, high) {
        case let (l?, h?) where l == h: f(l)
        case let (l?, h?): "\(f(l))–\(f(h))"
        case let (l?, nil): "≥ \(f(l))"
        case let (nil, h?): "≤ \(f(h))"
        default: ""
        }
    }

    /// Target in absolute units as the watch will show it. Pace low/high are sec/km (low = faster).
    public static func target(_ t: Target, sport: Sport, units u: Units = .current) -> String {
        let int = { (x: Double) in String(Int(x.rounded())) }
        switch t.metric {
        case .hr: return range(t.low, t.high, int) + " " + u.bpm
        case .power: return range(t.low, t.high, int) + " " + u.watt
        case .rpe: return "RPE " + range(t.low, t.high) { x in x.rounded() == x ? int(x) : String(format: "%.1f", x) }
        case .cadence: return range(t.low, t.high, int) + " " + (sport == .bike ? u.rpm : u.spm)
        case .speed: return range(t.low.map { $0 * 3.6 }, t.high.map { $0 * 3.6 }) { String(format: "%.1f", $0) } + " " + u.kmh
        case .pace:
            let unit = " " + (sport == .swim ? u.per100m : u.perKm)
            return range(t.low, t.high) { clock($0) } + unit
        }
    }

    public static func duration(_ d: StepDuration, units u: Units = .current) -> String? {
        switch d {
        case .time(let sec): stepTime(sec, units: u)
        case .distance(let m): distance(m, units: u)
        case .open: nil
        }
    }

    /// Rough seconds of a step for proportional bars: time as is, distance via the pace target
    /// (or a default pace by sport), open via its estimate.
    public static func estimatedSeconds(_ step: Step, sport: Sport) -> Double {
        switch step.duration {
        case .time(let sec): return Double(sec)
        case .open(let est): return Double(est ?? 300)
        case .distance(let m):
            let paceTarget = ([step.target] + (step.secondary ?? [])).compactMap { $0 }.first { $0.metric == .pace }
            let pace = paceTarget.flatMap { t in [t.low, t.high].compactMap { $0 }.max() }
            switch sport {
            case .swim: return m / 100 * (pace ?? 120)
            case .bike: return m / 8.3
            default: return m / 1000 * (pace ?? 330)
            }
        }
    }
}
