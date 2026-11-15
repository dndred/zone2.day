import CryptoKit
import Foundation
import HealthKit
import WorkoutKit

// Delivery of planned workouts to Apple Watch through WorkoutKit (docs/05-sync.md §5,
// docs/06-watch.md §2): plan → CustomWorkout (pure mapping), then a reconciler makes the set of
// scheduled workouts equal to the desired one. No bookkeeping table: the WorkoutPlan id is derived
// from the planned workout's id, date and content, so any change yields a new id → replace.

// MARK: - Mapping

public struct WatchWorkout: Sendable {
    public let workout: CustomWorkout
    /// What could not be expressed on the watch (dropped alert, unsupported goal…).
    public let warnings: [String]
}

public enum WorkoutBridge {
    /// Watch-deliverable sports. Indoor bike is not: the watch is busy with HeartCast (05 §7).
    public static func activity(for w: PlannedWorkout) -> (HKWorkoutActivityType, HKWorkoutSessionLocationType)? {
        switch (w.sport, w.subSport) {
        case (.run, "treadmill"): (.running, .indoor)
        case (.run, _): (.running, .outdoor)
        case (.bike, "indoor_bike"): nil
        case (.bike, _): (.cycling, .outdoor)
        case (.swim, "open_water"): (.swimming, .outdoor)
        case (.swim, _): (.swimming, .indoor)
        default: nil
        }
    }

    public static func customWorkout(_ w: PlannedWorkout) -> WatchWorkout? {
        guard let (activity, location) = activity(for: w) else { return nil }
        var warnings: [String] = []
        var nodes = w.resolved?.steps ?? []

        func step(_ s: Step) -> WorkoutStep {
            var goal: WorkoutGoal = switch s.duration {
            case .time(let sec): .time(Double(sec), .seconds)
            case .distance(let m): .distance(m, .meters)
            case .open: .open
            }
            if !CustomWorkout.supportsGoal(goal, activity: activity, location: location) {
                warnings.append("step \(s.id): goal not supported on the watch, using open")
                goal = .open
            }
            var alert: (any WorkoutAlert)?
            if let t = s.target {
                if let why = t.unresolved {
                    warnings.append("step \(s.id): no alert (\(why))")
                } else if let a = Self.alert(t, sport: w.sport) {
                    if CustomWorkout.supportsAlert(a, activity: activity, location: location) {
                        alert = a
                    } else {
                        warnings.append("step \(s.id): \(t.metric.rawValue) alert not supported for this activity")
                    }
                }
            }
            // RPE has no alert: show it as the step name so it is visible on the watch.
            let rpe = s.target.flatMap { $0.metric == .rpe ? Formats.target($0, sport: w.sport) : nil }
            return WorkoutStep(goal: goal, alert: alert, displayName: s.label ?? rpe)
        }

        func interval(_ s: Step) -> IntervalStep {
            let purpose: IntervalStep.Purpose = switch s.kind {
            case .work, .drill: .work
            case .recovery, .rest, .warmup, .cooldown: .recovery
            }
            return IntervalStep(purpose, step: step(s))
        }

        var warmup: WorkoutStep?
        var cooldown: WorkoutStep?
        if case .step(let first)? = nodes.first, first.kind == .warmup {
            warmup = step(first)
            nodes.removeFirst()
        }
        if case .step(let last)? = nodes.last, last.kind == .cooldown {
            cooldown = step(last)
            nodes.removeLast()
        }
        var blocks: [IntervalBlock] = nodes.map { node in
            switch node {
            case .step(let s): IntervalBlock(steps: [interval(s)], iterations: 1)
            case .repeats(_, let count, let steps): IntervalBlock(steps: steps.map(interval), iterations: count)
            }
        }
        // No structure (e.g. "easy by feel"): one open work step, so the workout is on the watch.
        if blocks.isEmpty && warmup == nil && cooldown == nil {
            blocks = [IntervalBlock(steps: [IntervalStep(.work, goal: .open)], iterations: 1)]
        }
        let workout = CustomWorkout(
            activity: activity, location: location, displayName: w.title,
            warmup: warmup, blocks: blocks, cooldown: cooldown
        )
        return WatchWorkout(workout: workout, warnings: warnings)
    }

