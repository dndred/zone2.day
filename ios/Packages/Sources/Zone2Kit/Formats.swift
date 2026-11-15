import Foundation

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
    public static func stepTime(_ sec: Int) -> String {
        if sec < 60 { return "\(sec) s" }
        if sec % 60 == 0 && sec < 3600 { return "\(sec / 60) min" }
        return clock(Double(sec))
    }

    /// 400 → "400 m", 1000 → "1 km", 5063 → "5.06 km", 12345 → "12.3 km".
    public static func distance(_ m: Double, locale: Locale = .current) -> String {
        if m < 1000 { return "\(Int(m.rounded())) m" }
        let km = m / 1000
        let digits = km.rounded() == km ? 0 : km < 10 ? 2 : 1
        return km.formatted(.number.precision(.fractionLength(digits)).locale(locale)) + " km"
    }

    /// Seconds per km → "5:01 /km".
    public static func pace(_ secPerKm: Double) -> String { clock(secPerKm) + " /km" }

    public static func pace100(_ secPer100: Double) -> String { clock(secPer100) + " /100m" }

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
    public static func target(_ t: Target, sport: Sport) -> String {
        let int = { (x: Double) in String(Int(x.rounded())) }
        switch t.metric {
        case .hr: return range(t.low, t.high, int) + " bpm"
        case .power: return range(t.low, t.high, int) + " W"
        case .rpe: return "RPE " + range(t.low, t.high) { x in x.rounded() == x ? int(x) : String(format: "%.1f", x) }
        case .cadence: return range(t.low, t.high, int) + (sport == .bike ? " rpm" : " spm")
        case .speed: return range(t.low.map { $0 * 3.6 }, t.high.map { $0 * 3.6 }) { String(format: "%.1f", $0) } + " km/h"
        case .pace:
            let unit = sport == .swim ? " /100m" : " /km"
            return range(t.low, t.high) { clock($0) } + unit
        }
    }

    public static func duration(_ d: StepDuration) -> String? {
        switch d {
        case .time(let sec): stepTime(sec)
        case .distance(let m): distance(m)
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
