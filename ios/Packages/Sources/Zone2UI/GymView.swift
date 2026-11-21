import SwiftUI
import Zone2Kit

/// Gym mode (docs/07-ios-app.md §3.5): a card per exercise, the current one open, done ones folded
/// to a line, next ones compact. Sets are prefilled from the plan; tap = done as planned, long
/// press = edit weight/reps. The athlete's note sits inline in the card. Every change is saved
/// locally and queued for the server, so it works offline. Screen stays on. No timers.
public struct GymView: View {
    @Environment(\.planContext) private var context
    @Environment(\.dismiss) private var dismiss
    let workout: PlannedWorkout
    @State private var session: StrengthSession?
    @State private var draft: StrengthSession
    @State private var editing: StrengthSet?
    /// Exercises the athlete opened or folded by hand (overrides the automatic "current" one).
    @State private var opened: [String: Bool] = [:]
    @State private var confirmFinish = false

    public init(workout: PlannedWorkout) {
        self.workout = workout
        _draft = State(initialValue: StrengthSession.draft(from: workout))
    }

    private var current: StrengthSession { session ?? draft }

    /// The coach's note for an exercise, from the plan.
    private func coachNote(_ name: String) -> String? {
        for item in workout.strength?.items ?? [] {
            if let e = item.exercise, e.exercise == name { return e.note }
            if let e = item.items?.first(where: { $0.exercise == name }) { return e.note }
        }
        return nil
    }

