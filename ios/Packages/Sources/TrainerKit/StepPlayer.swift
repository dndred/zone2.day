import Foundation
import Zone2Kit

/// One step of a planned workout, repeats unrolled ("Work 3/5").
public struct PlayStep: Sendable, Equatable, Identifiable {
    public let id: String
    public let stepId: String
    public let kind: Step.Kind
    public let label: String?
    public let duration: StepDuration
    public let target: Target?
    public let secondary: [Target]
    public let note: String?
    /// 1-based repetition and the count, for steps inside a repeat.
    public let rep: Int?
    public let reps: Int?

    /// Planned seconds: time steps exactly, open steps by their estimate.
    public var plannedSec: Int? {
        switch duration {
        case .time(let sec): sec
        case .open(let e): e
        case .distance: nil
        }
    }
}

/// The structure of a planned workout, flattened for the player.
public struct RidePlan: Sendable, Equatable {
    public let workoutId: String
    public let title: String
    public let steps: [PlayStep]

    public init(workoutId: String, title: String, steps: [PlayStep]) {
        self.workoutId = workoutId
        self.title = title
        self.steps = steps
    }

    /// nil when the workout has no endurance structure (then it is a free ride linked to the plan).
    public init(_ w: PlannedWorkout) {
        var steps: [PlayStep] = []
        func add(_ s: Step, rep: Int?, of reps: Int?) {
            steps.append(PlayStep(
                id: rep.map { "\(s.id)#\($0)" } ?? s.id, stepId: s.id, kind: s.kind, label: s.label,
                duration: s.duration, target: s.target, secondary: s.secondary ?? [], note: s.note,
                rep: rep, reps: reps))
        }
        for node in w.resolved?.steps ?? [] {
            switch node {
            case .step(let s): add(s, rep: nil, of: nil)
            case .repeats(_, let count, let inner):
                for i in 1...max(count, 1) { for s in inner { add(s, rep: i, of: count) } }
            }
        }
        self.init(workoutId: w.id, title: w.title, steps: steps)
    }

    /// Seconds of all time-based steps (and estimates of open ones).
    public var plannedSec: Int { steps.compactMap(\.plannedSec).reduce(0, +) }
}

/// Plays a plan against the ride: time and distance steps advance on their own, open steps wait
/// for `next`. Driven by active time (pauses don't count) and the trainer's virtual distance.
/// The ridden steps become segments of the record.
public struct StepPlayer: Sendable {
    public let plan: RidePlan
    public private(set) var index = 0
    private var stepStartSec = 0
    private var stepStartM = 0.0
    private var stepStartAt: Date?
    public private(set) var segments: [RideRecorder.Segment] = []

    public init(plan: RidePlan) { self.plan = plan }

    public var current: PlayStep? { plan.steps.indices.contains(index) ? plan.steps[index] : nil }
    public var next: PlayStep? { plan.steps.indices.contains(index + 1) ? plan.steps[index + 1] : nil }
    public var isFinished: Bool { index >= plan.steps.count }

    public mutating func begin(at now: Date) {
        index = 0
        stepStartSec = 0
        stepStartM = 0
        stepStartAt = now
        segments = []
    }

    /// Seconds into the current step.
    public func stepElapsed(_ elapsed: Int) -> Int { max(0, elapsed - stepStartSec) }

    /// Seconds left in a time step (nil for distance and open steps).
    public func remaining(_ elapsed: Int) -> Int? {
        guard case .time(let sec) = current?.duration else { return nil }
        return max(0, sec - stepElapsed(elapsed))
    }

    /// Metres left in a distance step.
    public func remainingM(_ distanceM: Double) -> Double? {
        guard case .distance(let m) = current?.duration else { return nil }
        return max(0, m - (distanceM - stepStartM))
    }

    /// Call every second with the ride's active time and distance; true when the step changed.
    @discardableResult
    public mutating func update(elapsed: Int, distanceM: Double, at now: Date) -> Bool {
        guard let step = current else { return false }
        let done = switch step.duration {
        case .time(let sec): elapsed - stepStartSec >= sec
        case .distance(let m): distanceM - stepStartM >= m
        case .open: false
        }
        guard done else { return false }
        advance(elapsed: elapsed, distanceM: distanceM, at: now)
        return true
    }

    /// Ends the current step now (open steps, or skipping ahead).
    public mutating func skip(elapsed: Int, distanceM: Double, at now: Date) {
        guard current != nil else { return }
        advance(elapsed: elapsed, distanceM: distanceM, at: now)
    }

    /// Closes the step in progress when the ride stops.
    public mutating func finish(at now: Date) {
        guard let step = current, let from = stepStartAt, now > from else { return }
        segments.append(.init(start: from, end: now, stepId: step.stepId, label: Self.label(step)))
        stepStartAt = nil
    }

    private mutating func advance(elapsed: Int, distanceM: Double, at now: Date) {
        if let step = current, let from = stepStartAt {
            segments.append(.init(start: from, end: now, stepId: step.stepId, label: Self.label(step)))
        }
        index += 1
        stepStartSec = elapsed
        stepStartM = distanceM
        stepStartAt = now
    }

    static func label(_ s: PlayStep) -> String {
        var name = s.label ?? s.kind.rawValue
        if let rep = s.rep, let reps = s.reps { name += " \(rep)/\(reps)" }
        return name
    }
}
