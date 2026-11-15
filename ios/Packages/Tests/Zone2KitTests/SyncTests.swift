import Foundation
import Testing
@testable import Zone2Kit

/// A page shaped like GET /v1/sync output (backend/src/sync/feed.ts).
let snapshotJSON = #"""
{
  "snapshot": true, "hasMore": false, "cursor": "42", "serverTime": "2026-11-15T10:00:00Z",
  "changes": [
    { "entity": "profile", "id": "profile", "op": "upsert", "version": 3,
      "data": { "timezone": "Asia/Barnaul", "run": { "lthr": 160 }, "futureField": [1, 2] } },
    { "entity": "week", "id": "2026-11-09", "op": "upsert", "version": 1,
      "data": { "weekStart": "2026-11-09", "title": "БАЗА — неделя 1", "header": "Вектор: Z2" } },
    { "entity": "planned_workout", "id": "w-tempo", "op": "upsert", "version": 2,
      "data": { "id": "w-tempo", "date": "2026-11-16", "order": 1, "sport": "run", "title": "Tempo",
                "goal": "Порог", "key": true, "tags": [], "execution": "workoutkit",
                "structure": { "steps": [] },
                "resolved": { "schema": 1, "steps": [
                  { "type": "step", "id": "wu", "kind": "warmup", "duration": { "type": "time", "sec": 900 } },
                  { "type": "repeat", "id": "r", "count": 3, "steps": [
                    { "type": "step", "id": "a", "kind": "work", "duration": { "type": "distance", "m": 1000 },
                      "target": { "metric": "pace", "low": 290, "high": 300, "unit": "abs" } },
                    { "type": "step", "id": "b", "kind": "recovery", "duration": { "type": "open" } } ] } ] } } },
    { "entity": "planned_workout", "id": "w-gym", "op": "upsert", "version": 1,
      "data": { "id": "w-gym", "date": "2026-11-14", "order": 0, "sport": "strength", "title": "Зал A",
                "execution": "none", "structure": { "schema": 1, "items": [
                  { "type": "exercise", "id": "sq", "exercise": "Присед", "sets": 3, "reps": 8, "weightKg": 60 } ] } } },
    { "entity": "planned_workout", "id": "w-run", "op": "upsert", "version": 1,
      "data": { "id": "w-run", "date": "2026-11-14", "order": 1, "sport": "run", "title": "Parkrun",
                "execution": "workoutkit" } },
    { "entity": "activity", "id": "a1", "op": "upsert", "version": 5,
      "data": { "id": "a1", "date": "2026-11-14", "startLocal": "08:33", "sport": "run", "kind": "training",
                "title": "Outdoor Run 11.7 km", "plannedWorkoutId": "w-run", "elapsedSec": 5191,
                "startAt": "2026-11-14T01:33:16Z",
                "summary": { "v": 7, "movingSec": 3950, "distanceM": 11684, "paceSecPerKm": 338,
                  "hr": { "avg": 136, "max": 162, "samples": 900 },
                  "running": { "powerAvg": 250, "cadenceSpm": 167 },
                  "intervals": [ { "startSec": 2407.8, "durationSec": 1526.2, "distanceM": 5062.7, "movingSec": 1517,
                                   "paceSecPerKm": 300, "avgHr": 156, "maxHr": 162, "cadence": 173 } ] },
                "laps": [ { "index": 0, "kind": "manual", "startSec": 0, "durationSec": 2407.8 } ] } },
    { "entity": "activity", "id": "a2", "op": "upsert", "version": 1,
      "data": { "id": "a2", "date": "2026-11-13", "sport": "other", "kind": "recovery",
                "summary": { "v": 7 }, "laps": [] } },
    { "entity": "journal", "id": "j1", "op": "upsert", "version": 1,
      "data": { "id": "j1", "date": "2026-11-14", "text": "Новые кроссовки", "tags": ["gear"] } },
    { "entity": "event", "id": "e1", "op": "upsert", "version": 1,
      "data": { "id": "e1", "name": "Half", "sport": "run", "status": "registered", "datePrecision": "day",
                "dateFrom": "2026-12-06", "dateTo": "2026-12-06" } }
  ]
}
"""#

func page(_ json: String) throws -> SyncPage {
    try JSONDecoder().decode(SyncPage.self, from: Data(json.utf8))
}

// 10:00 UTC = 17:00 in Barnaul → today is 2026-11-15 there.
let now = ISO8601DateFormatter().date(from: "2026-11-15T10:00:00Z")!

@Test func snapshotAppliesAndBuildsDays() throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now)
    let snap = try store.snapshot(from: LocalDate("2026-11-13")!, to: LocalDate("2026-11-16")!, now: now)

    #expect(snap.profile.timezone == "Asia/Barnaul")
    #expect(snap.today.iso == "2026-11-15")
    #expect(snap.status.cursor == "42")
    #expect(snap.status.lastSyncAt == now)
    #expect(snap.weeks[LocalDate("2026-11-09")!]?.title == "БАЗА — неделя 1")

    let sat = try #require(snap.day(LocalDate("2026-11-14")!))
    #expect(sat.planned.map(\.workout.title) == ["Зал A", "Parkrun"]) // by order
    #expect(sat.planned.map(\.status) == [.missed, .done])
    #expect(sat.planned[1].activities.first?.summary.intervals?.first?.paceSecPerKm == 300)
    #expect(sat.planned[0].workout.strength?.items.first?.exercise?.exercise == "Присед")
    #expect(sat.unplanned.isEmpty)
    #expect(sat.journal.first?.text == "Новые кроссовки")

    let fri = try #require(snap.day(LocalDate("2026-11-13")!))
    #expect(fri.unplanned.first?.isRecovery == true)

    let mon = try #require(snap.day(LocalDate("2026-11-16")!))
    let tempo = try #require(mon.planned.first)
    #expect(tempo.status == .planned)
    guard case .repeats(_, let count, let steps)? = tempo.workout.resolved?.steps.last else {
        Issue.record("repeat expected"); return
    }
    #expect(count == 3)
    #expect(steps.first?.target.map { Formats.target($0, sport: .run, units: .english) } == "4:50–5:00 /km")
    #expect(steps.last?.duration == .open(estimateSec: nil))
}

@Test func incrementUpdatesAndDeletes() throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now)
    try store.apply(try page(#"""
    { "snapshot": false, "hasMore": false, "cursor": "45", "changes": [
      { "entity": "planned_workout", "id": "w-tempo", "op": "upsert", "version": 3,
        "data": { "id": "w-tempo", "date": "2026-11-17", "order": 0, "sport": "run", "title": "Tempo moved", "execution": "workoutkit" } },
      { "entity": "planned_workout", "id": "w-gym", "op": "delete", "version": 2 },
      { "entity": "activity", "id": "a1", "op": "delete", "version": 6 }
    ] }
    """#), at: now)
    let snap = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-17")!, now: now)
    #expect(snap.status.cursor == "45")
    #expect(snap.day(LocalDate("2026-11-16")!)?.planned.isEmpty == true)
    #expect(snap.day(LocalDate("2026-11-17")!)?.planned.first?.workout.title == "Tempo moved")
    let sat = try #require(snap.day(LocalDate("2026-11-14")!))
    #expect(sat.planned.map(\.workout.title) == ["Parkrun"])
    #expect(sat.planned.first?.status == .missed) // its activity is gone
}

private actor FakeSource: SyncSource {
    var pages: [Result<SyncPage, Error>]
    var cursors: [String?] = []

    init(_ pages: [Result<SyncPage, Error>]) { self.pages = pages }

    func page(cursor: String?) async throws -> SyncPage {
        cursors.append(cursor)
        return try pages.removeFirst().get()
    }
}

@Test func engineDrainsPagesAndResyncsOn410() async throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now)
    let more = try page(#"{ "snapshot": false, "hasMore": true, "cursor": "50", "changes": [] }"#)
    let last = try page(#"{ "snapshot": false, "hasMore": false, "cursor": "51", "changes": [] }"#)
    let source = FakeSource([
        .failure(APIError.status(410, body: "cursor_gone")),
        .success(try page(snapshotJSON.replacingOccurrences(
            of: #""hasMore": false, "cursor": "42""#, with: #""hasMore": true, "cursor": "49""#))),
        .success(more),
        .success(last),
    ])
    let engine = SyncEngine(store: store, source: source)
    let outcome = await engine.pull()
    #expect(outcome == .synced(changes: 9, pages: 3))
    #expect(await source.cursors == ["42", nil, "49", "50"])
    #expect(try store.cursor() == "51")
}

@Test func engineRecordsErrorsAndKeepsData() async throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now)
    let engine = SyncEngine(store: store, source: FakeSource([.failure(URLError(.notConnectedToInternet))]))
    #expect(await engine.pull() == .failed("offline"))
    let snap = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    #expect(snap.status.lastError == "offline")
    #expect(snap.day(LocalDate("2026-11-14")!)?.planned.count == 2) // offline-first: data stays
}

@Test func syncRequestCarriesCursorInQuery() {
    let url = APIClient.url(URL(string: "https://api-staging.zone2.day")!, "v1/sync?limit=500&cursor=42")
    #expect(url.absoluteString == "https://api-staging.zone2.day/v1/sync?limit=500&cursor=42")
}

@Test func fileStoreWorksInFolderWithSpaces() throws {
    let dir = FileManager.default.temporaryDirectory.appending(path: "zone2 test \(UUID().uuidString)/Application Support")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
    try LocalStore(directory: dir).apply(try page(snapshotJSON), at: now)
    #expect(FileManager.default.fileExists(atPath: dir.appending(path: "zone2.sqlite").path(percentEncoded: false)))
    #expect(try LocalStore(directory: dir).cursor() == "42") // survives reopening
}

/// One planned workout, two recordings (watch restarted mid-run): both belong to it, none is "unplanned".
@Test func workoutRecordedInTwoPartsShowsBothAndTheTotal() throws {
    let store = try LocalStore()
    try store.apply(try page(snapshotJSON), at: now)
    let second = #"""
    { "changes": [
        { "entity": "activity", "id": "a3", "op": "upsert", "version": 1,
          "data": { "id": "a3", "date": "2026-11-14", "startLocal": "10:05", "sport": "run", "kind": "training",
                    "plannedWorkoutId": "w-run", "elapsedSec": 720,
                    "summary": { "v": 9, "movingSec": 700, "distanceM": 2000 }, "laps": [] } } ],
      "cursor": "43", "hasMore": false, "snapshot": false, "serverTime": "2026-11-15T10:00:00Z" }
    """#
    try store.apply(try page(second), at: now)
    let snap = try store.snapshot(from: LocalDate("2026-11-14")!, to: LocalDate("2026-11-14")!, now: now)
    let sat = try #require(snap.day(LocalDate("2026-11-14")!))
    let run = try #require(sat.planned.first { $0.workout.id == "w-run" })
    #expect(run.activities.map(\.id) == ["a1", "a3"]) // start order
    #expect(run.totalDistanceM == 13684)
    #expect(run.totalMovingSec == 4650)
    #expect(sat.unplanned.isEmpty)
}
