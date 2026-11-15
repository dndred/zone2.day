import Foundation
import Testing
@testable import Zone2Kit

@Test func clockAndDistance() {
    #expect(Formats.clock(75) == "1:15")
    #expect(Formats.clock(3725) == "1:02:05")
    #expect(Formats.stepTime(12, units: .english) == "12 s")
    #expect(Formats.stepTime(600, units: .english) == "10 min")
    #expect(Formats.stepTime(105) == "1:45")
    let en = Locale(identifier: "en_US")
    #expect(Formats.distance(400, locale: en, units: .english) == "400 m")
    #expect(Formats.distance(1000, locale: en, units: .english) == "1 km")
    #expect(Formats.distance(5062.7, locale: en, units: .english) == "5.06 km")
    #expect(Formats.distance(11684, locale: en, units: .english) == "11.7 km")
    #expect(Formats.pace(301, units: .english) == "5:01 /km")
    #expect(Formats.hoursMinutes(2700, units: .english) == "45 min")
    #expect(Formats.hoursMinutes(11100, units: .english) == "3 h 05 min")
}

@Test func targets() {
    func t(_ m: Target.Metric, _ l: Double?, _ h: Double?) -> Target {
        Target(metric: m, low: l, high: h, unit: "abs", unresolved: nil)
    }
    #expect(Formats.target(t(.hr, 140, 150), sport: .run, units: .english) == "140–150 bpm")
    #expect(Formats.target(t(.hr, nil, 150), sport: .run, units: .english) == "≤ 150 bpm")
    #expect(Formats.target(t(.pace, 290, 300), sport: .run, units: .english) == "4:50–5:00 /km")
    #expect(Formats.target(t(.pace, 100, 105), sport: .swim, units: .english) == "1:40–1:45 /100m")
    #expect(Formats.target(t(.power, 200, 220), sport: .bike, units: .english) == "200–220 W")
    #expect(Formats.target(t(.rpe, 9, 10), sport: .run, units: .english) == "RPE 9–10")
    #expect(Formats.target(t(.cadence, 85, 95), sport: .bike, units: .english) == "85–95 rpm")
}

@Test func localDates() {
    let d = LocalDate("2026-11-15")! // Sunday
    #expect(d.weekStart.iso == "2026-11-09")
    #expect(LocalDate("2026-11-16")!.weekStart.iso == "2026-11-16")
    #expect(d.adding(days: 17).iso == "2026-12-02")
    #expect(d.days(until: LocalDate("2026-12-06")!) == 21)
    #expect(LocalDate("2026-02-30") == nil)
    let tz = TimeZone(identifier: "Asia/Barnaul")!
    #expect(LocalDate.today(in: tz, now: ISO8601DateFormatter().date(from: "2026-11-14T18:30:00Z")!).iso == "2026-11-15")
}
