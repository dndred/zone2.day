import Foundation
import Testing
@testable import TrainerKit
import Zone2Kit

// Raw bytes from the ThinkRider X2Max (docs/spikes/S8-ftms-trainer.md) and HeartCast on iPhone.
@Test func indoorBikeDataIdle() {
    let d = IndoorBikeData([0x44, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00])
    #expect(d == IndoorBikeData(speedKmh: 0, cadenceRpm: 0, powerW: 0))
}

@Test func indoorBikeDataRiding() {
    // flags 0x44: speed 32.50 km/h (0x0CB2), cadence 90 rpm (180 half-rpm), power 215 W.
    let d = IndoorBikeData([0x44, 0x00, 0xB2, 0x0C, 0xB4, 0x00, 0xD7, 0x00])
    #expect(d?.speedKmh == 32.5)
    #expect(d?.cadenceRpm == 90)
    #expect(d?.powerW == 215)
}

@Test func indoorBikeDataMoreDataAndHeartRate() {
    // flags: more data (no speed) | cadence | power | heart rate.
    let flags = 0x0001 | 0x0004 | 0x0040 | 0x0200
    let d = IndoorBikeData([UInt8(flags & 0xFF), UInt8(flags >> 8), 0xA0, 0x00, 0x2C, 0x01, 0x8C])
    #expect(d == IndoorBikeData(speedKmh: nil, cadenceRpm: 80, powerW: 300, heartRate: 140))
}

@Test func indoorBikeDataTruncated() {
    #expect(IndoorBikeData([0x44, 0x00, 0x00]) == nil)
}

@Test func heartRate() {
    #expect(HeartRateMeasurement([0x06, 0x3D])?.bpm == 61)
    #expect(HeartRateMeasurement([0x06, 0x00])?.bpm == nil) // HeartCast "no reading"
    #expect(HeartRateMeasurement([0x01, 0x2C, 0x01])?.bpm == 300) // uint16 format
    #expect(HeartRateMeasurement([0x06]) == nil)
}

@Test func cyclingPower() {
    #expect(CyclingPowerMeasurement([0x30, 0x00, 0xD7, 0x00, 0, 0, 0, 0])?.powerW == 215)
}

@Test func recorderSamplesOncePerSecondAndDropsStale() throws {
    var r = RideRecorder()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    r.begin(at: t0)
    for s in 0..<60 {
        let now = t0.addingTimeInterval(Double(s))
        if s < 40 { r.trainer(IndoorBikeData(speedKmh: 36, cadenceRpm: 90, powerW: 200), at: now) }
        if s % 4 == 0 && s < 20 { r.heartRate(130, at: now) }
        r.tick(at: now.addingTimeInterval(0.5))
    }
    #expect(r.elapsed == 60)
    // Trainer stopped at 40 s → power is gone 3 s later; heart rate stale 10 s after the last one.
    #expect(r.seconds[41].powerW == 200)
    #expect(r.seconds[42].powerW == nil)
    #expect(r.seconds[25].heartRate == 130)
    #expect(r.seconds[30].heartRate == nil)
    #expect(r.averagePower == 200)
    #expect(abs(r.distanceM - 42 * 10) < 0.01) // 36 km/h = 10 m/s while fresh (0…41)

    let dump = try #require(r.dump(trainer: "X2Max", heartSource: "HeartCast", appVersion: "test"))
    #expect(dump.workout.activityType == 13)
    #expect(dump.workout.durationSec == 60)
    #expect(dump.workout.metadata["HKIndoorWorkout"] == .bool(true))
    #expect(dump.samples["cyclingPower"]?.values.count == 42)
    #expect(dump.samples["cyclingPower"]?.values.first == [0, 1, 200])
    #expect(dump.samples["heartRate"]?.unit == "count/min")
}

@Test func power3sAndNormalizedPower() {
    var r = RideRecorder()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    r.trainer(IndoorBikeData(powerW: 100), at: t0)
    r.trainer(IndoorBikeData(powerW: 200), at: t0.addingTimeInterval(1))
    r.trainer(IndoorBikeData(powerW: 300), at: t0.addingTimeInterval(2))
    #expect(r.power3s(t0.addingTimeInterval(2)) == 200)
    #expect(r.power3s(t0.addingTimeInterval(10)) == nil)

    r.begin(at: t0)
    for s in 0..<120 {
        let now = t0.addingTimeInterval(Double(s))
        r.trainer(IndoorBikeData(powerW: 250), at: now)
        r.tick(at: now)
    }
    #expect(r.normalizedPower == 250)
    #expect(r.energyKcal == 30) // 250 W × 120 s = 30 kJ
}

@Test func heartRateZeroClearsReading() {
    var r = RideRecorder()
    let t0 = Date()
    r.heartRate(120, at: t0)
    #expect(r.heartNow(t0) == 120)
    r.heartRate(nil, at: t0.addingTimeInterval(1))
    #expect(r.heartNow(t0.addingTimeInterval(1)) == nil)
}

