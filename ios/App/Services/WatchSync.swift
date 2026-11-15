import Foundation
import UIKit
import WorkoutKit
import Zone2Kit

/// After every pull: make the watch's scheduled workouts match the plan (docs/05-sync.md §5).
/// Result goes to the store (sync_state "watch") so screens can show "On watch".
enum WatchSync {
    /// Reconciles and queues a delivery report for the server (outbox, sent by the caller).
    static func run(store: LocalStore, interactive: Bool) async {
        let now = Date()
        var items: [DeliveryReportItem] = []
        var error: String?
        do {
            if !WorkoutScheduler.isSupported {
                error = "no watch"
            } else {
                var state = await WorkoutScheduler.shared.authorizationState
                if state == .notDetermined && interactive {
                    state = await WorkoutScheduler.shared.requestAuthorization()
                }
                if state != .authorized {
                    error = "not authorized"
                } else {
                    let (profile, today, candidates) = try store.deliveryCandidates(now: now)
                    let desired = WatchDelivery.desired(candidates, profile: profile, today: today,
                                                        limit: WorkoutScheduler.maxAllowedScheduledWorkoutCount)
                    let result = await WatchReconciler.reconcile(desired: desired, scheduler: SystemWatchScheduler())
                    items = result.report
                    try store.setWatchState(WatchState(onWatch: result.onWatch, at: now, error: nil, warnings: result.warnings))
                }
            }
            if let error {
                try store.setWatchState(WatchState(onWatch: [], at: now, error: error, warnings: []))
            }
        } catch let e {
            error = String(describing: e)
            try? store.setWatchState(WatchState(onWatch: [], at: now, error: error, warnings: []))
        }
        await queueReport(store: store, items: items, error: error)
    }

    private static func queueReport(store: LocalStore, items: [DeliveryReportItem], error: String?) async {
        guard let deviceId = try? store.deviceId() else { return }
        let status = try? store.status()
        let report = await DeliveryReport(
            deviceId: deviceId,
            deviceName: UIDevice.current.name,
            model: modelIdentifier(),
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            lastPullAt: status?.lastSyncAt,
            cursor: status?.cursor,
            error: error,
            items: items
        )
        if let body = try? JSONEncoder().encode(report) {
            // One logical message: a newer report replaces an unsent older one.
            try? store.enqueue(id: "delivery-report", kind: "delivery", payload: body)
        }
    }

    private static func modelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
