import SwiftUI
import Zone2Kit

/// Profile of a workout: bar width = length, height and colour = zone of the step's target
/// against the athlete's zones (by step kind when there is no usable target) (principle 3).
struct StructureBar: View {
    let structure: EnduranceStructure
    let sport: Sport
    var height: CGFloat = 28
    /// Time marks under the bars (workout screen).
    var showsAxis = false
    @Environment(\.athleteProfile) private var profile

    struct Segment: Identifiable {
        let id: Int
        let seconds: Double
        let zone: Int
    }

    static func segments(_ structure: EnduranceStructure, sport: Sport, profile: Profile) -> [Segment] {
        var out: [Segment] = []
        func add(_ s: Step) {
            out.append(Segment(id: out.count, seconds: Formats.estimatedSeconds(s, sport: sport),
                               zone: Intensity.zone(of: s, sport: sport, profile: profile)))
        }
        for node in structure.steps {
            switch node {
            case .step(let s): add(s)
            case .repeats(_, let count, let steps):
                for _ in 0..<count { steps.forEach(add) }
            }
        }
        return out
    }

    static func barHeight(_ zone: Int, _ height: CGFloat) -> CGFloat { height * (0.3 + 0.7 * CGFloat(zone) / 5) }

    var body: some View {
        let segs = Self.segments(structure, sport: sport, profile: profile)
        let total = max(segs.reduce(0) { $0 + $1.seconds }, 1)
        VStack(spacing: 6) {
            GeometryReader { geo in
                let gap: CGFloat = segs.count > 60 ? 0.5 : segs.count > 24 ? 1 : 2
                let usable = max(geo.size.width - gap * CGFloat(max(segs.count - 1, 0)), 1)
                ZStack(alignment: .bottom) {
                    // Zone levels as hairlines: the height of a bar reads as intensity.
                    if height >= 32 {
                        ForEach(1...5, id: \.self) { z in
                            Rectangle()
                                .fill(Color.secondary.opacity(0.14))
                                .frame(height: 0.5)
                                .offset(y: -Self.barHeight(z, height) + 0.5)
                        }
                    }
                    HStack(alignment: .bottom, spacing: gap) {
                        ForEach(segs) { s in
                            UnevenRoundedRectangle(topLeadingRadius: Radius.bar, bottomLeadingRadius: 1,
                                                   bottomTrailingRadius: 1, topTrailingRadius: Radius.bar, style: .continuous)
                                .fill(Color.zone(s.zone).gradient)
                                .frame(width: max(usable * s.seconds / total, 1.5), height: Self.barHeight(s.zone, height))
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .bottom)
            }
            .frame(height: height)
            if showsAxis {
                HStack {
                    Text(verbatim: "0")
                    Spacer()
                    Text(Formats.clock(total / 2))
                    Spacer()
                    Text(Formats.clock(total))
                }
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            }
        }
        .accessibilityHidden(true)
    }
}

/// What a plan adds up to: time, distance when every step is measured in metres, and the target
/// of the longest work (what the watch will show most of the time).
struct PlanEstimate {
    let seconds: Double
    let distanceM: Double?
    let mainTarget: Target?

    init(_ structure: EnduranceStructure, sport: Sport) {
        var sec = 0.0, dist = 0.0, allDistance = true
        var work: [(Double, Target)] = []
        func add(_ s: Step, times: Int) {
            let t = Formats.estimatedSeconds(s, sport: sport) * Double(times)
            sec += t
            if case .distance(let m) = s.duration { dist += m * Double(times) } else { allDistance = false }
            if s.kind == .work || s.kind == .drill, let target = s.target, target.unresolved == nil {
                work.append((t, target))
            }
        }
        for node in structure.steps {
            switch node {
            case .step(let s): add(s, times: 1)
            case .repeats(_, let count, let steps): steps.forEach { add($0, times: count) }
            }
        }
        seconds = sec
        distanceM = allDistance && dist > 0 ? dist : nil
        mainTarget = work.max { $0.0 < $1.0 }?.1
            ?? structure.steps.lazy.compactMap { node -> Target? in
                if case .step(let s) = node { return s.target } else { return nil }
            }.first { $0.unresolved == nil }
    }
}

/// One-line summary: "15 min · 3 × (1 km 4:50–5:00 /km + open) · 10 min".
func structureSummary(_ structure: EnduranceStructure, sport: Sport) -> String {
    func step(_ s: Step, withTarget: Bool) -> String {
        // Open steps (until Lap) read as their kind: "… · Cool-down".
        var parts: [String] = [Formats.duration(s.duration) ?? (s.label ?? s.kind.title)]
        if withTarget, let t = s.target, t.unresolved == nil { parts.append(Formats.target(t, sport: sport)) }
        return parts.joined(separator: " ")
    }
    return structure.steps.map { node in
        switch node {
        case .step(let s): step(s, withTarget: s.kind == .work)
        case .repeats(_, let count, let steps):
            "\(count) × (" + steps.map { step($0, withTarget: $0.kind == .work) }.joined(separator: " + ") + ")"
        }
    }.joined(separator: " · ")
}

/// Step list with repeats collapsed into a group (planned workout screen), for a card.
struct StepList: View {
    let structure: EnduranceStructure
    let sport: Sport

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(structure.steps.enumerated()), id: \.element.id) { i, node in
                if i > 0 { Divider().padding(.leading, 14) }
                switch node {
                case .step(let s):
                    StepRow(step: s, sport: sport).padding(.vertical, Space.m)
                case .repeats(_, let count, let steps):
                    VStack(alignment: .leading, spacing: Space.s) {
                        HStack(spacing: 6) {
                            Image(systemName: "repeat").font(.caption.weight(.bold))
                            Text(verbatim: "\(count) ×").font(.subheadline.weight(.bold).monospacedDigit())
                        }
                        .foregroundStyle(Color.brand)
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(steps.enumerated()), id: \.element.id) { j, s in
                                if j > 0 { Divider().padding(.leading, 14) }
                                StepRow(step: s, sport: sport).padding(.vertical, Space.s)
                            }
                        }
                        .padding(.horizontal, Space.m)
                        .background(Color.brand.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    }
                    .padding(.vertical, Space.m)
                }
            }
        }
    }
}

