import CryptoKit
import Foundation
import GRDB

/// One change from GET /v1/sync (docs/05-sync.md §2).
public struct SyncChange: Codable, Sendable, Equatable {
    public let entity: String
    public let id: String
    public let op: String
    public let version: Int
    public let data: JSONValue?

    public init(entity: String, id: String, op: String, version: Int, data: JSONValue?) {
        self.entity = entity
        self.id = id
        self.op = op
        self.version = version
        self.data = data
    }
}

public struct SyncPage: Codable, Sendable, Equatable {
    public let changes: [SyncChange]
    public let cursor: String
    public let hasMore: Bool
    public let snapshot: Bool
    public let serverTime: String?

    public init(changes: [SyncChange], cursor: String, hasMore: Bool, snapshot: Bool, serverTime: String?) {
        self.changes = changes
        self.cursor = cursor
        self.hasMore = hasMore
        self.snapshot = snapshot
        self.serverTime = serverTime
    }
}

public struct SyncStatus: Sendable, Equatable {
    public var cursor: String?
    public var lastSyncAt: Date?
    public var lastError: String?
    public var records: Int = 0
    /// Planned workout ids scheduled on the watch by the last reconcile.
    public var onWatch: Set<String> = []
    public var watchAt: Date?
    public var watchError: String?
    /// Messages waiting to be sent, and the last send error among them.
    public var outboxPending: Int = 0
    public var outboxError: String?
}

/// Last watch delivery, stored in sync_state as JSON.
public struct WatchState: Codable, Sendable, Equatable {
    public var onWatch: [String]
    public var at: Date
    public var error: String?
    public var warnings: [String]

    public init(onWatch: [String], at: Date, error: String?, warnings: [String]) {
        self.onWatch = onWatch
        self.at = at
        self.error = error
        self.warnings = warnings
    }
}

/// Everything a plan screen needs for a date range, read in one consistent snapshot.
public struct PlanSnapshot: Sendable, Equatable {
    public var profile: Profile
    public var today: LocalDate
    public var days: [Day]
    public var weeks: [LocalDate: Week]
    public var status: SyncStatus

    public func day(_ date: LocalDate) -> Day? { days.first { $0.date == date } }
}

/// Offline storage (GRDB). The UI reads only from here (rule 1: offline-first); the network
/// writes only through `apply`. Records are kept as the server's JSON, decoded on read.
public final class LocalStore: Sendable {
    public let db: DatabaseQueue

    /// File-backed store; `path` nil → in-memory (tests, previews).
    public init(path: String? = nil) throws {
        db = try path.map { try DatabaseQueue(path: $0) } ?? DatabaseQueue()
        try Self.migrator.migrate(db)
    }

    public static func appDefault() throws -> LocalStore {
        let dir = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return try LocalStore(directory: dir)
    }

