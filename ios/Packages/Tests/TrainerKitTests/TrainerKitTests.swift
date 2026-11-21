import Foundation
import Testing
@testable import TrainerKit

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
