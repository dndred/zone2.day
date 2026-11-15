import Foundation
import Testing
import WorkoutKit
@testable import Zone2Kit

private func workout(_ json: String) throws -> PlannedWorkout {
    try JSONDecoder().decode(PlannedWorkout.self, from: Data(json.utf8))
}

private let tempoJSON = #"""
{ "id": "w-tempo", "date": "2026-11-16", "order": 0, "sport": "run", "title": "Tempo", "execution": "workoutkit",
  "resolved": { "steps": [
    { "type": "step", "id": "wu", "kind": "warmup", "duration": { "type": "time", "sec": 900 },
      "target": { "metric": "hr", "low": 120, "high": 140, "unit": "abs" } },
    { "type": "repeat", "id": "r", "count": 6, "steps": [
      { "type": "step", "id": "s", "kind": "work", "label": "Hill", "duration": { "type": "time", "sec": 12 },
        "target": { "metric": "rpe", "low": 9, "high": 10, "unit": "abs" } },
      { "type": "step", "id": "w", "kind": "recovery", "duration": { "type": "time", "sec": 105 } } ] },
    { "type": "step", "id": "t", "kind": "work", "duration": { "type": "distance", "m": 5000 },
      "target": { "metric": "pace", "low": 295, "high": 305, "unit": "abs" } },
    { "type": "step", "id": "x", "kind": "work", "duration": { "type": "time", "sec": 600 },
      "target": { "metric": "hr", "low": 150, "unit": "pct_threshold", "unresolved": "no threshold for hr/run" } },
    { "type": "step", "id": "cd", "kind": "cooldown", "duration": { "type": "open" } } ] } }