struct StepRow: View {
    let step: Step
    let sport: Sport
    @Environment(\.athleteProfile) private var profile

    var body: some View {
        let zone = Intensity.zone(of: step, sport: sport, profile: profile)
        HStack(alignment: .top, spacing: Space.m) {
            Capsule()
                .fill(Color.zone(zone).gradient)
                .frame(width: 4)
                .frame(minHeight: 22, maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.label ?? step.kind.title).font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                    Text(Formats.duration(step.duration) ?? L("until lap"))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                }
                if let t = step.target {
                    if let why = t.unresolved {
                        Text(why).font(.caption).foregroundStyle(.orange)
                    } else {
                        Text(Formats.target(t, sport: sport)).font(.title3.weight(.semibold).monospacedDigit())
                    }
                }
                ForEach(Array((step.secondary ?? []).enumerated()), id: \.offset) { _, t in
                    Text(Formats.target(t, sport: sport)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if let note = step.note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Strength exercises: "Присед · 3 × 8 · 60 kg".
struct StrengthList: View {
    let structure: StrengthStructure

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(structure.items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Divider() }
                Group {
                    if let e = item.exercise {
                        ExerciseRow(exercise: e, sets: item.sets, setList: item.setList)
                    } else if let items = item.items {
                        VStack(alignment: .leading, spacing: Space.s) {
                            HStack(spacing: 6) {
                                Image(systemName: "repeat").font(.caption.weight(.bold))
                                Text(verbatim: "\(item.rounds ?? 1) ×").font(.subheadline.weight(.bold).monospacedDigit())
                            }
                            .foregroundStyle(Color.brand)
                            ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                                ExerciseRow(exercise: e, sets: nil, setList: nil).padding(.leading, Space.m)
                            }
                        }
                    }
                }
                .padding(.vertical, Space.m)
            }
        }
    }
}

struct ExerciseRow: View {
    let exercise: StrengthItem.Exercise
    let sets: Int?
    let setList: [StrengthItem.SetSpec]?

    private func load(reps: Int?, kg: Double?, hold: Int?) -> String {
        var parts: [String] = []
        if let reps { parts.append("\(reps)") }
        if let hold { parts.append(Formats.stepTime(hold)) }
        var s = parts.joined()
        if let kg { s += " · " + L("\(kg.formatted()) kg") }
        return s
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(exercise.exercise).font(.body.weight(.semibold))
            Group {
                if let setList {
                    Text(setList.map { load(reps: $0.reps, kg: $0.weightKg, hold: $0.holdSec) }.joined(separator: " / "))
                } else {
                    Text("\(sets ?? 1) × " + load(reps: exercise.reps, kg: exercise.weightKg, hold: exercise.holdSec)
                        + (exercise.perSide == true ? " " + L("per side") : ""))
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
            if let note = exercise.note {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}