    /// Main target → alert. Open bounds get wide defaults (WorkoutKit wants closed ranges).
    static func alert(_ t: Target, sport: Sport) -> (any WorkoutAlert)? {
        func range(_ lo: Double?, _ hi: Double?, min: Double, max: Double) -> ClosedRange<Double>? {
            let l = lo ?? min, h = hi ?? max
            return l <= h ? l...h : nil
        }
        switch t.metric {
        case .hr:
            return range(t.low, t.high, min: 40, max: 230).map { .heartRate($0) }
        case .power:
            return range(t.low, t.high, min: 0, max: 2500).map { .power($0, unit: .watts) }
        case .cadence:
            return range(t.low, t.high, min: 0, max: 250).map { .cadence($0) }
        case .speed:
            return range(t.low, t.high, min: 0.3, max: 30).map { .speed($0, unit: .metersPerSecond) }
        case .pace:
            // sec per km (swim: per 100 m) → m/s; faster pace (smaller number) = higher speed.
            let meters = sport == .swim ? 100.0 : 1000.0
            let fast = t.low.map { meters / $0 }, slow = t.high.map { meters / $0 }
            return range(slow, fast, min: 0.3, max: 30).map { .speed($0, unit: .metersPerSecond) }
        case .rpe:
            return nil
        }
    }
}

// MARK: - What to deliver

public struct DeliveryCandidate: Sendable, Equatable {
    public let workout: PlannedWorkout
    /// Hash of the stored record (plan + resolved targets): changes when anything changes.
    public let digest: String
    public let done: Bool
    /// Server version of the planned workout (reported back so the coach sees which one is on the watch).
    public let version: Int

    public init(workout: PlannedWorkout, digest: String, done: Bool, version: Int = 1) {
        self.workout = workout
        self.digest = digest
        self.done = done
        self.version = version
    }
}

public struct DesiredWorkout: Sendable {
    public let plannedWorkoutId: String
    public let version: Int
    public let localDate: LocalDate
    public let date: DateComponents
    public let plan: WorkoutPlan
    public let warnings: [String]
}

public enum WatchDelivery {
    public static let horizonDays = 7

