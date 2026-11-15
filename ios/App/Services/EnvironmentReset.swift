import Foundation
import Zone2Kit

/// Local state belongs to one server: the offline database (records, cursor), the workout upload
/// queue (HealthKit anchor: "already uploaded") and the health-metrics backfill flag. When this copy
/// starts talking to another server (the old single app was staging, now it is prod), drop that
/// state so the new server gets the whole history and a fresh snapshot. Sign-in is per host already.
enum EnvironmentReset {
    private static let key = "lastServerURL"

    static func ifServerChanged(_ url: URL) {
        let d = UserDefaults.standard
        let fm = FileManager.default
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let healthState = docs.appending(path: "health-sync.json")
        // Builds before the two copies did not record the server: they always used staging.
        let last = d.string(forKey: key)
            ?? (fm.fileExists(atPath: healthState.path(percentEncoded: false)) ? AppEnvironment.stagingURL.absoluteString : nil)
        d.set(url.absoluteString, forKey: key)
        guard let last, last != url.absoluteString else { return }
        for file in [
            healthState,
            support.appending(path: "health-uploads"),
            support.appending(path: "zone2.sqlite"),
            support.appending(path: "zone2.sqlite-wal"),
            support.appending(path: "zone2.sqlite-shm"),
        ] {
            try? fm.removeItem(at: file)
        }
        d.removeObject(forKey: "dailyMetrics.backfilled")
    }
}
