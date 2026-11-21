import Foundation
import Testing
@testable import Zone2Kit

private func profile(_ json: String) throws -> Profile {
    try JSONDecoder().decode(Profile.self, from: Data(json.utf8))
}

@Test func profileThresholdsDecodeNumbersAndRanges() throws {
    let p = try profile("""
    {"timezone":"Asia/Barnaul","run":{"maxHr":186,"hrZones":[140,153,162,172],
     "lthr":{"low":167,"high":171,"basis":"…"},"thresholdPaceSecPerKm":{"low":295,"high":310}},
     "bike":{"ftp":200},"swim":{}}
    """)
    #expect(p.run.lthr == 169)
    #expect(p.run.thresholdPaceSecPerKm == 302.5)
    #expect(p.run.hrZones == [140, 153, 162, 172])
    #expect(p.bike.ftp == 200)
    #expect(p.run.detail["lthr"]?.low == 167 && p.run.detail["lthr"]?.basis == "…")
    #expect(p.bike.detail["ftp"]?.low == nil && p.bike.detail["ftp"]?.value == 200)
    #expect(p.timezone == "Asia/Barnaul")
    // A profile without sports still decodes.
    #expect(try profile(#"{"timezone":"UTC"}"#).run == Profile.SportProfile())
}

@Test func hrZonesFollowTheServerOrder() throws {
    let own = try profile(#"{"run":{"hrZones":[172,140,162,153],"lthr":170}}"#)
    #expect(own.hrZones(for: .run)?.bounds == [140, 153, 162, 172])
    // The bike borrows run zones when it has none of its own.
    #expect(own.hrZones(for: .bike)?.bounds == [140, 153, 162, 172])

    let friel = try profile(#"{"run":{"lthr":{"low":167,"high":171}}}"#)
    #expect(friel.hrZones(for: .run)?.bounds == [144, 152, 161, 169])

    let max = try profile(#"{"run":{"maxHr":190}}"#)
    #expect(max.hrZones(for: .swim)?.bounds == [114, 133, 152, 171])
    #expect(try profile("{}").hrZones(for: .run) == nil)
}

@Test func zoneOfValueAndTimeInZones() {
    let z = ZoneSet(metric: .hr, bounds: [140, 153, 162, 172])
    #expect(z.zone(of: 120) == 1)
    #expect(z.zone(of: 140) == 2)
    #expect(z.zone(of: 161) == 3)
    #expect(z.zone(of: 190) == 5)
    #expect(z.range(of: 1).low == nil && z.range(of: 1).high == 139)
    #expect(z.range(of: 5).low == 172 && z.range(of: 5).high == nil)
    #expect(z.seconds(in: [130, 145, nil, 150, 175, 0], bucketSec: 10) == [10, 20, 0, 0, 10])

    // 10 min Z1 + 20 min Z2 + 30 min Z4 → 10 + 40 + 120.
    #expect(z.edwardsTrimp([600, 1200, 0, 1800, 0]) == 170)
    #expect(z.edwardsTrimp([600, 1200]) == nil)
    let coggan = ZoneSet(metric: .power, bounds: [112, 152, 182, 212, 242, 302])
    #expect(coggan.zone(of: 320) == 7)
    #expect(coggan.displayZone(of: 320) == 5)
}

@Test func stepIntensityFromTargetsElseKind() throws {
    let p = try profile(#"{"run":{"hrZones":[140,153,162,172],"thresholdPaceSecPerKm":300},"bike":{"ftp":200}}"#)
    func step(_ kind: Step.Kind, _ target: Target?) -> Step {
        Step(id: "s", kind: kind, label: nil, duration: .time(sec: 600), target: target, secondary: nil, note: nil)
    }
    func t(_ m: Target.Metric, _ l: Double?, _ h: Double?) -> Target {
        Target(metric: m, low: l, high: h, unit: "abs", unresolved: nil)
    }
    #expect(Intensity.zone(of: step(.work, t(.hr, nil, 150)), sport: .run, profile: p) == 2)
    #expect(Intensity.zone(of: step(.work, t(.hr, 165, 170)), sport: .run, profile: p) == 4)
    // Pace: threshold 5:00; 4:50–5:00 is at threshold, 6:30 is easy.
    #expect(Intensity.zone(of: step(.work, t(.pace, 290, 300)), sport: .run, profile: p) == 5)
    #expect(Intensity.zone(of: step(.work, t(.pace, 380, 400)), sport: .run, profile: p) == 1)
    // Sweet spot 88–93 % FTP: middle 181 W < 182 (91 %) → Coggan Z3.
    #expect(Intensity.zone(of: step(.work, t(.power, 176, 186)), sport: .bike, profile: p) == 3)
    #expect(Intensity.zone(of: step(.work, t(.rpe, 9, 10)), sport: .run, profile: p) == 5)
    // No usable target → by kind.
    #expect(Intensity.zone(of: step(.warmup, nil), sport: .run, profile: p) == 2)
    #expect(Intensity.zone(of: step(.work, t(.hr, 150, 160)), sport: .run, profile: Profile()) == 3)
    #expect(Intensity.zone(of: step(.rest, t(.hr, 170, 180)), sport: .run, profile: p) == 1)
    // Power without FTP: a secondary HR cap doesn't make the work easier than the warm-up.
    let noFtp = try profile(#"{"run":{"hrZones":[140,153,162,172]}}"#)
    let work = Step(id: "w", kind: .work, label: nil, duration: .time(sec: 2700), target: t(.power, 145, 165),
                    secondary: [t(.hr, nil, 140), t(.cadence, 85, 90)], note: nil)
    #expect(Intensity.zone(of: work, sport: .bike, profile: noFtp) == 3)
    let ranged = Step(id: "r", kind: .work, label: nil, duration: .time(sec: 600), target: t(.power, 145, 165),
                      secondary: [t(.hr, 145, 152)], note: nil)
    #expect(Intensity.zone(of: ranged, sport: .bike, profile: noFtp) == 2)
}

@Test func activityAnalysisDecodes() throws {
    let json = #"{"distanceM":17400,"analysis":{"gapSecPerKm":362,"decoupling":{"metric":"pace","pct":3.3,"steadyMin":91,"basis":"…"}}}"#
    let s = try JSONDecoder().decode(ActivitySummary.self, from: Data(json.utf8))
    #expect(s.analysis?.gapSecPerKm == 362)
    #expect(s.analysis?.decoupling?.pct == 3.3 && s.analysis?.decoupling?.metric == "pace")
    let bare = try JSONDecoder().decode(ActivitySummary.self, from: Data(#"{"analysis":{"gapSecPerKm":null,"decoupling":null}}"#.utf8))
    #expect(bare.analysis?.gapSecPerKm == nil)
}

@Test func fitnessFatigueForm() throws {
    let d0 = try #require(LocalDate("2026-11-01"))
    // 100 TRIMP a day for a week, then rest.
    var loads: [LocalDate: Double] = [:]
    for i in 0..<7 { loads[d0.adding(days: i)] = 100 }
    let s = Fitness.series(loads: loads, to: d0.adding(days: 13))
    #expect(s.count == 14)
    #expect(abs(s[0].fitness - 100 / 42) < 1e-9 && abs(s[0].fatigue - 100 / 7) < 1e-9)
    #expect(s[0].form == 0) // form is yesterday's fitness − fatigue
    // Fatigue rises faster than fitness: form negative at the end of the block…
    #expect(s[6].fatigue > s[6].fitness && s[7].form < 0)
    // …and recovers during the rest week as fatigue decays faster.
    #expect(s[13].form > s[7].form)
    #expect(Fitness.series(loads: [:], to: d0).isEmpty)
}

@Test func bestPowerAndClimbPerKm() {
    // 10-s buckets: 10 min at 150 W, 5 min at 250 W, 5 min at 100 W.
    let power: [Double?] = Array(repeating: 150, count: 60) + Array(repeating: 250, count: 30) + Array(repeating: 100, count: 30)
    let t = (0..<120).map { Double($0) * 10 }
    let s = ActivityStreams(bucketSec: 10, columns: ["t": t, "cyclingPower": power])
    let best = StreamMath.bestPower(s, channel: "cyclingPower")
    #expect(best.first { $0.seconds == 300 }?.watts == 250)
    #expect(best.first { $0.seconds == 600 }?.watts == 200) // 5 min at 250 + 5 min at 150
    #expect(best.first { $0.seconds == 1200 }?.watts == 162.5) // the whole ride
    #expect(best.contains { $0.seconds == 1800 } == false) // longer than the ride
    #expect(StreamMath.bestPower(s, channel: "runningPower").isEmpty)

    // 5 m/s for 400 s (2 km): flat first km, +20 m on the second.
    let alt: [Double?] = (0..<40).map { $0 < 20 ? 100 : 100 + Double($0 - 19) }
    let climb = StreamMath.elevationGainPerKm(ActivityStreams(bucketSec: 10, columns: [
        "t": (0..<40).map { Double($0) * 10 }, "altitude": alt, "speed": Array(repeating: 5, count: 40),
    ]))!
    #expect(climb.count >= 2)
    #expect(climb[0] < 1)
    #expect(abs(climb[1] - 20) < 1.5)
}