    /// Today … +7 days, `execution == workoutkit`, not skipped, not done yet; earliest first,
    /// capped by the system limit.
    public static func desired(_ candidates: [DeliveryCandidate], profile: Profile, today: LocalDate,
                               limit: Int = 50) -> [DesiredWorkout] {
        let end = today.adding(days: horizonDays)
        return candidates
            .filter { c in
                let w = c.workout
                return w.execution == "workoutkit" && w.skipped == nil && !c.done && w.date >= today && w.date <= end
            }
            .sorted { ($0.workout.date, $0.workout.order) < ($1.workout.date, $1.workout.order) }
            .compactMap { c -> DesiredWorkout? in
                guard let built = WorkoutBridge.customWorkout(c.workout) else { return nil }
                let id = planId(c.workout.id, c.workout.date, c.digest)
                return DesiredWorkout(
                    plannedWorkoutId: c.workout.id,
                    version: c.version,
                    localDate: c.workout.date,
                    date: dateComponents(c.workout.date, timeZone: profile.timeZone(on: c.workout.date)),
                    plan: WorkoutPlan(.custom(built.workout), id: id),
                    warnings: built.warnings
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    /// Date only (S1: the watch shows it on that day; no time needed), in the plan's zone.
    static func dateComponents(_ date: LocalDate, timeZone: TimeZone) -> DateComponents {
        let parts = date.iso.split(separator: "-").map { Int($0)! }
        var c = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        c.timeZone = timeZone
        return c
    }

    /// Stable UUID from (planned workout, date, content).
    public static func planId(_ plannedId: String, _ date: LocalDate, _ digest: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data("\(plannedId)|\(date.iso)|\(digest)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50 // version 5-style
        bytes[8] = (bytes[8] & 0x3F) | 0x80 // RFC 4122 variant
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}

// MARK: - Reconcile

/// WorkoutScheduler behind a protocol, so reconciling is testable without a watch.
public protocol WatchScheduling: Sendable {
    func scheduled() async -> [ScheduledWorkoutPlan]
    func schedule(_ plan: WorkoutPlan, at date: DateComponents) async
    func remove(_ plan: WorkoutPlan, at date: DateComponents) async
}

public struct WatchReconcileResult: Sendable, Equatable {
    /// Planned workout ids that are on the watch after reconciling.
    public var onWatch: [String]
    /// The same, with what the server needs for POST /v1/deliveries.
    public var report: [DeliveryReportItem]
    public var added: Int
    public var removed: Int
    public var warnings: [String]
}

public enum WatchReconciler {
    /// Makes scheduled == desired: removes ours that are no longer wanted (not completed ones),
    /// adds what is missing. Ids encode content, so an edited workout is removed and re-added.
    public static func reconcile(desired: [DesiredWorkout], scheduler: WatchScheduling) async -> WatchReconcileResult {
        let wanted = Set(desired.map(\.plan.id))
        var removed = 0
        for s in await scheduler.scheduled() where !s.complete && !wanted.contains(s.plan.id) {
            await scheduler.remove(s.plan, at: s.date)
            removed += 1
        }
        let present = Set(await scheduler.scheduled().map(\.plan.id))
        var added = 0
        for d in desired where !present.contains(d.plan.id) {
            await scheduler.schedule(d.plan, at: d.date)
            added += 1
        }
        let after = Set(await scheduler.scheduled().map(\.plan.id))
        let delivered = desired.filter { after.contains($0.plan.id) }
        return WatchReconcileResult(
            onWatch: delivered.map(\.plannedWorkoutId),
            report: delivered.map {
                DeliveryReportItem(plannedWorkoutId: $0.plannedWorkoutId, version: $0.version, date: $0.localDate.iso,
                                   warnings: $0.warnings.isEmpty ? nil : $0.warnings)
            },
            added: added,
            removed: removed,
            warnings: desired.flatMap { d in d.warnings.map { "\(d.plannedWorkoutId): \($0)" } }
        )
    }
}

public struct SystemWatchScheduler: WatchScheduling {
    public init() {}
    public func scheduled() async -> [ScheduledWorkoutPlan] { await WorkoutScheduler.shared.scheduledWorkouts }
    public func schedule(_ plan: WorkoutPlan, at date: DateComponents) async {
        await WorkoutScheduler.shared.schedule(plan, at: date)
    }
    public func remove(_ plan: WorkoutPlan, at date: DateComponents) async {
        await WorkoutScheduler.shared.remove(plan, at: date)
    }
}

// MARK: - Report to the server

public struct DeliveryReportItem: Codable, Sendable, Equatable {
    public let plannedWorkoutId: String
    public let version: Int
    public let date: String
    public let warnings: [String]?
}

/// Body of POST /v1/deliveries: a snapshot of what is on the watch + the device's sync state.
public struct DeliveryReport: Codable, Sendable, Equatable {
    public struct Watch: Codable, Sendable, Equatable {
        public let error: String?
        public let items: [DeliveryReportItem]
    }

    public let deviceId: String
    public let deviceName: String?
    public let model: String?
    public let appVersion: String?
    public let lastPullAt: String?
    public let cursor: String?
    public let watch: Watch

    public init(deviceId: String, deviceName: String?, model: String?, appVersion: String?, lastPullAt: Date?,
                cursor: String?, error: String?, items: [DeliveryReportItem]) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.model = model
        self.appVersion = appVersion
        self.lastPullAt = lastPullAt.map { ISO8601DateFormatter().string(from: $0) }
        self.cursor = cursor
        self.watch = Watch(error: error, items: items)
    }
}
