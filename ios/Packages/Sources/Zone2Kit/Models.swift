import Foundation

// Read models for what the sync feed delivers (docs/03-data-model.md). All lenient: optional
// fields, unknown values tolerated — the server owns validation, the app only displays.

public enum Sport: String, Codable, Sendable, CaseIterable {
    case run, bike, swim, strength, other

    public init(from decoder: Decoder) throws {
        self = Sport(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .other
    }
}

public struct Profile: Decodable, Sendable, Equatable {
    public struct Travel: Decodable, Sendable, Equatable {
        public let from: LocalDate
        public let to: LocalDate
        public let timezone: String
    }

    public var timezone: String = "UTC"
    public var travel: [Travel] = []

    public init() {}

    enum CodingKeys: String, CodingKey { case timezone, travel }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        timezone = (try? c.decode(String.self, forKey: .timezone)) ?? "UTC"
        travel = (try? c.decode([Travel].self, forKey: .travel)) ?? []
    }

    /// Zone the plan's dates are in right now: home, or a travel period covering home's today.
    public func effectiveTimeZone(now: Date = Date()) -> TimeZone {
        let home = TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
        return timeZone(on: LocalDate.today(in: home, now: now))
    }

    /// Zone of a plan date: a travel period covering it, else home.
    public func timeZone(on date: LocalDate) -> TimeZone {
        if let t = travel.first(where: { $0.from <= date && date <= $0.to }),
           let tz = TimeZone(identifier: t.timezone) {
            return tz
        }
        return TimeZone(identifier: timezone) ?? TimeZone(identifier: "UTC")!
    }
}

// MARK: - Structure

public struct Target: Codable, Sendable, Equatable {
    public enum Metric: String, Codable, Sendable { case hr, pace, power, speed, cadence, rpe }
    public let metric: Metric
    public let low: Double?
    public let high: Double?
    public let unit: String?
    /// Set when a %-target could not be resolved on the server (no threshold in the profile).
    public let unresolved: String?
}

public enum StepDuration: Codable, Sendable, Equatable {
    case time(sec: Int)
    case distance(m: Double)
    case open(estimateSec: Int?)

    enum CodingKeys: String, CodingKey { case type, sec, m, estimateSec }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "time": self = .time(sec: try c.decode(Int.self, forKey: .sec))
        case "distance": self = .distance(m: try c.decode(Double.self, forKey: .m))
        default: self = .open(estimateSec: try c.decodeIfPresent(Int.self, forKey: .estimateSec))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .time(let sec): try c.encode("time", forKey: .type); try c.encode(sec, forKey: .sec)
        case .distance(let m): try c.encode("distance", forKey: .type); try c.encode(m, forKey: .m)
        case .open(let e): try c.encode("open", forKey: .type); try c.encodeIfPresent(e, forKey: .estimateSec)
        }
    }
}

public struct Step: Codable, Sendable, Equatable, Identifiable {
    public enum Kind: String, Codable, Sendable { case warmup, work, recovery, rest, cooldown, drill }
    public let id: String
    public let kind: Kind
    public let label: String?
    public let duration: StepDuration
    public let target: Target?
    public let secondary: [Target]?
    public let note: String?
}

public enum StructureNode: Decodable, Sendable, Equatable, Identifiable {
    case step(Step)
    case repeats(id: String, count: Int, steps: [Step])

    public var id: String {
        switch self {
        case .step(let s): s.id
        case .repeats(let id, _, _): id
        }
    }

    enum CodingKeys: String, CodingKey { case type, id, count, steps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if try c.decode(String.self, forKey: .type) == "repeat" {
            self = .repeats(
                id: try c.decode(String.self, forKey: .id),
                count: try c.decode(Int.self, forKey: .count),
                steps: try c.decode([Step].self, forKey: .steps)
            )
        } else {
            self = .step(try Step(from: decoder))
        }
    }
}

public struct EnduranceStructure: Decodable, Sendable, Equatable {
    public let poolLengthM: Double?
    public let steps: [StructureNode]
}