    /// `zone2.sqlite` in a directory. Note: `URL.path()` percent-encodes ("Application%20Support"),
    /// which silently pointed SQLite at a non-existent folder — always use percentEncoded: false.
    public convenience init(directory: URL) throws {
        try self.init(path: directory.appending(path: "zone2.sqlite").path(percentEncoded: false))
    }

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.create(table: "record") { t in
                t.column("entity", .text).notNull()
                t.column("id", .text).notNull()
                t.column("version", .integer).notNull()
                t.column("date", .text) // plan date / activity date / week start / event dateFrom
                t.column("data", .blob).notNull()
                t.primaryKey(["entity", "id"])
            }
            try db.create(index: "record_date", on: "record", columns: ["entity", "date"])
            try db.create(table: "sync_state") { t in
                t.primaryKey("key", .text)
                t.column("value", .text)
            }
        }
        m.registerMigration("v2-outbox") { db in
            // Everything the phone sends up goes through here (docs/05-sync.md §3): survives
            // restarts and offline, retried with backoff. `id` is the idempotency key.
            try db.create(table: "outbox") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull()
                t.column("payload", .blob).notNull()
                t.column("attempts", .integer).notNull().defaults(to: 0)
                t.column("nextAttemptAt", .double).notNull()
                t.column("lastError", .text)
                t.column("createdAt", .double).notNull()
            }
        }
        m.registerMigration("v3-streams") { db in
            // Curves for the activity screen: fetched once per activity, kept offline.
            try db.create(table: "stream_cache") { t in
                t.primaryKey("activityId", .text)
                t.column("data", .blob).notNull()
                t.column("fetchedAt", .double).notNull()
            }
        }
        return m
    }

    // MARK: Outbox

    public struct OutboxItem: Sendable, Equatable {
        public let id: String
        public let kind: String
        public let payload: Data
        public let attempts: Int
        public let lastError: String?
    }

    /// Adds or replaces (same id = same logical message, e.g. the latest delivery report).
    public func enqueue(id: String, kind: String, payload: Data, now: Date = Date()) throws {
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO outbox (id, kind, payload, attempts, nextAttemptAt, lastError, createdAt) VALUES (?, ?, ?, 0, ?, NULL, ?)
                ON CONFLICT (id) DO UPDATE SET payload = excluded.payload, attempts = 0, nextAttemptAt = excluded.nextAttemptAt, lastError = NULL
                """,
                arguments: [id, kind, payload, now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
        }
    }

    public func dueOutbox(now: Date = Date()) throws -> [OutboxItem] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbox WHERE nextAttemptAt <= ? ORDER BY createdAt", arguments: [now.timeIntervalSince1970])
                .map { OutboxItem(id: $0["id"], kind: $0["kind"], payload: $0["payload"], attempts: $0["attempts"], lastError: $0["lastError"]) }
        }
    }

    public func outboxAll() throws -> [OutboxItem] {
        try db.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM outbox ORDER BY createdAt")
                .map { OutboxItem(id: $0["id"], kind: $0["kind"], payload: $0["payload"], attempts: $0["attempts"], lastError: $0["lastError"]) }
        }
    }

    public func outboxSent(_ id: String) throws {
        try db.write { db in try db.execute(sql: "DELETE FROM outbox WHERE id = ?", arguments: [id]) }
    }

    public func outboxFailed(_ id: String, error: String, retryAt: Date) throws {
        try db.write { db in
            try db.execute(sql: "UPDATE outbox SET attempts = attempts + 1, lastError = ?, nextAttemptAt = ? WHERE id = ?",
                           arguments: [error, retryAt.timeIntervalSince1970, id])
        }
    }

    // MARK: Strength

    /// Saves a gym session locally (UI updates at once) and queues it for the server.
    public func saveStrength(_ s: StrengthSession, now: Date = Date()) throws {
        let data = try JSONEncoder().encode(s)
        try db.write { db in
            try db.execute(
                sql: """
                INSERT INTO record (entity, id, version, date, data) VALUES ('strength_session', ?, 0, ?, ?)
                ON CONFLICT (entity, id) DO UPDATE SET date = excluded.date, data = excluded.data
                """,
                arguments: [s.id, s.date.iso, data]
            )
            try db.execute(
                sql: """
                INSERT INTO outbox (id, kind, payload, attempts, nextAttemptAt, lastError, createdAt) VALUES (?, 'strength', ?, 0, ?, NULL, ?)
                ON CONFLICT (id) DO UPDATE SET payload = excluded.payload, attempts = 0, nextAttemptAt = excluded.nextAttemptAt, lastError = NULL
                """,
                arguments: ["strength-\(s.id)", data, now.timeIntervalSince1970, now.timeIntervalSince1970]
            )
        }
    }

    static func strengthSessions(_ db: Database, sql: String, _ args: StatementArguments) throws -> [StrengthSession] {
        try decode(StrengthSession.self, db, sql: sql, args)
    }

    /// The session logged for a planned workout (nil until the first tap in the gym).
    public func observeStrength(plannedWorkoutId: String) -> AsyncValueObservation<StrengthSession?> {
        ValueObservation.tracking { db in
            try Self.strengthSessions(db, sql: "SELECT data FROM record WHERE entity = 'strength_session'", [])
                .first { $0.plannedWorkoutId == plannedWorkoutId }
        }
        .removeDuplicates()
        .values(in: db)
    }

    // MARK: Notebook & streams

    public func observeNotebook() -> AsyncValueObservation<[NotebookPage]> {
        ValueObservation.tracking { db in
            try Self.decode(NotebookPage.self, db, sql: "SELECT data FROM record WHERE entity = 'notebook_page'", [])
                .sorted { ($0.pinned ? 0 : 1, $0.title) < ($1.pinned ? 0 : 1, $1.title) }
        }
        .removeDuplicates()
        .values(in: db)
    }

    public func saveStreams(_ s: ActivityStreams, activityId: String, now: Date = Date()) throws {
        let data = try JSONEncoder().encode(s)
        try db.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO stream_cache (activityId, data, fetchedAt) VALUES (?, ?, ?)",
                           arguments: [activityId, data, now.timeIntervalSince1970])
        }
    }

    public func hasStreams(_ activityId: String) throws -> Bool {
        try db.read { db in try Bool.fetchOne(db, sql: "SELECT 1 FROM stream_cache WHERE activityId = ?", arguments: [activityId]) ?? false }
    }

    public func observeStreams(_ activityId: String) -> AsyncValueObservation<ActivityStreams?> {
        ValueObservation.tracking { db in
            try Data.fetchOne(db, sql: "SELECT data FROM stream_cache WHERE activityId = ?", arguments: [activityId])
                .flatMap { try? JSONDecoder().decode(ActivityStreams.self, from: $0) }
        }
        .removeDuplicates()
        .values(in: db)
    }

    /// Stable id of this app install (kept across resyncs).
    public func deviceId() throws -> String {
        try db.write { db in
            if let id = try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'deviceId'") { return id }
            let id = UUID().uuidString.lowercased()
            try Self.set(db, "deviceId", id)
            return id
        }
    }

    // MARK: Write

    /// Applies one feed page in a single transaction. A snapshot page replaces everything.
    public func apply(_ page: SyncPage, at now: Date = Date()) throws {
        let encoder = JSONEncoder()
        try db.write { db in
            // Gym sessions with unsent local edits stay: the phone is their source of truth until sent.
            let pending = Set(try String.fetchAll(db, sql: "SELECT substr(id, 10) FROM outbox WHERE kind = 'strength'"))
            if page.snapshot {
                try db.execute(sql: "DELETE FROM record WHERE NOT (entity = 'strength_session' AND 'strength-' || id IN (SELECT id FROM outbox))")
            }
            for c in page.changes {
                if c.entity == "strength_session" && pending.contains(c.id) { continue }
                if c.op == "delete" || c.data == nil {
                    try db.execute(sql: "DELETE FROM record WHERE entity = ? AND id = ?", arguments: [c.entity, c.id])
                    continue
                }
                let data = c.data!
                try db.execute(
                    sql: """
                    INSERT INTO record (entity, id, version, date, data) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT (entity, id) DO UPDATE SET version = excluded.version, date = excluded.date, data = excluded.data
                    """,
                    arguments: [c.entity, c.id, c.version, Self.date(of: c), try encoder.encode(data)]
                )
            }
            try Self.set(db, "cursor", page.cursor)
            try Self.set(db, "lastSyncAt", String(now.timeIntervalSince1970))
            try Self.set(db, "lastError", nil)
        }
    }

    public func setWatchState(_ state: WatchState) throws {
        let json = String(decoding: try JSONEncoder().encode(state), as: UTF8.self)
        try db.write { db in try Self.set(db, "watch", json) }
    }

    public func watchState() throws -> WatchState? {
        try db.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'watch'")
                .flatMap { try? JSONDecoder().decode(WatchState.self, from: Data($0.utf8)) }
        }
    }

    /// Planned workouts from today to the delivery horizon (athlete's zone), each with a content
    /// digest and whether an activity matched it.
    public func deliveryCandidates(now: Date = Date()) throws -> (profile: Profile, today: LocalDate, candidates: [DeliveryCandidate]) {
        try db.read { db in
            let profile = try Self.decode(Profile.self, db, sql: "SELECT data FROM record WHERE entity = 'profile'", []).first ?? Profile()
            let today = LocalDate.today(in: profile.effectiveTimeZone(now: now), now: now)
            let from = today, to = today.adding(days: WatchDelivery.horizonDays)
            let done = Set(try Self.decode(Activity.self, db, sql: "SELECT data FROM record WHERE entity = 'activity' AND date BETWEEN ? AND ?", [from.iso, to.iso])
                .compactMap(\.plannedWorkoutId))
            let decoder = JSONDecoder()
            let rows = try Row.fetchAll(db, sql: "SELECT data, version FROM record WHERE entity = 'planned_workout' AND date BETWEEN ? AND ?", arguments: [from.iso, to.iso])
            let candidates = rows.compactMap { row -> DeliveryCandidate? in
                let data: Data = row["data"]
                guard let w = try? decoder.decode(PlannedWorkout.self, from: data) else { return nil }
                let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                return DeliveryCandidate(workout: w, digest: digest, done: done.contains(w.id), version: row["version"])
            }
            return (profile, today, candidates)
        }
    }

    public func recordError(_ message: String) throws {
        try db.write { db in try Self.set(db, "lastError", message) }
    }

    /// Full resync: forget the cursor (and data) so the next pull takes a snapshot.
    public func reset() throws {
        try db.write { db in
            try db.execute(sql: "DELETE FROM record")
            try Self.set(db, "cursor", nil)
        }
    }

    private static func date(of c: SyncChange) -> String? {
        switch c.entity {
        case "week": c.id
        case "event": c.data?["dateFrom"]?.string
        default: c.data?["date"]?.string
        }
    }

    private static func set(_ db: Database, _ key: String, _ value: String?) throws {
        try db.execute(
            sql: "INSERT INTO sync_state (key, value) VALUES (?, ?) ON CONFLICT (key) DO UPDATE SET value = excluded.value",
            arguments: [key, value]
        )
    }

    // MARK: Read

    public func cursor() throws -> String? {
        try db.read { db in try String.fetchOne(db, sql: "SELECT value FROM sync_state WHERE key = 'cursor'") }
    }

    public func status() throws -> SyncStatus {
        try db.read { db in try Self.status(db) }
    }

    static func status(_ db: Database) throws -> SyncStatus {
        let rows = try Row.fetchAll(db, sql: "SELECT key, value FROM sync_state")
        var s = SyncStatus()
        for r in rows {
            let key: String = r["key"]
            let value: String? = r["value"]
            switch key {
            case "cursor": s.cursor = value
            case "lastSyncAt": s.lastSyncAt = value.flatMap(Double.init).map(Date.init(timeIntervalSince1970:))
            case "lastError": s.lastError = value
            case "watch":
                if let w = value.flatMap({ try? JSONDecoder().decode(WatchState.self, from: Data($0.utf8)) }) {
                    s.onWatch = Set(w.onWatch)
                    s.watchAt = w.at
                    s.watchError = w.error
                }
            default: break
            }
        }
        s.records = try Int.fetchOne(db, sql: "SELECT count(*) FROM record") ?? 0
        s.outboxPending = try Int.fetchOne(db, sql: "SELECT count(*) FROM outbox") ?? 0
        s.outboxError = try String.fetchOne(db, sql: "SELECT lastError FROM outbox WHERE lastError IS NOT NULL ORDER BY nextAttemptAt DESC LIMIT 1")
        return s
    }

    static func decode<T: Decodable>(_ type: T.Type, _ db: Database, sql: String, _ args: StatementArguments) throws -> [T] {
        let decoder = JSONDecoder()
        return try Data.fetchAll(db, sql: sql, arguments: args).compactMap { try? decoder.decode(T.self, from: $0) }
    }

    /// Days in [from, to] with plan, activities (matched and not), journal and events.
    /// `today` follows the athlete's time zone from the stored profile.
    public static func snapshot(_ db: Database, from: LocalDate, to: LocalDate, now: Date = Date()) throws -> PlanSnapshot {
        let profile = try decode(Profile.self, db, sql: "SELECT data FROM record WHERE entity = 'profile'", []).first ?? Profile()
        let today = LocalDate.today(in: profile.effectiveTimeZone(now: now), now: now)
        let range: StatementArguments = [from.iso, to.iso]
        let workouts = try decode(PlannedWorkout.self, db, sql: "SELECT data FROM record WHERE entity = 'planned_workout' AND date BETWEEN ? AND ?", range)
        let activities = try decode(Activity.self, db, sql: "SELECT data FROM record WHERE entity = 'activity' AND date BETWEEN ? AND ?", range)
        let journal = try decode(JournalEntry.self, db, sql: "SELECT data FROM record WHERE entity = 'journal' AND date BETWEEN ? AND ?", range)
        let lifted = Set(try strengthSessions(db, sql: "SELECT data FROM record WHERE entity = 'strength_session' AND date BETWEEN ? AND ?", range)
            .filter { $0.doneCount > 0 }.compactMap(\.plannedWorkoutId))
        let events = try decode(PlanEvent.self, db, sql: "SELECT data FROM record WHERE entity = 'event'", [])
            .filter { $0.dateTo >= from && $0.dateFrom <= to && $0.status != "cancelled" }
        let weeks = try decode(Week.self, db, sql: "SELECT data FROM record WHERE entity = 'week' AND date BETWEEN ? AND ?", [from.weekStart.iso, to.iso])

        var days: [Day] = []
        var d = from
        while d <= to {
            let date = d
            let acts = activities.filter { $0.date == date }.sorted { ($0.startLocal ?? "") < ($1.startLocal ?? "") }
            let planned = workouts.filter { $0.date == date }.sorted { ($0.order, $0.title) < ($1.order, $1.title) }
                .map { w -> PlannedItem in
                    let mine = acts.filter { $0.plannedWorkoutId == w.id }
                    let status: WorkoutStatus = !mine.isEmpty || lifted.contains(w.id) ? .done : w.skipped != nil ? .skipped : date < today ? .missed : .planned
                    return PlannedItem(workout: w, activities: mine, status: status)
                }
            let matched = Set(planned.flatMap { $0.activities.map(\.id) })
            days.append(Day(
                date: date,
                planned: planned,
                unplanned: acts.filter { !matched.contains($0.id) },
                journal: journal.filter { $0.date == date },
                events: events.filter { $0.dateFrom <= date && date <= $0.dateTo && $0.datePrecision == "day" }
            ))
            d = d.adding(days: 1)
        }
        return PlanSnapshot(
            profile: profile,
            today: today,
            days: days,
            weeks: Dictionary(weeks.map { ($0.weekStart, $0) }, uniquingKeysWith: { a, _ in a }),
            status: try status(db)
        )
    }

    public func snapshot(from: LocalDate, to: LocalDate, now: Date = Date()) throws -> PlanSnapshot {
        try db.read { db in try Self.snapshot(db, from: from, to: to, now: now) }
    }

    /// Live snapshot: re-emits whenever a sync applies changes. Range is relative to today
    /// (in the athlete's zone), so it moves past midnight on the next change or app start.
    public func observe(pastDays: Int, futureDays: Int) -> AsyncValueObservation<PlanSnapshot> {
        ValueObservation.tracking { db in
            let profile = try Self.decode(Profile.self, db, sql: "SELECT data FROM record WHERE entity = 'profile'", []).first ?? Profile()
            let today = LocalDate.today(in: profile.effectiveTimeZone())
            return try Self.snapshot(db, from: today.adding(days: -pastDays), to: today.adding(days: futureDays))
        }
        .removeDuplicates()
        .values(in: db)
    }

    /// Upcoming confirmed events (countdown on Today).
    public func observeEvents() -> AsyncValueObservation<[PlanEvent]> {
        ValueObservation.tracking { db in
            try Self.decode(PlanEvent.self, db, sql: "SELECT data FROM record WHERE entity = 'event' ORDER BY date", [])
        }
        .removeDuplicates()
        .values(in: db)
    }

    /// Recent activities, newest first (Activities tab).
    public func observeActivities(limit: Int = 200) -> AsyncValueObservation<[Activity]> {
        ValueObservation.tracking { db in
            try Self.decode(Activity.self, db, sql: "SELECT data FROM record WHERE entity = 'activity' ORDER BY date DESC, id LIMIT ?", [limit])
                .sorted { ($0.date, $0.startLocal ?? "") > ($1.date, $1.startLocal ?? "") }
        }
        .removeDuplicates()
        .values(in: db)
    }

    public func activity(id: String) throws -> Activity? {
        try db.read { db in
            try Self.decode(Activity.self, db, sql: "SELECT data FROM record WHERE entity = 'activity' AND id = ?", [id]).first
        }
    }

    public func observeStatus() -> AsyncValueObservation<SyncStatus> {
        ValueObservation.tracking { db in try Self.status(db) }.removeDuplicates().values(in: db)
    }
}
