import Foundation
import WorkoutKit
import Zone2Kit

/// After every pull: make the watch's scheduled workouts match the plan (docs/05-sync.md §5).
/// Result goes to the store (sync_state "watch") so screens can show "On watch".
enum WatchSync {
    static func run(store: LocalStore, interactive: Bool) async {
        let now = Date()
        do {
            guard WorkoutScheduler.isSupported else {
                return try store.setWatchState(WatchState(onWatch: [], at: now, error: "no watch", warnings: []))
            }
            var state = await WorkoutScheduler.shared.authorizationState
            if state == .notDetermined && interactive {
                state = await WorkoutScheduler.shared.requestAuthorization()
            }
            guard state == .authorized else {
                return try store.setWatchState(WatchState(onWatch: [], at: now, error: "not authorized", warnings: []))
            }
            let (profile, today, candidates) = try store.deliveryCandidates(now: now)
            let desired = WatchDelivery.desired(candidates, profile: profile, today: today,
                                                limit: WorkoutScheduler.maxAllowedScheduledWorkoutCount)
            let result = await WatchReconciler.reconcile(desired: desired, scheduler: SystemWatchScheduler())
            try store.setWatchState(WatchState(onWatch: result.onWatch, at: now, error: nil, warnings: result.warnings))
        } catch {
            try? store.setWatchState(WatchState(onWatch: [], at: now, error: String(describing: error), warnings: []))
        }
    }
}