public struct StrengthItem: Decodable, Sendable, Equatable, Identifiable {
    public struct SetSpec: Decodable, Sendable, Equatable {
        public let reps: Int?
        public let weightKg: Double?
        public let holdSec: Int?
        public let rpe: Double?
    }

    public struct Exercise: Decodable, Sendable, Equatable {
        public let exercise: String
        public let reps: Int?
        public let weightKg: Double?
        public let rpe: Double?
        public let holdSec: Int?
        public let perSide: Bool?
        public let note: String?
    }

    public let id: String
    public let type: String
    /// exercise: one movement; superset: `items` done in rounds.
    public let exercise: Exercise?
    public let sets: Int?
    public let setList: [SetSpec]?
    public let rounds: Int?
    public let items: [Exercise]?

    enum CodingKeys: String, CodingKey { case id, type, sets, setList, rounds, items }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = try c.decode(String.self, forKey: .type)
        sets = try c.decodeIfPresent(Int.self, forKey: .sets)
        setList = try c.decodeIfPresent([SetSpec].self, forKey: .setList)
        rounds = try c.decodeIfPresent(Int.self, forKey: .rounds)
        items = try c.decodeIfPresent([Exercise].self, forKey: .items)
        exercise = type == "exercise" ? try Exercise(from: decoder) : nil
    }
}

public struct StrengthStructure: Decodable, Sendable, Equatable {
    public let items: [StrengthItem]
}

// MARK: - Plan

public struct PlannedWorkout: Decodable, Sendable, Equatable, Identifiable {
    public struct Skipped: Decodable, Sendable, Equatable { public let reason: String }

    public let id: String
    public let date: LocalDate
    public let order: Int
    public let sport: Sport
    public let subSport: String?
    public let title: String
    public let goal: String?
    public let notes: String?
    public let key: Bool
    public let execution: String
    public let skipped: Skipped?
    /// Endurance structure with targets resolved to absolute units by the server.
    public let resolved: EnduranceStructure?
    public let strength: StrengthStructure?

    enum CodingKeys: String, CodingKey {
        case id, date, order, sport, subSport, title, goal, notes, key, execution, skipped, resolved, structure
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(LocalDate.self, forKey: .date)
        order = (try? c.decode(Int.self, forKey: .order)) ?? 0
        sport = try c.decode(Sport.self, forKey: .sport)
        subSport = try c.decodeIfPresent(String.self, forKey: .subSport)
        title = try c.decode(String.self, forKey: .title)
        goal = try c.decodeIfPresent(String.self, forKey: .goal)
        notes = try c.decodeIfPresent(String.self, forKey: .notes)
        key = (try? c.decode(Bool.self, forKey: .key)) ?? false
        execution = (try? c.decode(String.self, forKey: .execution)) ?? "none"
        skipped = try? c.decodeIfPresent(Skipped.self, forKey: .skipped)
        resolved = try? c.decodeIfPresent(EnduranceStructure.self, forKey: .resolved)
        strength = sport == .strength ? try? c.decodeIfPresent(StrengthStructure.self, forKey: .structure) : nil
    }
}

public struct Week: Decodable, Sendable, Equatable {
    public let weekStart: LocalDate
    public let title: String?
    public let header: String?
    public let review: String?
}

public struct PlanEvent: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    public let sport: String
    public let status: String
    public let datePrecision: String
    public let dateFrom: LocalDate
    public let dateTo: LocalDate
    public let dateText: String?
    public let distanceM: Double?
    public let priority: String?
    public let goal: String?

    /// Shown with a countdown only when the date is exact and the start is really on.
    public var isConfirmed: Bool {
        datePrecision == "day" && (status == "planned" || status == "registered")
    }
}

public struct JournalEntry: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let date: LocalDate
    public let text: String
    public let tags: [String]?
    public let due: LocalDate?
    public let closedAt: String?
}

// MARK: - Activities

public struct Lap: Decodable, Sendable, Equatable {
    public let kind: String?
    public let startSec: Double
    public let durationSec: Double
    public let distanceM: Double?
    public let movingSec: Double?
    public let avgHr: Double?
    public let maxHr: Double?
    public let paceSecPerKm: Double?
    public let speedKmh: Double?
    public let powerAvg: Double?
    public let cadence: Double?
}

