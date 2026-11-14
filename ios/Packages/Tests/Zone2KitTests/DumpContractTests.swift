import Foundation
import Testing
@testable import Zone2Kit

/// The same fixture is parsed by the server (backend/tests/ingest_test.ts).
@Test func contractFixtureRoundTrips() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appending(path: "fixtures/healthkit/contract-v1.json")
    let data = try Data(contentsOf: url)
    let dump = try JSONDecoder().decode(HealthKitDump.self, from: data)
    #expect(dump.schema == 1)
    #expect(dump.workout.uuid == "CONTRACT-V1")
    #expect(dump.workout.metadata["HKWeatherTemperature"] == .quantity(value: 25.9, unit: "degF"))
    #expect(dump.workout.metadata["HKIndoorWorkout"] == .bool(false))
    #expect(dump.samples["heartRate"]?.values.first?.count == 3)
    let again = try JSONDecoder().decode(HealthKitDump.self, from: try dump.encoded())
    #expect(again == dump)
}
