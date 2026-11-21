import AppKit
import Foundation
import Observation
import TrainerKit
import Zone2Kit

/// The ride: live numbers for the overlay, 1 Hz recording, saving the record.
@MainActor @Observable
final class RideModel {
    enum State { case idle, recording, paused }

    let link = TrainerLink()
    let account = RideAccount()
    private(set) var recorder = RideRecorder()
    /// The planned workout to follow (chosen before the start); nil — free ride.
    private(set) var chosen: PlannedItem?
    /// The plan's steps while riding (nil for a free ride or a workout without structure).
    private(set) var player: StepPlayer?
    /// Free ride on purpose, so the suggestion does not come back.
    private var freeRide = false
    private(set) var state: State = .idle
    private(set) var now = Date()
    private(set) var lastSaved: URL?
    private(set) var saveError: String?

    @ObservationIgnored private var timer: Timer?
    /// No App Nap: an accessory app behind full-screen video would otherwise get its timers and
    /// Bluetooth callbacks throttled.
    @ObservationIgnored private let activity = ProcessInfo.processInfo.beginActivity(
        options: [.userInitiated, .latencyCritical], reason: "Recording a trainer ride")

    static let ridesFolder = URL.homeDirectory.appending(path: "zone2/rides", directoryHint: .isDirectory)

    init() {
        link.onTrainer = { [weak self] d in self?.recorder.trainer(d, at: Date()) }
        link.onHeart = { [weak self] bpm in self?.recorder.heartRate(bpm, at: Date()) }
        let t = Timer(timeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated { RideModel.shared?.tick() }
        }
        RunLoop.main.add(t, forMode: .common) // keeps ticking while a menu is open or the window is dragged
        timer = t
        RideModel.shared = self
    }

    @ObservationIgnored nonisolated(unsafe) static weak var shared: RideModel?

    private func tick() {
        now = Date()
        if state == .idle, Int(now.timeIntervalSince1970) % 600 == 0 { Task { await account.refresh() } }
        guard state == .recording else { return }
        recorder.tick(at: now)
        guard var p = player else { return }
        let before = p.remaining(recorder.elapsed)
        if p.update(elapsed: recorder.elapsed, distanceM: recorder.distanceM, at: now) {
            NSSound(named: "Glass")?.play()
        } else if let left = p.remaining(recorder.elapsed), left != before, (1...3).contains(left) {
            NSSound(named: "Tink")?.play()
        }
        player = p
    }

    // MARK: Plan

    /// The workout the overlay will follow: the athlete's choice, else today's suggestion.
    var workout: PlannedItem? {
        if state != .idle { return chosen }
        return chosen ?? (freeRide ? nil : account.suggested)
    }

    func choose(_ item: PlannedItem?) {
        guard state == .idle else { return }
        chosen = item
        freeRide = item == nil
    }

    func nextStep() {
        guard state != .idle, var p = player else { return }
        p.skip(elapsed: recorder.elapsed, distanceM: recorder.distanceM, at: Date())
        player = p
    }

    // MARK: Live values

    var power: Int? { recorder.power3s(now) }
    var heartRate: Int? { recorder.heartNow(now) }
    var cadence: Int? { recorder.cadenceNow(now).map { Int($0.rounded()) } }
    var speed: Double? { recorder.speedNow(now) }

    // MARK: Controls

    func start() {
        switch state {
        case .idle:
            let now = Date()
            chosen = workout
            let plan = chosen.map { RidePlan($0.workout) }
            player = plan.flatMap { $0.steps.isEmpty ? nil : StepPlayer(plan: $0) }
            player?.begin(at: now)
            recorder.begin(at: now)
            lastSaved = nil
            saveError = nil
            state = .recording
        case .paused:
            recorder.resume(at: Date())
            state = .recording
        case .recording: break
        }
    }

    func pause() {
        guard state == .recording else { return }
        recorder.pause(at: Date())
        state = .paused
    }

    func stop() {
        guard state != .idle else { return }
        let now = Date()
        recorder.finish(at: now)
        player?.finish(at: now)
        state = .idle
        save()
        if let lastSaved { Task { await account.upload(lastSaved) } }
        chosen = nil
        freeRide = false
    }

    func discard() {
        state = .idle
        recorder = RideRecorder()
        player = nil
        chosen = nil
        freeRide = false
    }

    private func save() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let dump = recorder.dump(trainer: link.trainer.name, heartSource: link.heart.name,
                                       appVersion: "ride-mac \(version)",
                                       plannedWorkoutId: chosen?.workout.id,
                                       segments: player?.segments ?? []) else { return }
        do {
            try FileManager.default.createDirectory(at: Self.ridesFolder, withIntermediateDirectories: true)
            let f = DateFormatter()
            f.dateFormat = "yyyy-MM-dd-HHmm"
            let url = Self.ridesFolder.appending(path: "\(f.string(from: recorder.start ?? Date()))-ride.json")
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(dump).write(to: url)
            lastSaved = url
        } catch {
            saveError = error.localizedDescription
        }
    }

    func revealRides() {
        NSWorkspace.shared.activateFileViewerSelecting([lastSaved ?? Self.ridesFolder])
    }
}