    public var body: some View {
        let s = current
        let exercises = s.exercises
        // The first exercise with a set left is the one in progress.
        let active = exercises.first { ex in ex.sets.contains { !$0.done } }?.name
        ScrollView {
            VStack(alignment: .leading, spacing: Space.m) {
                header(s)
                ForEach(Array(exercises.enumerated()), id: \.element.name) { i, ex in
                    let done = ex.sets.allSatisfy(\.done)
                    let isOpen = opened[ex.name] ?? (ex.name == active)
                    ExerciseCard(index: i + 1, name: ex.name, sets: ex.sets, coachNote: coachNote(ex.name),
                                 isOpen: isOpen, isDone: done, isActive: ex.name == active,
                                 toggleOpen: { withAnimation(.snappy) { opened[ex.name] = !isOpen } },
                                 tapSet: { set in update { $0.toggle(set.id) } },
                                 editSet: { editing = $0 },
                                 addSet: { update { $0.addSet(to: ex.name) } },
                                 saveNote: { note in update { $0.setNote(ex.name, note) } })
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
            .animation(.snappy, value: s.doneCount)
        }
        .background(Color.groupedBackground)
        .scrollDismissesKeyboard(.interactively)
        // Appears with the first set done: before that there is nothing to finish.
        .safeAreaInset(edge: .bottom) { if s.doneCount > 0 { finishBar(s).transition(.move(edge: .bottom).combined(with: .opacity)) } }
        .navigationTitle(L("Gym"))
        .inlineTitle()
        .sensoryFeedback(.success, trigger: s.doneCount)
        .sheet(item: $editing) { set in
            SetEditor(set: set) { load in update { $0.setActual(set.id, load) } }
                .presentationDetents([.medium])
        }
        .confirmationDialog(L("Finish the workout?"), isPresented: $confirmFinish, titleVisibility: .visible) {
            Button(L("Finish")) { finish() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text("\(s.sets.count - s.doneCount) sets not marked. They stay not done.", bundle: .module)
        }
        .task {
            guard let context else { return }
            do {
                for try await saved in context.store.observeStrength(plannedWorkoutId: workout.id) {
                    session = saved
                }
            } catch {}
        }
        #if os(iOS)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        #endif
    }

    private func header(_ s: StrengthSession) -> some View {
        let tonnage = s.sets.compactMap { set -> Double? in
            guard let a = set.actual, let w = a.weightKg, let r = a.reps else { return nil }
            return w * Double(r)
        }.reduce(0, +)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.l) {
                ProgressRing(fraction: s.sets.isEmpty ? 0 : Double(s.doneCount) / Double(s.sets.count),
                             color: Sport.strength.color, lineWidth: 7) {
                    VStack(spacing: 0) {
                        Text(verbatim: "\(s.doneCount)").font(.title3.weight(.bold).monospacedDigit())
                        Text(verbatim: "/ \(s.sets.count)").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(Sport.strength.title, color: Sport.strength.color)
                    Text(workout.title).font(.title3.weight(.bold))
                    if tonnage > 0 {
                        Text("Volume \(Int(tonnage.rounded()).formatted()) \(Units.current.kg)", bundle: .module)
                            .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            .contentTransition(.numericText())
                    }
                }
            }
            if let goal = workout.goal {
                MarkdownText(goal, style: .compact).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .card()
    }

    private func finishBar(_ s: StrengthSession) -> some View {
        let all = !s.sets.isEmpty && s.doneCount == s.sets.count
        return Button {
            if all { finish() } else { confirmFinish = true }
        } label: {
            Label(L("Finish"), systemImage: all ? "checkmark.circle.fill" : "flag.checkered")
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .tint(Sport.strength.color)
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.s)
    }

    /// Sends the log now (offline: it stays queued) and leaves the gym.
    private func finish() {
        if let context { Task { await context.send() } }
        dismiss()
    }

    private func update(_ change: (inout StrengthSession) -> Void) {
        var s = current
        change(&s)
        session = s
        guard let context else { return }
        try? context.store.saveStrength(s)
        Task { await context.send() }
    }
}

/// One exercise: number, name, "2 / 4"; open: the coach's note, the sets, "add set", the
/// athlete's note; folded: what was done (or planned) in one line.
struct ExerciseCard: View {
    let index: Int
    let name: String
    let sets: [StrengthSet]
    let coachNote: String?
    let isOpen: Bool
    let isDone: Bool
    let isActive: Bool
    let toggleOpen: () -> Void
    let tapSet: (StrengthSet) -> Void
    let editSet: (StrengthSet) -> Void
    let addSet: () -> Void
    let saveNote: (String?) -> Void

    private var doneCount: Int { sets.filter(\.done).count }

    /// Runs of equal sets: "4 × 70 kg × 6", "2 × 70 kg × 6 · 75 kg × 6 · 70 kg × 6".
    private var summary: String {
        var runs: [(load: String, count: Int)] = []
        for set in sets {
            let l = (set.actual ?? set.planned)?.formatted() ?? "—"
            if runs.last?.load == l { runs[runs.count - 1].count += 1 } else { runs.append((l, 1)) }
        }
        return runs.map { $0.count > 1 ? "\($0.count) × \($0.load)" : $0.load }.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggleOpen) {
                HStack(spacing: Space.m) {
                    ZStack {
                        Circle().fill(isDone ? Sport.strength.color : isActive ? Sport.strength.color.opacity(0.15) : Color.secondary.opacity(0.12))
                        if isDone {
                            Image(systemName: "checkmark").font(.subheadline.weight(.bold)).foregroundStyle(.white)
                        } else {
                            Text(verbatim: "\(index)").font(.subheadline.weight(.bold).monospacedDigit())
                                .foregroundStyle(isActive ? Sport.strength.color : .secondary)
                        }
                    }
                    .frame(width: 32, height: 32)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.headline).multilineTextAlignment(.leading)
                        if !isOpen {
                            Text(summary).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    Text(verbatim: "\(doneCount) / \(sets.count)")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .foregroundStyle(isDone ? Sport.strength.color : .secondary)
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isOpen {
                if let coachNote {
                    Label { Text(coachNote) } icon: { Image(systemName: "text.bubble") }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.top, Space.m)
                }
                VStack(spacing: Space.s) {
                    ForEach(sets) { set in
                        // Long press wins over the tap (else a held finger marks the set done).
                        SetRow(set: set)
                            .highPriorityGesture(LongPressGesture(minimumDuration: 0.35).onEnded { _ in editSet(set) })
                            .onTapGesture { tapSet(set) }
                            .accessibilityAction(named: L("Edit")) { editSet(set) }
                    }
                }
                .padding(.top, Space.m)
                HStack {
                    Button(action: addSet) {
                        Label(L("Add set"), systemImage: "plus").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Sport.strength.color)
                    Spacer()
                }
                .padding(.top, Space.m)
                NoteField(note: sets.first?.note, save: saveNote)
                    .padding(.top, Space.m)
            }
        }
        .card()
        .overlay {
            if isActive {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Sport.strength.color.opacity(0.5), lineWidth: 1.5)
            }
        }
    }
}

/// The athlete's note to an exercise: one line in the card, saved on return or leaving the field.
struct NoteField: View {
    let note: String?
    let save: (String?) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: Space.s) {
            Image(systemName: "square.and.pencil").foregroundStyle(.secondary)
            TextField(L("Note: how it went, what to change"), text: $text, axis: .vertical)
                .font(.subheadline)
                .focused($focused)
                .submitLabel(.done)
                .onSubmit { commit() }
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .onAppear { text = note ?? "" }
        .onChange(of: note) { _, new in if !focused { text = new ?? "" } }
        .onChange(of: focused) { _, isFocused in if !isFocused { commit() } }
    }

    private func commit() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t != (note ?? "") { save(t.isEmpty ? nil : t) }
        focused = false
    }
}

