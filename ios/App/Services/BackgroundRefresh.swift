import BackgroundTasks
import Foundation

/// BGAppRefreshTask: iOS wakes the app now and then (S4 measures how often) → full sync cycle.
enum BackgroundRefresh {
    static let taskId = "day.zone2.app.refresh"

    /// Re-submitted on every foreground/background switch and after each run.
    static func schedule() {
        let request = BGAppRefreshTaskRequest(identifier: taskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        try? BGTaskScheduler.shared.submit(request)
    }
}
