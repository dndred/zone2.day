import SwiftUI
import Zone2Kit

/// Profile of a workout: bar width = length, height = intensity by step kind (principle 3).
struct StructureBar: View {
    let structure: EnduranceStructure
    let sport: Sport
    var height: CGFloat = 28

    private struct Segment: Identifiable {
        let id: Int
        let seconds: Double
        let kind: Step.Kind
    }

    private var segments: [Segment] {
        var out: [Segment] = []
        for node in structure.steps {
            switch node {
            case .step(let s):
                out.append(Segment(id: out.count, seconds: Formats.estimatedSeconds(s, sport: sport), kind: s.kind))
            case .repeats(_, let count, let steps):
                for _ in 0..<count {
                    for s in steps {
                        out.append(Segment(id: out.count, seconds: Formats.estimatedSeconds(s, sport: sport), kind: s.kind))
                    }
                }
            }
        }
        return out
    }

    var body: some View {
        let segs = segments
        let total = max(segs.reduce(0) { $0 + $1.seconds }, 1)
        GeometryReader { geo in
            let gap: CGFloat = segs.count > 60 ? 0.5 : 1.5
            let usable = max(geo.size.width - gap * CGFloat(max(segs.count - 1, 0)), 1)
            HStack(alignment: .bottom, spacing: gap) {
                ForEach(segs) { s in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(s.kind == .work || s.kind == .drill ? sport.color : sport.color.opacity(0.35))
                        .frame(width: max(usable * s.seconds / total, 1.5), height: height * s.kind.intensity)
                }
            }
            .frame(maxHeight: .infinity, alignment: .bottom)
        }
        .frame(height: height)
        .accessibilityHidden(true)
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

/// Step list with repeats collapsed into a group (planned workout screen).
struct StepList: View {
    let structure: EnduranceStructure
    let sport: Sport

    var body: some View {
        ForEach(structure.steps) { node in
            switch node {
            case .step(let s):
                StepRow(step: s, sport: sport)
            case .repeats(_, let count, let steps):
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(count) ×").font(.headline.monospacedDigit())
                    ForEach(steps) { s in StepRow(step: s, sport: sport).padding(.leading, 12) }
                }
                .padding(.vertical, 2)
            }
        }
    }
}

struct StepRow: View {
    let step: Step
    let sport: Sport

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            RoundedRectangle(cornerRadius: 2)
                .fill(step.kind == .work || step.kind == .drill ? sport.color : sport.color.opacity(0.35))
                .frame(width: 4, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(step.label ?? step.kind.title).font(.subheadline)
                    Spacer()
                    Text(Formats.duration(step.duration) ?? L("until lap"))
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
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
    }
}

/// Strength exercises: "Присед · 3 × 8 · 60 kg".
struct StrengthList: View {
    let structure: StrengthStructure

    var body: some View {
        ForEach(structure.items) { item in
            if let e = item.exercise {
                ExerciseRow(exercise: e, sets: item.sets, setList: item.setList)
            } else if let items = item.items {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(item.rounds ?? 1) ×").font(.headline.monospacedDigit())
                    ForEach(Array(items.enumerated()), id: \.offset) { _, e in
                        ExerciseRow(exercise: e, sets: nil, setList: nil).padding(.leading, 12)
                    }
                }
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
            Text(exercise.exercise).font(.subheadline.weight(.medium))
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
