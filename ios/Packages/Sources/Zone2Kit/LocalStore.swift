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
}

public struct SyncStatus: Sendable, Equatable {
    public var cursor: String?
    public var lastSyncAt: Date?
    public var lastError: String?
    public var records: Int = 0
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
        return try LocalStore(path: dir.appending(path: "zone2.sqlite").path())
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
        return m
    }

    // MARK: Write

    /// Applies one feed page in a single transaction. A snapshot page replaces everything.
    public func apply(_ page: SyncPage, at now: Date = Date()) throws {
        let encoder = JSONEncoder()
        try db.write { db in
            if page.snapshot { try db.execute(sql: "DELETE FROM record") }
            for c in page.changes {
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
            default: break
            }
        }
        s.records = try Int.fetchOne(db, sql: "SELECT count(*) FROM record") ?? 0
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
                    let a = acts.first { $0.plannedWorkoutId == w.id }
                    let status: WorkoutStatus = a != nil ? .done : w.skipped != nil ? .skipped : date < today ? .missed : .planned
                    return PlannedItem(workout: w, activity: a, status: status)
                }
            let matched = Set(planned.compactMap { $0.activity?.id })
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
