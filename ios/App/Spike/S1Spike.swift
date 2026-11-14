#if DEBUG
import Foundation
import HealthKit
import UIKit
import WorkoutKit

/// Spike S1 (docs/09-roadmap.md): do HealthKit and WorkoutKit work on a free Personal Team?
/// Every check appends a line to the report; the report is saved to Documents/s1-report.json so the
/// agent can pull it with `xcrun devicectl device copy from …` without the athlete retyping anything.
@MainActor
final class S1Spike: ObservableObject {
    struct Entry: Codable, Identifiable {
        var id = UUID()
        let step: String
        let ok: Bool
        let detail: String
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var running = false

    private let store = HKHealthStore()
    private let markerPrefix = "S1 "

    private func add(_ step: String, _ ok: Bool, _ detail: String) {
        entries.append(Entry(step: step, ok: ok, detail: detail))
    }

    // MARK: - Run all

    func runAll() async {
        running = true
        entries = []
        environment()
        await healthKitAuthorization()
        await backgroundDelivery()
        await readRecentWorkouts()
        await workoutKitAuthorization()
        supportMatrix()
        await scheduleTestWorkouts()
        await listScheduled()
        saveReport()
        running = false
    }

    // MARK: - Steps

    private func environment() {
        let device = UIDevice.current
        add("environment", true, "\(device.model) iOS \(device.systemVersion); healthDataAvailable=\(HKHealthStore.isHealthDataAvailable()); WorkoutScheduler.isSupported=\(WorkoutScheduler.isSupported)")
    }

    private var readTypes: Set<HKObjectType> {
        var types: Set<HKObjectType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        let quantities: [HKQuantityTypeIdentifier] = [
            .heartRate, .restingHeartRate, .heartRateVariabilitySDNN, .vo2Max, .bodyMass,
            .distanceWalkingRunning, .distanceCycling, .distanceSwimming, .swimmingStrokeCount,
            .runningPower, .runningSpeed, .runningStrideLength, .runningVerticalOscillation,
            .runningGroundContactTime, .cyclingPower, .cyclingCadence, .activeEnergyBurned, .stepCount,
        ]
        for q in quantities { types.insert(HKQuantityType(q)) }
        types.insert(HKCategoryType(.sleepAnalysis))
        return types
    }

    private var shareTypes: Set<HKSampleType> {
        [
            HKObjectType.workoutType(), HKQuantityType(.heartRate), HKQuantityType(.cyclingPower),
            HKQuantityType(.cyclingCadence), HKQuantityType(.distanceCycling),
            HKQuantityType(.activeEnergyBurned),
        ]
    }

    private func healthKitAuthorization() async {
        do {
            try await store.requestAuthorization(toShare: shareTypes, read: readTypes)
            let write = store.authorizationStatus(for: HKObjectType.workoutType())
            add("healthkit.authorization", true, "requested; workout write status=\(write.rawValue) (2=authorized; read status is never revealed)")
        } catch {
            add("healthkit.authorization", false, String(describing: error))
        }
    }

    private func backgroundDelivery() async {
        do {
            try await store.enableBackgroundDelivery(for: HKObjectType.workoutType(), frequency: .immediate)
            try await store.enableBackgroundDelivery(for: HKQuantityType(.stepCount), frequency: .hourly)
            add("healthkit.background_delivery", true, "workouts=.immediate, stepCount=.hourly enabled")
        } catch {
            add("healthkit.background_delivery", false, String(describing: error))
        }
    }

