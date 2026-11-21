@preconcurrency import HealthKit
import Observation

/// Indoor ride on the watch: HKWorkoutSession + live builder (heart rate), mirrored to the iPhone.
/// The iPhone sends trainer power/cadence back; we add them to the builder so the single workout in
/// Health has heart rate, power and cadence (spike S9 question 4).
@MainActor @Observable
final class Ride: NSObject {
    static let shared = Ride()

    private(set) var heartRate: Double?
    private(set) var power: Double?
    private(set) var cadence: Double?
    private(set) var status = "idle"
    private(set) var running = false
    private(set) var sent = 0
    private(set) var received = 0
    private(set) var error: String?

    @ObservationIgnored private let store = HKHealthStore()
    @ObservationIgnored private var session: HKWorkoutSession?
    @ObservationIgnored private var builder: HKLiveWorkoutBuilder?
    @ObservationIgnored private var powerSamples = 0
    @ObservationIgnored private var cadenceSamples = 0
    @ObservationIgnored private var lastHeartRateEnd: Date?

    private static let share: Set<HKSampleType> = [
        .workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.cyclingPower), HKQuantityType(.cyclingCadence),
    ]
    private static let read: Set<HKObjectType> = [
        .workoutType(), HKQuantityType(.heartRate), HKQuantityType(.activeEnergyBurned),
    ]

    func start(activity: HKWorkoutActivityType, location: HKWorkoutSessionLocationType) async {
        guard session == nil else { return }
        error = nil
        do {
            try await store.requestAuthorization(toShare: Self.share, read: Self.read)
            let config = HKWorkoutConfiguration()
            config.activityType = activity
            config.locationType = location
            let session = try HKWorkoutSession(healthStore: store, configuration: config)
            let builder = session.associatedWorkoutBuilder()
            builder.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            session.delegate = self
            builder.delegate = self
            self.session = session
            self.builder = builder
            powerSamples = 0; cadenceSamples = 0; sent = 0; received = 0
            let now = Date()
            session.startActivity(with: now)
            try await builder.beginCollection(at: now)
            try await builder.addMetadata([HKMetadataKeyIndoorWorkout: true, "zone2.trainer": "spike S9"])
            running = true
            status = "running, mirroring…"
            try await session.startMirroringToCompanionDevice()
            status = "running, mirrored"
            await send(.state("running"))
        } catch {
            self.error = "\(error)"
            status = "failed"
        }
    }

    func stop() {
        session?.end()
    }

    private func finish(at date: Date) async {
        guard let builder else { return }
        do {
            try await builder.endCollection(at: date)
            let workout = try await builder.finishWorkout()
            status = "saved \(Int(workout?.duration ?? 0)) s"
            await send(.saved(duration: workout?.duration ?? 0, powerSamples: powerSamples, cadenceSamples: cadenceSamples))
        } catch {
            self.error = "\(error)"
            await send(.error("finish: \(error)"))
        }
        running = false
        session = nil
        self.builder = nil
    }

    private func send(_ message: WorkoutLink) async {
        guard let session else { return }
        do {
            try await session.sendToRemoteWorkoutSession(data: message.data)
            sent += 1
        } catch {
            self.error = "send: \(error.localizedDescription)"
        }
    }

    fileprivate func collected(_ types: Set<HKSampleType>) {
        guard let builder, types.contains(HKQuantityType(.heartRate)),
              let stats = builder.statistics(for: HKQuantityType(.heartRate)),
              let q = stats.mostRecentQuantity(), let interval = stats.mostRecentQuantityDateInterval()
        else { return }
        guard interval.end != lastHeartRateEnd else { return }
        lastHeartRateEnd = interval.end
        let bpm = q.doubleValue(for: .count().unitDivided(by: .minute()))
        heartRate = bpm
        let seq = sent
        Task { await send(.heartRate(bpm: bpm, at: interval.end, sentAt: Date(), seq: seq)) }
    }

    fileprivate func receivedFromPhone(_ batch: [Data]) {
        for data in batch {
            guard let message = WorkoutLink(data: data) else { continue }
            received += 1
            if case let .metrics(p, c, at) = message { add(power: p, cadence: c, at: at) }
            if case .state("stop") = message { stop() }
        }
    }

    private func add(power p: Double, cadence c: Double, at: Date) {
        power = p
        cadence = c
        guard let builder else { return }
        let start = at.addingTimeInterval(-1)
        let samples = [
            HKQuantitySample(type: HKQuantityType(.cyclingPower), quantity: HKQuantity(unit: .watt(), doubleValue: p),
                             start: start, end: at),
            HKQuantitySample(type: HKQuantityType(.cyclingCadence),
                             quantity: HKQuantity(unit: .count().unitDivided(by: .minute()), doubleValue: c),
                             start: start, end: at),
        ]
        Task {
            do {
                try await builder.addSamples(samples)
                powerSamples += 1
                cadenceSamples += 1
            } catch {
                self.error = "add: \(error.localizedDescription)"
            }
        }
    }

    fileprivate func changed(to state: HKWorkoutSessionState, at date: Date) {
        status = "state \(state.rawValue)"
        if state == .ended { Task { await finish(at: date) } }
    }
}

extension Ride: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState,
                                    from: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.changed(to: to, at: date) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        let text = "\(error)"
        Task { @MainActor in self.error = text }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didReceiveDataFromRemoteWorkoutSession data: [Data]) {
        Task { @MainActor in self.receivedFromPhone(data) }
    }

    nonisolated func workoutSession(_ s: HKWorkoutSession, didDisconnectFromRemoteDeviceWithError error: Error?) {
        let text = error.map { "\($0)" } ?? "phone disconnected"
        Task { @MainActor in self.error = text }
    }

    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        Task { @MainActor in self.collected(types) }
    }

    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
}