"""#

@Test func bridgeMapsStructureToCustomWorkout() throws {
    let built = try #require(WorkoutBridge.customWorkout(try workout(tempoJSON)))
    let w = built.workout
    #expect(w.activity == .running)
    #expect(w.location == .outdoor)
    #expect(w.displayName == "Tempo")
    #expect(w.warmup?.goal == .time(900, .seconds))
    #expect(w.warmup?.alert != nil)
    #expect(w.cooldown?.goal == .open)
    #expect(w.blocks.count == 3)
    #expect(w.blocks[0].iterations == 6)
    #expect(w.blocks[0].steps.map(\.purpose) == [.work, .recovery])
    #expect(w.blocks[0].steps[0].step.displayName == "Hill") // RPE has no alert; label shown
    #expect(w.blocks[0].steps[0].step.alert == nil)
    #expect(w.blocks[1].steps[0].step.goal == .distance(5000, .meters))
    #expect(w.blocks[1].steps[0].step.alert != nil) // pace → speed alert
    #expect(w.blocks[2].steps[0].step.alert == nil) // unresolved %-target
    #expect(built.warnings == ["step x: no alert (no threshold for hr/run)"])
}

@Test func paceBecomesSpeedRange() throws {
    let a = WorkoutBridge.alert(Target(metric: .pace, low: 250, high: 400, unit: "abs", unresolved: nil), sport: .run)
    let speed = try #require(a as? SpeedRangeAlert)
    #expect(abs(speed.target.lowerBound.converted(to: .metersPerSecond).value - 2.5) < 0.001) // 400 s/km
    #expect(abs(speed.target.upperBound.converted(to: .metersPerSecond).value - 4.0) < 0.001) // 250 s/km
}

@Test func unstructuredAndUndeliverable() throws {
    let easy = try #require(WorkoutBridge.customWorkout(try workout(
        #"{ "id": "e", "date": "2026-11-16", "sport": "run", "title": "Easy", "execution": "workoutkit" }"#)))
    #expect(easy.workout.blocks.count == 1)
    #expect(easy.workout.blocks[0].steps.first?.step.goal == .open)
    #expect(WorkoutBridge.customWorkout(try workout(
        #"{ "id": "b", "date": "2026-11-16", "sport": "bike", "subSport": "indoor_bike", "title": "ERG", "execution": "workoutkit" }"#)) == nil)
    #expect(WorkoutBridge.customWorkout(try workout(
        #"{ "id": "g", "date": "2026-11-16", "sport": "strength", "title": "Gym", "execution": "none" }"#)) == nil)
}

@Test func desiredFiltersAndIdsFollowContent() throws {
    let today = LocalDate("2026-11-15")!
    func c(_ id: String, _ date: String, exec: String = "workoutkit", skipped: Bool = false, done: Bool = false, digest: String = "d1") throws -> DeliveryCandidate {
        let skip = skipped ? #", "skipped": { "reason": "sick" }"# : ""
        return DeliveryCandidate(workout: try workout(
            #"{ "id": "\#(id)", "date": "\#(date)", "sport": "run", "title": "\#(id)", "execution": "\#(exec)"\#(skip) }"#),
            digest: digest, done: done)
    }
    var profile = Profile()
    profile.timezone = "Asia/Barnaul"
    let desired = WatchDelivery.desired([
        try c("later", "2026-11-18"),
        try c("today", "2026-11-15"),
        try c("past", "2026-11-14"),
        try c("far", "2026-11-23"),
        try c("whoosh", "2026-11-16", exec: "mywhoosh"),
        try c("skipped", "2026-11-16", skipped: true),
        try c("done", "2026-11-15", done: true),
    ], profile: profile, today: today)
    #expect(desired.map(\.plannedWorkoutId) == ["today", "later"])
    #expect(desired[0].date.day == 15 && desired[0].date.hour == nil)
    #expect(desired[0].date.timeZone?.identifier == "Asia/Barnaul")

    let a = WatchDelivery.planId("w", today, "d1")
    #expect(a == WatchDelivery.planId("w", today, "d1"))
    #expect(a != WatchDelivery.planId("w", today, "d2"))
    #expect(a != WatchDelivery.planId("w", today.adding(days: 1), "d1"))
}

private actor FakeScheduler: WatchScheduling {
    var plans: [ScheduledWorkoutPlan] = []
    var calls: [String] = []

    func scheduled() async -> [ScheduledWorkoutPlan] { plans }
    func schedule(_ plan: WorkoutPlan, at date: DateComponents) async {
        calls.append("add")
        plans.append(ScheduledWorkoutPlan(plan, date: date))
    }
    func remove(_ plan: WorkoutPlan, at date: DateComponents) async {
        calls.append("remove")
        plans.removeAll { $0.plan.id == plan.id }
    }
    func seed(_ p: ScheduledWorkoutPlan) { plans.append(p) }
}

@Test func reconcilerReplacesChangedAndKeepsCompleted() async throws {
    let today = LocalDate("2026-11-15")!
    let w = try workout(tempoJSON)
    let v1 = WatchDelivery.desired([DeliveryCandidate(workout: w, digest: "v1", done: false)], profile: Profile(), today: today)
    let v2 = WatchDelivery.desired([DeliveryCandidate(workout: w, digest: "v2", done: false)], profile: Profile(), today: today)
    let scheduler = FakeScheduler()

    var r = await WatchReconciler.reconcile(desired: v1, scheduler: scheduler)
    #expect(r.onWatch == ["w-tempo"] && r.added == 1 && r.removed == 0)
    #expect(r.report == [DeliveryReportItem(plannedWorkoutId: "w-tempo", version: 1, date: "2026-11-16",
                                            warnings: ["step x: no alert (no threshold for hr/run)"])])

    r = await WatchReconciler.reconcile(desired: v1, scheduler: scheduler) // idempotent
    #expect(r.added == 0 && r.removed == 0)

    var completed = ScheduledWorkoutPlan(WorkoutPlan(.custom(v1[0].plan.workout.custom!), id: UUID()), date: v1[0].date)
    completed.complete = true
    await scheduler.seed(completed)
    r = await WatchReconciler.reconcile(desired: v2, scheduler: scheduler) // edited → replace
    #expect(r.added == 1 && r.removed == 1)
    #expect(await scheduler.plans.count == 2) // v2 + the completed one stays

    r = await WatchReconciler.reconcile(desired: [], scheduler: scheduler) // deleted from plan
    #expect(r.removed == 1 && r.onWatch.isEmpty)
}

private extension WorkoutPlan.Workout {
    var custom: CustomWorkout? {
        if case .custom(let w) = self { return w }
        return nil
    }
}