    private func readRecentWorkouts() async {
        do {
            let workouts: [HKWorkout] = try await withCheckedThrowingContinuation { cont in
                let q = HKSampleQuery(
                    sampleType: .workoutType(), predicate: nil, limit: 5,
                    sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: false)]
                ) { _, samples, error in
                    if let error { cont.resume(throwing: error) } else { cont.resume(returning: (samples as? [HKWorkout]) ?? []) }
                }
                store.execute(q)
            }
            add("healthkit.read_workouts", !workouts.isEmpty, "found \(workouts.count) recent workouts")
            for w in workouts {
                let km = (w.totalDistance?.doubleValue(for: .meter()) ?? 0) / 1000
                let meta = (w.metadata ?? [:]).keys.sorted().joined(separator: ",")
                add("workout", true, "\(w.workoutActivityType.rawValue) \(w.startDate.formatted()) \(Int(w.duration / 60))min \(String(format: "%.2f", km))km src=\(w.sourceRevision.source.name) activities=\(w.workoutActivities.count) events=\(w.workoutEvents?.count ?? 0) meta=[\(meta)]")
            }
            if let latest = workouts.first {
                await detail(of: latest)
            }
        } catch {
            add("healthkit.read_workouts", false, String(describing: error))
        }
    }

    private func detail(of workout: HKWorkout) async {
        let predicate = HKQuery.predicateForObjects(from: workout)
        for (name, id) in [("heartRate", HKQuantityTypeIdentifier.heartRate), ("runningPower", .runningPower), ("runningSpeed", .runningSpeed), ("cyclingPower", .cyclingPower), ("distanceSwimming", .distanceSwimming)] {
            let count: Int = await withCheckedContinuation { cont in
                let q = HKSampleQuery(sampleType: HKQuantityType(id), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                    cont.resume(returning: samples?.count ?? 0)
                }
                store.execute(q)
            }
            add("latest.samples.\(name)", true, "\(count) samples")
        }
        let routes: [HKWorkoutRoute] = await withCheckedContinuation { cont in
            let q = HKSampleQuery(sampleType: HKSeriesType.workoutRoute(), predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, samples, _ in
                cont.resume(returning: (samples as? [HKWorkoutRoute]) ?? [])
            }
            store.execute(q)
        }
        var points = 0
        for route in routes {
            points += await withCheckedContinuation { cont in
                var n = 0
                let q = HKWorkoutRouteQuery(route: route) { _, locations, done, _ in
                    n += locations?.count ?? 0
                    if done { cont.resume(returning: n) }
                }
                store.execute(q)
            }
        }
        add("latest.route", true, "\(routes.count) route(s), \(points) points")
        if let temp = workout.metadata?[HKMetadataKeyWeatherTemperature] as? HKQuantity {
            add("latest.weather", true, "temp=\(temp) humidity=\(String(describing: workout.metadata?[HKMetadataKeyWeatherHumidity] ?? "-"))")
        } else {
            add("latest.weather", false, "no weather metadata on latest workout")
        }
    }

    private func workoutKitAuthorization() async {
        let state = await WorkoutScheduler.shared.requestAuthorization()
        add("workoutkit.authorization", state == .authorized, "state=\(state)")
    }

    private func supportMatrix() {
        let cases: [(String, HKWorkoutActivityType, HKWorkoutSessionLocationType)] = [
            ("run outdoor", .running, .outdoor), ("bike outdoor", .cycling, .outdoor),
            ("bike indoor", .cycling, .indoor), ("swim pool", .swimming, .indoor),
            ("swim open water", .swimming, .outdoor),
        ]
        for (name, activity, location) in cases {
            let activityOK = CustomWorkout.supportsActivity(activity)
            let open = CustomWorkout.supportsGoal(.open, activity: activity, location: location)
            let distance = CustomWorkout.supportsGoal(.distance(100, .meters), activity: activity, location: location)
            add("workoutkit.supports.\(name)", activityOK, "activity=\(activityOK) goal.open=\(open) goal.distance=\(distance)")
        }
    }

    private func dateOnly(daysFromNow: Int) -> DateComponents {
        let d = Calendar.current.date(byAdding: .day, value: daysFromNow, to: .now)!
        return Calendar.current.dateComponents([.year, .month, .day], from: d)
    }

    private func withTime(daysFromNow: Int, hour: Int) -> DateComponents {
        var c = dateOnly(daysFromNow: daysFromNow)
        c.hour = hour
        c.minute = 0
        return c
    }

    private func runWorkout() -> CustomWorkout {
        let work = IntervalStep(.work, goal: .time(1, .minutes), alert: .heartRate(150...160))
        let recover = IntervalStep(.recovery, goal: .time(1, .minutes), alert: .heartRate(100...140))
        return CustomWorkout(
            activity: .running, location: .outdoor, displayName: "\(markerPrefix)Run 3×1′ HR",
            warmup: WorkoutStep(goal: .open, alert: .heartRate(125...145)),
            blocks: [IntervalBlock(steps: [work, recover], iterations: 3)],
            cooldown: WorkoutStep(goal: .open)
        )
    }

    private func bikeWorkout() -> CustomWorkout {
        let work = IntervalStep(.work, goal: .time(5, .minutes), alert: .power(180...200, unit: .watts))
        return CustomWorkout(
            activity: .cycling, location: .outdoor, displayName: "\(markerPrefix)Bike power",
            warmup: WorkoutStep(goal: .time(10, .minutes)),
            blocks: [IntervalBlock(steps: [work], iterations: 2)],
            cooldown: WorkoutStep(goal: .open)
        )
    }

    private func swimWorkout() -> CustomWorkout {
        let work = IntervalStep(.work, goal: .distance(100, .meters))
        let rest = IntervalStep(.recovery, goal: .time(30, .seconds))
        return CustomWorkout(
            activity: .swimming, location: .indoor, displayName: "\(markerPrefix)Swim 4×100",
            warmup: WorkoutStep(goal: .distance(200, .meters)),
            blocks: [IntervalBlock(steps: [work, rest], iterations: 4)],
            cooldown: WorkoutStep(goal: .distance(100, .meters))
        )
    }

    private func scheduleTestWorkouts() async {
        let plans: [(String, () -> CustomWorkout, DateComponents)] = [
            ("run date-only", runWorkout, dateOnly(daysFromNow: 1)),
            ("run with time", runWorkout, withTime(daysFromNow: 2, hour: 7)),
            ("bike date-only", bikeWorkout, dateOnly(daysFromNow: 1)),
            ("swim pool date-only", swimWorkout, dateOnly(daysFromNow: 1)),
        ]
        for (name, make, when) in plans {
            do {
                let workout = make()
                await WorkoutScheduler.shared.schedule(WorkoutPlan(.custom(workout)), at: when)
                add("workoutkit.schedule.\(name)", true, "scheduled at \(when)")
            } catch {
                add("workoutkit.schedule.\(name)", false, String(describing: error))
            }
        }
    }

    private func listScheduled() async {
        let scheduled = await WorkoutScheduler.shared.scheduledWorkouts
        add("workoutkit.scheduled", !scheduled.isEmpty, "\(scheduled.count) scheduled (max \(WorkoutScheduler.maxAllowedScheduledWorkoutCount))")
        for s in scheduled {
            add("scheduled", true, "\(s.date) complete=\(s.complete) plan=\(s.plan.id)")
        }
    }

    func removeSpikeWorkouts() async {
        for s in await WorkoutScheduler.shared.scheduledWorkouts {
            await WorkoutScheduler.shared.remove(s.plan, at: s.date)
        }
        add("workoutkit.cleanup", true, "removed all scheduled workouts")
        saveReport()
    }

    // MARK: - Report

    static var reportURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appending(path: "s1-report.json")
    }

    private func saveReport() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        struct Report: Codable { let at: Date; let entries: [Entry] }
        do {
            try encoder.encode(Report(at: .now, entries: entries)).write(to: Self.reportURL)
        } catch {
            add("report.save", false, String(describing: error))
        }
    }
}
#endif
