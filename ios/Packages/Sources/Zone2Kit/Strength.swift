import Foundation

// Gym log (docs/07-ios-app.md §3.5): sets prefilled from the plan, tap = done as planned,
// edits are written locally at once and sent through the outbox as a session snapshot.

public struct Load: Codable, Sendable, Equatable, Hashable {
    public var reps: Int?
    public var weightKg: Double?
    public var holdSec: Int?
    public var distanceM: Double?

    public init(reps: Int? = nil, weightKg: Double? = nil, holdSec: Int? = nil, distanceM: Double? = nil) {
        self.reps = reps
        self.weightKg = weightKg
        self.holdSec = holdSec
        self.distanceM = distanceM
    }

    /// "60 kg × 8", "× 12", "45 s".
    public func formatted(units u: Units = .current) -> String {
        var parts: [String] = []
        if let w = weightKg, w > 0 { parts.append("\(w.formatted()) \(u.kg)") }
        if let r = reps { parts.append("\(r)") }
        var out = parts.joined(separator: " × ")
        if let h = holdSec { out += (out.isEmpty ? "" : " × ") + Formats.stepTime(h, units: u) }
        if let d = distanceM { out += (out.isEmpty ? "" : " × ") + "\(Int(d)) \(u.m)" }
        if parts.count == 1 && reps != nil && weightKg == nil { out = "× \(reps!)" }
        return out.isEmpty ? "✓" : out
    }
}

public struct StrengthSet: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var exercise: String
    public var order: Int
    public var setIndex: Int
    public var planned: Load?
    /// nil = not done yet.
    public var actual: Load?
    public var rpe: Double?
    public var note: String?
    public var loggedAt: String?

    public var done: Bool { actual != nil }
}

public struct StrengthSession: Codable, Sendable, Equatable, Identifiable {
    public let id: String
    public var plannedWorkoutId: String?
    public var date: LocalDate
    public var notes: String?
    public var sets: [StrengthSet]

    enum CodingKeys: String, CodingKey { case id, plannedWorkoutId, date, notes, sets }

    public init(id: String, plannedWorkoutId: String?, date: LocalDate, notes: String?, sets: [StrengthSet]) {
        self.id = id
        self.plannedWorkoutId = plannedWorkoutId
        self.date = date
        self.notes = notes
        self.sets = sets
    }

    public var doneCount: Int { sets.filter(\.done).count }

    /// Exercises in order with their sets.
    public var exercises: [(name: String, sets: [StrengthSet])] {
        var order: [String] = []
        var groups: [String: [StrengthSet]] = [:]
        for s in sets.sorted(by: { ($0.order, $0.setIndex) < ($1.order, $1.setIndex) }) {
            if groups[s.exercise] == nil { order.append(s.exercise) }
            groups[s.exercise, default: []].append(s)
        }
        return order.map { ($0, groups[$0]!) }
    }

    /// Draft from a planned strength workout: every planned set, nothing done yet.
    public static func draft(from w: PlannedWorkout, newId: () -> String = { UUID().uuidString.lowercased() }) -> StrengthSession {
        var sets: [StrengthSet] = []
        var order = 0
        for item in w.strength?.items ?? [] {
            if let e = item.exercise {
                let specs: [Load] = item.setList?.map { Load(reps: $0.reps, weightKg: $0.weightKg, holdSec: $0.holdSec) }
                    ?? Array(repeating: Load(reps: e.reps, weightKg: e.weightKg, holdSec: e.holdSec), count: item.sets ?? 1)
                for (i, l) in specs.enumerated() {
                    sets.append(StrengthSet(id: newId(), exercise: e.exercise, order: order, setIndex: i, planned: l))
                }
                order += 1
            } else if let items = item.items {
                // Superset: each movement keeps its own order; rounds are set indices.
                for e in items {
                    for round in 0..<(item.rounds ?? 1) {
                        sets.append(StrengthSet(id: newId(), exercise: e.exercise, order: order, setIndex: round,
                                                planned: Load(reps: e.reps, weightKg: e.weightKg, holdSec: e.holdSec)))
                    }
                    order += 1
                }
            }
        }
        return StrengthSession(id: newId(), plannedWorkoutId: w.id, date: w.date, notes: nil, sets: sets)
    }

    // MARK: Edits

    /// Tap: done as planned (or as the previous done set when nothing is planned); tap again: undo.
    public mutating func toggle(_ setId: String, at now: Date = Date()) {
        guard let i = sets.firstIndex(where: { $0.id == setId }) else { return }
        if sets[i].done {
            sets[i].actual = nil
        } else {
            let previous = sets.filter { $0.exercise == sets[i].exercise && $0.setIndex < sets[i].setIndex && $0.done }
                .max { $0.setIndex < $1.setIndex }?.actual
            sets[i].actual = sets[i].planned ?? previous ?? Load(reps: 0)
        }
        sets[i].loggedAt = ISO8601DateFormatter().string(from: now)
    }

    public mutating func setActual(_ setId: String, _ load: Load, at now: Date = Date()) {
        guard let i = sets.firstIndex(where: { $0.id == setId }) else { return }
        sets[i].actual = load
        sets[i].loggedAt = ISO8601DateFormatter().string(from: now)
    }

    /// One more set of an exercise, like the last one.
    public mutating func addSet(to exercise: String, newId: String = UUID().uuidString.lowercased()) {
        let mine = sets.filter { $0.exercise == exercise }
        guard let last = mine.max(by: { $0.setIndex < $1.setIndex }) else { return }
        sets.append(StrengthSet(id: newId, exercise: exercise, order: last.order, setIndex: last.setIndex + 1,
                                planned: nil, actual: nil))
        // Prefill from the last set so a tap marks it done with the same load.
        if let i = sets.firstIndex(where: { $0.id == newId }) { sets[i].planned = last.actual ?? last.planned }
    }

    public mutating func setNote(_ exercise: String, _ note: String?) {
        guard let i = sets.firstIndex(where: { $0.exercise == exercise && $0.setIndex == 0 }) else { return }
        sets[i].note = note?.isEmpty == true ? nil : note
    }
}