// MARK: - Plan player

private func workout(_ steps: String) throws -> PlannedWorkout {
    let json = """
    {"id":"11111111-1111-1111-1111-111111111111","date":"2026-11-21","sport":"bike","title":"4×4",
     "resolved":{"steps":\(steps)}}
    """
    return try JSONDecoder().decode(PlannedWorkout.self, from: Data(json.utf8))
}

@Test func planUnrollsRepeats() throws {
    let w = try workout("""
    [{"type":"step","id":"wu","kind":"warmup","duration":{"type":"time","sec":600},
      "target":{"metric":"power","low":120,"high":150,"unit":"W"}},
     {"type":"repeat","id":"r","count":2,"steps":[
       {"type":"step","id":"on","kind":"work","duration":{"type":"time","sec":240},"target":{"metric":"power","low":250,"high":265}},
       {"type":"step","id":"off","kind":"recovery","duration":{"type":"time","sec":120}}]},
     {"type":"step","id":"cd","kind":"cooldown","duration":{"type":"open","estimateSec":300}}]
    """)
    let plan = RidePlan(w)
    #expect(plan.steps.map(\.id) == ["wu", "on#1", "off#1", "on#2", "off#2", "cd"])
    #expect(plan.steps[3].rep == 2 && plan.steps[3].reps == 2)
    #expect(plan.steps[1].target?.low == 250)
    #expect(plan.plannedSec == 600 + 2 * 360 + 300)
}

@Test func playerAdvancesByTimeWaitsOnOpenAndRecordsSegments() throws {
    let w = try workout("""
    [{"type":"step","id":"a","kind":"warmup","duration":{"type":"time","sec":60}},
     {"type":"step","id":"b","kind":"work","duration":{"type":"distance","m":500}},
     {"type":"step","id":"c","kind":"cooldown","duration":{"type":"open"}}]
    """)
    var p = StepPlayer(plan: RidePlan(w))
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    p.begin(at: t0)
    #expect(p.current?.id == "a")
    #expect(p.remaining(20) == 40)
    do { let changed = p.update(elapsed: 59, distanceM: 590, at: t0.addingTimeInterval(59)); #expect(!changed) }
    do { let changed = p.update(elapsed: 60, distanceM: 600, at: t0.addingTimeInterval(60)); #expect(changed) }
    #expect(p.current?.id == "b")
    #expect(p.remainingM(800) == 300) // 500 m from 600 m
    do { let changed = p.update(elapsed: 110, distanceM: 1100, at: t0.addingTimeInterval(110)); #expect(changed) }
    #expect(p.current?.id == "c")
    // Open step: never ends by itself.
    do { let changed = p.update(elapsed: 5000, distanceM: 50000, at: t0.addingTimeInterval(5000)); #expect(!changed) }
    #expect(p.stepElapsed(170) == 60)
    p.skip(elapsed: 170, distanceM: 1700, at: t0.addingTimeInterval(170))
    #expect(p.isFinished)
    p.finish(at: t0.addingTimeInterval(200)) // nothing in progress
    #expect(p.segments.map(\.stepId) == ["a", "b", "c"])
    #expect(p.segments[1].start == t0.addingTimeInterval(60))
    #expect(p.segments[2].end == t0.addingTimeInterval(170))
}

@Test func recorderKeepsWallClockAcrossPausesAndWritesEvents() throws {
    var r = RideRecorder()
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    r.begin(at: t0)
    for s in 0..<30 {
        let now = t0.addingTimeInterval(Double(s))
        r.trainer(IndoorBikeData(speedKmh: 36, cadenceRpm: 90, powerW: 200), at: now)
        r.tick(at: now)
    }
    r.pause(at: t0.addingTimeInterval(30))
    r.resume(at: t0.addingTimeInterval(90))
    for s in 90..<120 {
        let now = t0.addingTimeInterval(Double(s))
        r.trainer(IndoorBikeData(speedKmh: 36, cadenceRpm: 90, powerW: 200), at: now)
        r.tick(at: now)
    }
    r.finish(at: t0.addingTimeInterval(120))
    #expect(r.elapsed == 60) // active time
    let seg = RideRecorder.Segment(start: t0, end: t0.addingTimeInterval(200), stepId: "a", label: "warmup")
    let dump = try #require(r.dump(trainer: nil, heartSource: nil, appVersion: "test",
                                   plannedWorkoutId: "pw-1", segments: [seg]))
    #expect(dump.workout.durationSec == 120)
    #expect(dump.samples["cyclingPower"]?.values[30].first == 90) // first second after the pause
    #expect(dump.workout.events.map(\.type) == ["pause", "resume", "segment"])
    #expect(dump.workout.events[2].end == dump.workout.end) // clipped to the ride's end
    #expect(dump.workout.metadata["zone2.plannedWorkoutId"] == .string("pw-1"))
}
