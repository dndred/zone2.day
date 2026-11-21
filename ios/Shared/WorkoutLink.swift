import Foundation

/// Messages between the watch companion and the iPhone over the mirrored HKWorkoutSession
/// (`sendToRemoteWorkoutSession(data:)`). Spike S9, docs/11-trainer.md §4.
enum WorkoutLink: Codable, Sendable {
    /// Watch → iPhone: the latest heart rate from the live builder. `at` — end of the sample,
    /// `sentAt` — when the watch sent it (latency = received − at), `seq` — to count gaps.
    case heartRate(bpm: Double, at: Date, sentAt: Date, seq: Int)
    /// Watch → iPhone: session state for the trainer screen.
    case state(String)
    /// iPhone → watch: trainer metrics for the last second, added to the live builder.
    case metrics(power: Double, cadence: Double, at: Date)
    /// Watch → iPhone: the workout is in Health.
    case saved(duration: Double, powerSamples: Int, cadenceSamples: Int)
    /// Either way: something failed on the other side.
    case error(String)

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    init?(data: Data) {
        guard let v = try? JSONDecoder().decode(Self.self, from: data) else { return nil }
        self = v
    }
}
