import AppKit
import Foundation
import Observation
import TrainerKit

/// The ride: live numbers for the overlay, 1 Hz recording, saving the record.
@MainActor @Observable
final class RideModel {
    enum State { case idle, recording, paused }

    let link = TrainerLink()
    private(set) var recorder = RideRecorder()
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
        if state == .recording { recorder.tick(at: now) }
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
            recorder.begin(at: Date())
            lastSaved = nil
            saveError = nil
            state = .recording
        case .paused: state = .recording
        case .recording: break
        }
    }

    func pause() { if state == .recording { state = .paused } }

    func stop() {
        guard state != .idle else { return }
        state = .idle
        save()
    }

    func discard() {
        state = .idle
        recorder = RideRecorder()
    }

    private func save() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
        guard let dump = recorder.dump(trainer: link.trainer.name, heartSource: link.heart.name,
                                       appVersion: "ride-mac \(version)") else { return }
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
