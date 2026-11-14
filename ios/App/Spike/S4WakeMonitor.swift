#if DEBUG
import BackgroundTasks
import Foundation
import HealthKit
import UIKit

/// Spike S4 (docs/09-roadmap.md): how often does the app get to run without push?
/// Every wake-up appends one JSON line to Documents/wakes.jsonl (pulled later with devicectl):
/// trigger, app state, and whether the network was reachable (GET /health on staging).
enum WakeMonitor {
    static let refreshTaskId = "day.zone2.app.refresh"
    private static let store = HKHealthStore()
    nonisolated(unsafe) private static var started = false

    struct Event: Codable, Identifiable {
        var id: Date { at }
        let at: Date
        let trigger: String
        let state: String
        let net: String
        let ms: Int
        let error: String?
    }

    /// HealthKit's completion handler is not Sendable; we call it exactly once from the Task.
    private final class UncheckedBox<T>: @unchecked Sendable {
        let value: T
        init(_ value: T) { self.value = value }
    }

    static var logURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "wakes.jsonl")
    }

    /// Called from App.init — runs on every launch, including background launches by HealthKit.
    static func start() {
        guard !started else { return }
        started = true
        let observed: [(String, HKSampleType)] = [
            ("hk.workout", HKObjectType.workoutType()),
            ("hk.steps", HKQuantityType(.stepCount)),
        ]
        for (name, type) in observed {
            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                let done = UncheckedBox(completion)
                let message = error.map { String(describing: $0) }
                Task {
                    await record(name, errorText: message)
                    done.value()
                }
            }
            store.execute(query)
        }
        Task {
            try? await store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate)
            try? await store.enableBackgroundDelivery(for: HKQuantityType(.stepCount), frequency: .hourly)
        }
        // Note: BGTaskScheduler.submit must not run here — SwiftUI registers `.backgroundTask`
        // handlers after App.init, and submitting before registration aborts the app.
        Task { await record("launch") }
    }

    static func scheduleRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: refreshTaskId)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 30 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            Task { await append(Event(at: .now, trigger: "bg.schedule_failed", state: "-", net: "-", ms: 0, error: String(describing: error))) }
        }
    }

    static func record(_ trigger: String, errorText: String? = nil) async {
        let state = await MainActor.run { () -> String in
            switch UIApplication.shared.applicationState {
            case .active: "active"
            case .background: "background"
            case .inactive: "inactive"
            @unknown default: "unknown"
            }
        }
        let (net, ms) = await ping()
        await append(Event(at: .now, trigger: trigger, state: state, net: net, ms: ms, error: errorText))
    }

    private static func ping() async -> (String, Int) {
        var request = URLRequest(url: URL(string: "https://api-staging.zone2.day/health")!)
        request.timeoutInterval = 10
        let started = Date()
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (code == 200 ? "ok" : "http\(code)", Int(Date().timeIntervalSince(started) * 1000))
        } catch {
            return ("offline", Int(Date().timeIntervalSince(started) * 1000))
        }
    }

    private static let writer = Writer()

    private actor Writer {
        func append(_ line: Data) {
            let url = WakeMonitor.logURL
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(line)
                try? handle.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    private static func append(_ event: Event) async {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard var data = try? encoder.encode(event) else { return }
        data.append(0x0A)
        await writer.append(data)
    }

    static func load() -> [Event] {
        guard let text = try? String(contentsOf: logURL, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Event.self, from: Data($0.utf8)) }
    }
}
#endif
