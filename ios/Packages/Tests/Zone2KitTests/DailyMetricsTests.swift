import Foundation
import Testing
@testable import Zone2Kit

private let barnaul = TimeZone(identifier: "Asia/Barnaul")! // UTC+7

/// Local time in Barnaul → Date.
private func at(_ s: String) -> Date {
    let f = ISO8601DateFormatter()
    f.timeZone = barnaul
    f.formatOptions = [.withFullDate, .withTime, .withColonSeparatorInTime, .withDashSeparatorInDate]
    return f.date(from: s)!
}

private func seg(_ a: String, _ b: String, _ stage: SleepSegment.Stage, _ source: String = "Watch") -> SleepSegment {
    SleepSegment(start: at(a), end: at(b), stage: stage, source: source)
}

@Test func sleepGoesToTheWakeUpDateWithStages() {
    let night = [
        seg("2026-11-15T23:10:00", "2026-11-16T01:00:00", .core),
        seg("2026-11-16T01:00:00", "2026-11-16T02:00:00", .deep),
        seg("2026-11-16T02:00:00", "2026-11-16T02:10:00", .awake),
        seg("2026-11-16T02:10:00", "2026-11-16T04:00:00", .rem),
        seg("2026-11-16T04:00:00", "2026-11-16T06:30:00", .core),
    ]
    let s = DailyAggregation.sleep(night, in: barnaul)
    let d = LocalDate("2026-11-16")!
    #expect(s.count == 1)
    #expect(s[d]?.asleepMin == 430) // 110 + 60 + 110 + 150
    #expect(s[d]?.deepMin == 60)
    #expect(s[d]?.remMin == 110)
    #expect(s[d]?.awakeMin == 10)
    #expect(s[d]?.inBedStart == "2026-11-15T23:10:00+07:00")
    #expect(s[d]?.inBedEnd == "2026-11-16T06:30:00+07:00")
}

@Test func twoSourcesOneNightKeepsTheRicherOneOnly() {
    let watch = [seg("2026-11-15T23:00:00", "2026-11-16T07:00:00", .core)]
    let phone = [seg("2026-11-15T23:30:00", "2026-11-16T05:00:00", .asleep, "iPhone")]
    let s = DailyAggregation.sleep(watch + phone, in: barnaul)[LocalDate("2026-11-16")!]
    #expect(s?.asleepMin == 480)
    #expect(s?.source == "Watch")
    // Without stages (only "asleep"): stage fields stay nil.
    let plain = DailyAggregation.sleep(phone, in: barnaul)[LocalDate("2026-11-16")!]
    #expect(plain?.deepMin == nil && plain?.asleepMin == 330)
}

@Test func separateNightsSplitBySessionGap() {
    let two = [
        seg("2026-11-14T23:00:00", "2026-11-15T06:00:00", .core),
        seg("2026-11-15T23:00:00", "2026-11-16T06:00:00", .core),
    ]
    let s = DailyAggregation.sleep(two, in: barnaul)
    #expect(s[LocalDate("2026-11-15")!]?.asleepMin == 420)
    #expect(s[LocalDate("2026-11-16")!]?.asleepMin == 420)
}

@Test func quantitiesByLocalDayAndPayloadShape() throws {
    let hrv = [
        MetricSample(start: at("2026-11-16T02:00:00"), end: at("2026-11-16T02:01:00"), value: 50),
        MetricSample(start: at("2026-11-16T05:00:00"), end: at("2026-11-16T05:01:00"), value: 70),
        // 23:30 local on the 16th is still the 16th although it is the 16th 16:30 UTC.
        MetricSample(start: at("2026-11-16T23:30:00"), end: at("2026-11-16T23:31:00"), value: 30),
    ]
    let byDay = DailyAggregation.byDay(hrv, in: barnaul, reduce: .mean)
    #expect(byDay[LocalDate("2026-11-16")!]?.value == 50)
    #expect(byDay[LocalDate("2026-11-16")!]?.count == 3)
    let weight = DailyAggregation.byDay([
        MetricSample(start: at("2026-11-16T07:00:00"), end: at("2026-11-16T07:00:00"), value: 72.4),
        MetricSample(start: at("2026-11-16T21:00:00"), end: at("2026-11-16T21:00:00"), value: 73.0),
    ], in: barnaul, reduce: .last)
    #expect(weight[LocalDate("2026-11-16")!]?.value == 73.0)

    let days = DailyAggregation.days(
        from: LocalDate("2026-11-15")!, to: LocalDate("2026-11-16")!,
        restingHr: [LocalDate("2026-11-16")!: (48.4, 1)], hrv: byDay, sleep: [:],
        respiratory: [:], wristTemp: [LocalDate("2026-11-16")!: (34.5678, 1)], weight: weight, vo2max: [:]
    )
    #expect(days.count == 1) // the 15th has nothing → not sent
    #expect(days[0].restingHr == 48.4 && days[0].hrvSamples == 3 && days[0].wristTempC == 34.57)
    let json = try JSONSerialization.jsonObject(
        with: JSONEncoder().encode(DailyMetricsPayload(deviceId: "d", days: days))
    ) as! [String: Any]
    let day = (json["days"] as! [[String: Any]])[0]
    #expect(day["date"] as? String == "2026-11-16")
    #expect(day["sleep"] == nil) // absent, server reads it as null
}
