import HealthKit
import SwiftUI
import WatchKit

/// Zone2 Watch — first feature: heart-rate companion for the trainer (spike S9, docs/11-trainer.md §4).
@main
struct Zone2WatchApp: App {
    @WKApplicationDelegateAdaptor private var delegate: WatchDelegate

    var body: some Scene {
        WindowGroup { RideView(ride: .shared) }
    }
}

final class WatchDelegate: NSObject, WKApplicationDelegate {
    /// iPhone called `HKHealthStore.startWatchApp(toHandle:)`: start the session without a tap.
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        let activity = workoutConfiguration.activityType, location = workoutConfiguration.locationType
        Task { @MainActor in await Ride.shared.start(activity: activity, location: location) }
    }
}

struct RideView: View {
    var ride: Ride

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(ride.heartRate.map { "\(Int($0))" } ?? "--")
                        .font(.system(size: 52, weight: .semibold, design: .rounded).monospacedDigit())
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                }
                if let p = ride.power {
                    Text("\(Int(p)) W · \(Int(ride.cadence ?? 0)) rpm").font(.headline.monospacedDigit())
                }
                Text(ride.status).font(.footnote).foregroundStyle(.secondary)
                Text("sent \(ride.sent) · got \(ride.received)").font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                if let e = ride.error { Text(e).font(.caption2).foregroundStyle(.orange) }
                if ride.running {
                    Button("Stop", role: .destructive) { ride.stop() }
                } else {
                    Button("Start") {
                        Task { await ride.start(activity: .cycling, location: .indoor) }
                    }
                    .tint(.orange)
                }
            }
        }
    }
}