public struct ActivitySummary: Decodable, Sendable, Equatable {
    public struct HR: Decodable, Sendable, Equatable { public let avg: Double?; public let max: Double? }
    public struct Weather: Decodable, Sendable, Equatable { public let tempC: Double?; public let humidityPct: Double? }
    public struct Running: Decodable, Sendable, Equatable {
        public let powerAvg: Double?
        public let cadenceSpm: Double?
        public let strideLengthM: Double?
        public let verticalOscillationCm: Double?
        public let groundContactMs: Double?
    }
    public struct Cycling: Decodable, Sendable, Equatable {
        public let powerAvg: Double?
        public let powerMax: Double?
        public let cadenceAvg: Double?
    }
    public struct Swim: Decodable, Sendable, Equatable {
        public let poolLengthM: Double?
        public let lengths: Int?
        public let strokes: Int?
    }

    public let kind: String?
    public let elapsedSec: Double?
    public let movingSec: Double?
    public let distanceM: Double?
    public let distanceKind: String?
    public let paceSecPerKm: Double?
    public let paceSecPer100m: Double?
    public let speedKmh: Double?
    public let hr: HR?
    public let elevationGainM: Double?
    public let energyKcal: Double?
    public let weather: Weather?
    public let detail: String?
    public let running: Running?
    public let cycling: Cycling?
    public let swim: Swim?
    /// The athlete's manual intervals (markers during the workout); the real effort when set.
    public let intervals: [Lap]?
}

public struct Activity: Decodable, Sendable, Equatable, Identifiable {
    public let id: String
    public let date: LocalDate
    public let startLocal: String?
    public let sport: Sport
    public let subSport: String?
    public let kind: String?
    public let title: String?
    public let plannedWorkoutId: String?
    public let source: String?
    public let device: String?
    public let summary: ActivitySummary
    public let laps: [Lap]
    public let athleteNotes: String?
    public let coachNotes: String?
    public let rpe: Double?

    enum CodingKeys: String, CodingKey {
        case id, date, startLocal, sport, subSport, kind, title, plannedWorkoutId, source, device,
             summary, laps, athleteNotes, coachNotes, rpe
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        date = try c.decode(LocalDate.self, forKey: .date)
        startLocal = try c.decodeIfPresent(String.self, forKey: .startLocal)
        sport = try c.decode(Sport.self, forKey: .sport)
        subSport = try c.decodeIfPresent(String.self, forKey: .subSport)
        kind = try c.decodeIfPresent(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        plannedWorkoutId = try c.decodeIfPresent(String.self, forKey: .plannedWorkoutId)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        device = try c.decodeIfPresent(String.self, forKey: .device)
        summary = try c.decode(ActivitySummary.self, forKey: .summary)
        laps = (try? c.decode([Lap].self, forKey: .laps)) ?? []
        athleteNotes = try c.decodeIfPresent(String.self, forKey: .athleteNotes)
        coachNotes = try c.decodeIfPresent(String.self, forKey: .coachNotes)
        rpe = try c.decodeIfPresent(Double.self, forKey: .rpe)
    }

    public var isRecovery: Bool { kind == "recovery" }
}

// MARK: - Days

public enum WorkoutStatus: String, Sendable {
    case planned, done, skipped, missed
}

public struct PlannedItem: Sendable, Equatable, Identifiable {
    public let workout: PlannedWorkout
    public let activity: Activity?
    public let status: WorkoutStatus
    public var id: String { workout.id }

    public init(workout: PlannedWorkout, activity: Activity?, status: WorkoutStatus) {
        self.workout = workout
        self.activity = activity
        self.status = status
    }
}

public struct Day: Sendable, Equatable, Identifiable {
    public let date: LocalDate
    public var planned: [PlannedItem]
    /// Activities not matched to any planned workout of the day.
    public var unplanned: [Activity]
    public var journal: [JournalEntry]
    public var events: [PlanEvent]
    public var id: String { date.iso }
    public var isEmpty: Bool { planned.isEmpty && unplanned.isEmpty && journal.isEmpty && events.isEmpty }
}
