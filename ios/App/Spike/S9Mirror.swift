#if DEBUG
@preconcurrency import HealthKit
import SwiftUI

/// Spike S9 (docs/11-trainer.md §7): heart rate from our watch app over a mirrored HKWorkoutSession.
/// The iPhone wakes the watch app, receives heart rate, measures latency and gaps, and sends fake
/// trainer power/cadence back once a second. Every heart-rate message → Documents/s9.jsonl
/// (`just ios-pull Documents/s9.jsonl`).
@MainActor @Observable
final class S9Mirror: NSObject {
    static let shared = S9Mirror()

    private(set) var status = "idle"
    private(set) var heartRate: Double?
    private(set) var count = 0
    private(set) var lastLatency: Double?
    private(set) var maxLatency: Double = 0
    private(set) var maxGap: Double = 0
    private(set) var log: [String] = []
    var sendPower = true

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var lastAt: Date?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var tick = 0
    @ObservationIgnored private var file: FileHandle?

    /// Must run at launch: iOS may launch the app in the background to hand over the mirrored session.
    func install() {
        store.workoutSessionMirroringStartHandler = { session in
            Task { @MainActor in S9Mirror.shared.attach(session) }
        }
    }

    func startOnWatch() async {
        note("startWatchApp…")
        do {
            try await store.requestAuthorization(toShare: [.workoutType()], read: [HKQuantityType(.heartRate)])
            let config = HKWorkoutConfiguration()
            config.activityType = .cycling
            config.locationType = .indoor
            try await store.startWatchApp(toHandle: config)
            note("watch app asked to start")
        } catch {
            note("startWatchApp failed: \(error)")
        }
    }

    func stop() {
        Task { await send(.state("stop")) }
    }

    private func attach(_ session: HKWorkoutSession) {
        self.session = session
        session.delegate = self
        count = 0; maxLatency = 0; maxGap = 0; lastAt = nil; tick = 0
        status = "mirrored, state \(session.state.rawValue)"
        note("mirrored session attached")
        openFile()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in await S9Mirror.shared.sendMetrics() }
        }
    }

    private func sendMetrics() async {
        guard sendPower, session != nil else { return }
        tick += 1
        // Fake trainer: 150 W ± 20 and 85 rpm, so the workout in Health shows a recognisable shape.
        let power = 150 + 20 * sin(Double(tick) / 30)
        await send(.metrics(power: power.rounded(), cadence: 85, at: Date()))
    }

    private func send(_ message: WorkoutLink) async {
        guard let session else { return }
        do { try await session.sendToRemoteWorkoutSession(data: message.data) } catch {
            note("send failed: \(error.localizedDescription)")
        }
    }

    fileprivate func received(_ batch: [Data]) {
        let now = Date()
        for data in batch {
            guard let message = WorkoutLink(data: data) else { continue }
            switch message {
            case let .heartRate(bpm, at, sentAt, seq):
                heartRate = bpm
                count += 1
                let latency = now.timeIntervalSince(at)
                lastLatency = latency
                maxLatency = max(maxLatency, latency)
                if let lastAt { maxGap = max(maxGap, at.timeIntervalSince(lastAt)) }
                lastAt = at
                write(["bpm": bpm, "at": at.timeIntervalSince1970, "sentAt": sentAt.timeIntervalSince1970,
                       "received": now.timeIntervalSince1970, "seq": Double(seq)])
            case let .state(s): note("watch: \(s)")
            case let .saved(duration, p, c): note("saved \(Int(duration)) s, power \(p), cadence \(c)")
            case let .error(e): note("watch error: \(e)")
            case .metrics: break
            }
        }
    }

    fileprivate func ended(_ state: HKWorkoutSessionState) {
        status = "state \(state.rawValue)"
        if state == .ended || state == .stopped {
            timer?.invalidate()
            timer = nil
        }
    }

    fileprivate func disconnected(_ error: String) {
        note("disconnected: \(error)")
        timer?.invalidate()
        timer = nil
        session = nil
        try? file?.close()
        file = nil
    }

    private func note(_ text: String) {
        log.append("\(Date().formatted(date: .omitted, time: .standard)) \(text)")
        write(["note": text, "received": Date().timeIntervalSince1970])
    }

    private func openFile() {
        let url = URL.documentsDirectory.appending(path: "s9.jsonl")
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        file = try? FileHandle(forWritingTo: url)
        _ = try? file?.seekToEnd()
    }

    private func write(_ obj: [String: Any]) {
        guard let file, let line = try? JSONSerialization.data(withJSONObject: obj) else { return }
        file.write(line + Data("\n".utf8))
    }
}

extension S9Mirror: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in S9Mirror.shared.ended(to) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        let text = "\(error)"
        Task { @MainActor in S9Mirror.shared.note("failed: \(text)") }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in S9Mirror.shared.received(data) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        let text = error.map { "\($0)" } ?? "ended"
        Task { @MainActor in S9Mirror.shared.disconnected(text) }
    }
}

struct S9MirrorView: View {
    var mirror = S9Mirror.shared

    var body: some View {
        List {
            Section {
                HStack(alignment: .firstTextBaseline) {
                    Text(mirror.heartRate.map { "\(Int($0))" } ?? "--")
                        .font(.system(size: 64, weight: .semibold, design: .rounded).monospacedDigit())
                    Image(systemName: "heart.fill").foregroundStyle(.red)
                }
                LabeledContent("Status", value: mirror.status)
                LabeledContent("Messages", value: "\(mirror.count)")
                LabeledContent("Latency", value: mirror.lastLatency.map { String(format: "%.1f s", $0) } ?? "–")
                LabeledContent("Max latency", value: String(format: "%.1f s", mirror.maxLatency))
                LabeledContent("Max gap", value: String(format: "%.1f s", mirror.maxGap))
            }
            Section {
                Button("Start on watch") { Task { await mirror.startOnWatch() } }
                Button("Stop", role: .destructive) { mirror.stop() }
                Toggle("Send fake power 150 W", isOn: Binding(get: { mirror.sendPower }, set: { mirror.sendPower = $0 }))
            }
            Section("Log") {
                ForEach(Array(mirror.log.suffix(40).reversed().enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
        }
        .navigationTitle("Spike S9")
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}
#endif
