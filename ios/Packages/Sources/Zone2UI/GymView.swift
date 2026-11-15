import SwiftUI
import Zone2Kit

/// Gym mode (docs/07-ios-app.md §3.5): sets prefilled from the plan; tap = done as planned,
/// swipe or long press = edit weight/reps. Every change is saved locally and queued for the
/// server, so it works offline. Screen stays on. No timers.
public struct GymView: View {
    @Environment(\.planContext) private var context
    let workout: PlannedWorkout
    @State private var session: StrengthSession?
    @State private var draft: StrengthSession
    @State private var editing: StrengthSet?
    @State private var noteFor: String?
    @State private var noteText = ""

    public init(workout: PlannedWorkout) {
        self.workout = workout
        _draft = State(initialValue: StrengthSession.draft(from: workout))
    }

    private var current: StrengthSession { session ?? draft }

    public var body: some View {
        let s = current
        List {
            Section {
                HStack {
                    Text(workout.title).font(.headline)
                    Spacer()
                    Text("\(s.doneCount) / \(s.sets.count)").font(.headline.monospacedDigit())
                        .foregroundStyle(s.doneCount == s.sets.count && !s.sets.isEmpty ? .green : .secondary)
                }
                if let goal = workout.goal { Text(goal).font(.subheadline).foregroundStyle(.secondary) }
            }
            ForEach(s.exercises, id: \.name) { ex in
                Section {
                    ForEach(ex.sets) { set in
                        SetRow(set: set)
                            .contentShape(Rectangle())
                            .onTapGesture { update { $0.toggle(set.id) } }
                            .swipeActions(edge: .trailing) {
                                Button(L("Edit")) { editing = set }.tint(.blue)
                            }
                            .contextMenu {
                                Button(L("Edit"), systemImage: "pencil") { editing = set }
                            }
                    }
                    Button {
                        update { $0.addSet(to: ex.name) }
                    } label: {
                        Label(L("Add set"), systemImage: "plus")
                    }
                    .font(.subheadline)
                } header: {
                    HStack {
                        Text(ex.name)
                        Spacer()
                        Button {
                            noteText = ex.sets.first?.note ?? ""
                            noteFor = ex.name
                        } label: {
                            Image(systemName: ex.sets.first?.note == nil ? "square.and.pencil" : "note.text")
                        }
                        .accessibilityLabel(L("Note"))
                    }
                } footer: {
                    if let note = ex.sets.first?.note { Text(note) }
                }
            }
        }
        .navigationTitle(L("Gym"))
        .inlineTitle()
        .sensoryFeedback(.success, trigger: s.doneCount)
        .sheet(item: $editing) { set in
            SetEditor(set: set) { load in update { $0.setActual(set.id, load) } }
                .presentationDetents([.medium])
        }
        .alert(L("Note"), isPresented: Binding(get: { noteFor != nil }, set: { if !$0 { noteFor = nil } })) {
            TextField(L("Note"), text: $noteText)
            Button(L("Save")) {
                if let name = noteFor { update { $0.setNote(name, noteText) } }
            }
            Button(L("Cancel"), role: .cancel) {}
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

    private func update(_ change: (inout StrengthSession) -> Void) {
        var s = current
        change(&s)
        session = s
        guard let context else { return }
        try? context.store.saveStrength(s)
        Task { await context.send() }
    }
}

struct SetRow: View {
    let set: StrengthSet

    var body: some View {
        HStack(spacing: 12) {
            Text("\(set.setIndex + 1)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 20)
            if let actual = set.actual {
                Text(actual.formatted()).font(.title3.weight(.semibold).monospacedDigit())
                if let planned = set.planned, planned != actual {
                    Text(planned.formatted()).font(.footnote.monospacedDigit()).strikethrough().foregroundStyle(.secondary)
                }
            } else {
                Text(set.planned?.formatted() ?? "—").font(.title3.monospacedDigit()).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: set.done ? "checkmark.circle.fill" : "circle")
                .font(.title2)
                .foregroundStyle(set.done ? .green : Color.secondary.opacity(0.5))
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
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
