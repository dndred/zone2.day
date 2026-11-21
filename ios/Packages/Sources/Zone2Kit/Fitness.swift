import Foundation

/// Fitness, fatigue and form from daily load (the Banister impulse-response model as in
/// TrainingPeaks and HealthFit): fitness (CTL) is a 42-day exponential average of daily TRIMP,
/// fatigue (ATL) a 7-day one, form (TSB) yesterday's fitness minus yesterday's fatigue.
public enum Fitness {
    public struct Day: Sendable, Equatable {
        public let date: LocalDate
        public let load: Double
        public let fitness: Double
        public let fatigue: Double
        public var form: Double
    }

    public static let fitnessDays = 42.0
    public static let fatigueDays = 7.0

    /// One value per day from the first day with load (both averages start at zero) through `to`.
    public static func series(loads: [LocalDate: Double], to: LocalDate) -> [Day] {
        guard let first = loads.keys.min(), first <= to else { return [] }
        var out: [Day] = []
        var ctl = 0.0, atl = 0.0
        var d = first
        while d <= to {
            let load = loads[d] ?? 0
            let form = ctl - atl
            ctl += (load - ctl) / fitnessDays
            atl += (load - atl) / fatigueDays
            out.append(Day(date: d, load: load, fitness: ctl, fatigue: atl, form: form))
            d = d.adding(days: 1)
        }
        return out
    }

    /// Daily load of activities with a server TRIMP (recovery ones included: they are load too).
    public static func loads(_ activities: [Activity]) -> [LocalDate: Double] {
        activities.reduce(into: [:]) { acc, a in
            if let t = a.summary.analysis?.trimp { acc[a.date, default: 0] += t }
        }
    }
}