/// A set: number, load as planned (grey) or done (bold, tinted row), the plan struck through when
/// the athlete did something else; a big check on the right. The whole row is the tap target.
struct SetRow: View {
    let set: StrengthSet

    var body: some View {
        let load = set.actual ?? set.planned
        HStack(spacing: Space.m) {
            Text(verbatim: "\(set.setIndex + 1)")
                .font(.footnote.weight(.semibold).monospacedDigit())
                .foregroundStyle(set.done ? Sport.strength.color : .secondary)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 0) {
                LoadText(load: load, done: set.done)
                if let planned = set.planned, let actual = set.actual, planned != actual {
                    Text(planned.formatted()).font(.caption.monospacedDigit()).strikethrough().foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 30))
                .foregroundStyle(set.done ? Sport.strength.color : Color.secondary.opacity(0.4))
                .contentTransition(.symbolEffect(.replace))
        }
        .padding(.horizontal, Space.m)
        .frame(minHeight: 56)
        .background(set.done ? Sport.strength.color.opacity(0.1) : Color.secondary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(set.done ? L("Done") : "")
    }
}

/// "70 kg × 6": weight big, its unit small, reps big; hold and distance as text.
struct LoadText: View {
    let load: Load?
    let done: Bool

    var body: some View {
        let color: Color = done ? .primary : .secondary
        if let load, load.holdSec == nil, load.distanceM == nil, load.weightKg != nil || load.reps != nil {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if let w = load.weightKg, w > 0 {
                    StatValue(value: w.formatted(), unit: Units.current.kg, size: 24, color: color)
                }
                if let r = load.reps {
                    Text(verbatim: "×").font(.title3).foregroundStyle(.secondary)
                    Text(verbatim: "\(r)").font(.system(size: 24, weight: .semibold).monospacedDigit()).foregroundStyle(color)
                }
            }
        } else {
            Text(load?.formatted() ?? "—").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(color)
        }
    }
}

/// Weight ±2.5 kg, reps ±1, hold ±5 s; also typed in.
struct SetEditor: View {
    let set: StrengthSet
    let onSave: (Load) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var weight: Double
    @State private var reps: Int
    @State private var hold: Int

    init(set: StrengthSet, onSave: @escaping (Load) -> Void) {
        self.set = set
        self.onSave = onSave
        let base = set.actual ?? set.planned ?? Load()
        _weight = State(initialValue: base.weightKg ?? 0)
        _reps = State(initialValue: base.reps ?? 0)
        _hold = State(initialValue: base.holdSec ?? 0)
    }

    private var usesHold: Bool { (set.planned?.holdSec ?? set.actual?.holdSec) != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section(L("Weight")) {
                    Stepper(value: $weight, in: 0...500, step: 2.5) {
                        HStack {
                            TextField("0", value: $weight, format: .number)
                                .font(.title2.monospacedDigit())
                                #if os(iOS)
                                .keyboardType(.decimalPad)
                                #endif
                            Text(Units.current.kg).foregroundStyle(.secondary)
                        }
                    }
                }
                if usesHold {
                    Section(L("Hold")) {
                        Stepper(value: $hold, in: 0...3600, step: 5) {
                            Text(Formats.stepTime(hold)).font(.title2.monospacedDigit())
                        }
                    }
                } else {
                    Section(L("Reps")) {
                        Stepper(value: $reps, in: 0...100) {
                            Text("\(reps)").font(.title2.monospacedDigit())
                        }
                    }
                }
            }
            .navigationTitle(set.exercise)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(L("Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("Save")) {
                        onSave(Load(reps: usesHold ? (reps > 0 ? reps : nil) : reps,
                                    weightKg: weight > 0 ? weight : nil,
                                    holdSec: usesHold ? hold : nil))
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Environment

private struct PlanContextKey: EnvironmentKey {
    static let defaultValue: PlanContext? = nil
}

extension EnvironmentValues {
    public var planContext: PlanContext? {
        get { self[PlanContextKey.self] }
        set { self[PlanContextKey.self] = newValue }
    }
}
