import Foundation
import Testing
@testable import Zone2Kit

private let gymJSON = #"""
{ "id": "w-gym", "date": "2026-11-15", "order": 0, "sport": "strength", "title": "Зал A", "execution": "none",
  "structure": { "items": [
    { "type": "exercise", "id": "sq", "exercise": "Присед", "sets": 3, "reps": 6, "weightKg": 70 },
    { "type": "exercise", "id": "rdl", "exercise": "Тяга", "setList": [ { "reps": 8, "weightKg": 60 }, { "reps": 6, "weightKg": 65 } ] },
    { "type": "superset", "id": "core", "rounds": 2, "items": [ { "exercise": "Планка", "holdSec": 45 }, { "exercise": "Скручивания", "reps": 15 } ] } ] } }
"""#

private func counter() -> () -> String {
    var n = 0
    return { n += 1; return "id\(n)" }
}

@Test func draftFromPlan() throws {
    let w = try JSONDecoder().decode(PlannedWorkout.self, from: Data(gymJSON.utf8))
    let s = StrengthSession.draft(from: w, newId: counter())
    #expect(s.exercises.map(\.name) == ["Присед", "Тяга", "Планка", "Скручивания"])
    #expect(s.exercises[0].sets.count == 3)
    #expect(s.exercises[1].sets.map { $0.planned?.weightKg } == [60, 65])
    #expect(s.exercises[2].sets.count == 2 && s.exercises[2].sets[0].planned?.holdSec == 45)
    #expect(s.doneCount == 0 && s.plannedWorkoutId == "w-gym")
    #expect(s.exercises[0].sets[0].planned?.formatted(units: .english) == "70 kg × 6")
    #expect(s.exercises[3].sets[0].planned?.formatted(units: .english) == "× 15")
    #expect(s.exercises[2].sets[0].planned?.formatted(units: .english) == "45 s")
}

@Test func tapEditAddSet() throws {
    let w = try JSONDecoder().decode(PlannedWorkout.self, from: Data(gymJSON.utf8))
    var s = StrengthSession.draft(from: w, newId: counter())
    let sq = s.exercises[0].sets
    s.toggle(sq[0].id)
    #expect(s.exercises[0].sets[0].actual == Load(reps: 6, weightKg: 70))
    s.setActual(sq[1].id, Load(reps: 5, weightKg: 72.5))
    s.toggle(sq[0].id) // undo
    #expect(s.exercises[0].sets[0].actual == nil && s.doneCount == 1)
    s.addSet(to: "Присед", newId: "extra")
    let extra = try #require(s.sets.first { $0.id == "extra" })
    #expect(extra.setIndex == 3 && extra.order == 0)
    #expect(extra.planned == Load(reps: 6, weightKg: 70)) // like the last set (its plan; it is not done)
    s.toggle("extra")
    #expect(s.sets.first { $0.id == "extra" }?.actual == Load(reps: 6, weightKg: 70))
}

@Test func savedSessionMarksDayDoneAndSurvivesFeed() throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now) // has w-gym on 2026-11-14 (strength)
    let snap0 = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    let gym = try #require(snap0.day(LocalDate("2026-11-14")!)?.planned.first)
    #expect(gym.status == .missed)

    var s = StrengthSession.draft(from: gym.workout, newId: counter())
    s.toggle(s.sets[0].id)
    try store.saveStrength(s, now: now)
    #expect(try store.outboxAll().map(\.id) == ["strength-\(s.id)"])
    let snap1 = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    #expect(snap1.day(LocalDate("2026-11-14")!)?.planned.first?.status == .done)

    // A snapshot or an older server copy must not wipe unsent local edits.
    var stale = s
    stale.sets[0].actual = nil
    let serverCopy = SyncChange(entity: "strength_session", id: s.id, op: "upsert", version: 1,
                                data: try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(stale)))
    try store.apply(try page(snapshotJSON), at: now) // full resync: local session kept
    try store.apply(SyncPage(changes: [serverCopy], cursor: "50", hasMore: false, snapshot: false, serverTime: nil), at: now)
    let snap2 = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    #expect(snap2.day(LocalDate("2026-11-14")!)?.planned.first?.status == .done)

    // Once sent, the server copy wins again.
    try store.outboxSent("strength-\(s.id)")
    try store.apply(SyncPage(changes: [serverCopy], cursor: "51", hasMore: false, snapshot: false, serverTime: nil), at: now)
    let snap3 = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    #expect(snap3.day(LocalDate("2026-11-14")!)?.planned.first?.status == .missed)
}
