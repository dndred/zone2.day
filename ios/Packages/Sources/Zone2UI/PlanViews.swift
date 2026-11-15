import SwiftUI
import Zone2Kit

/// Workout card on Today. Plan and fact are one object (principle 4): once done, the card
/// shows the result under the plan.
struct WorkoutCard: View {
    let item: PlannedItem
    var expanded = true

    var body: some View {
        let w = item.workout
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: Sport.symbol(w.sport, subSport: w.subSport))
                    .foregroundStyle(w.sport.color)
                Text(w.title).font(expanded ? .title3.weight(.semibold) : .headline)
                if w.key { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                Spacer()
                StatusBadge(status: item.status)
            }
            if let goal = w.goal, expanded {
                Text(goal).font(.subheadline).foregroundStyle(.secondary)
            }
            if let s = w.resolved {
                StructureBar(structure: s, sport: w.sport, height: expanded ? 28 : 16)
                if expanded {
                    Text(structureSummary(s, sport: w.sport))
                        .font(.footnote.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            } else if let s = w.strength, expanded {
                Text(s.items.compactMap { $0.exercise?.exercise ?? $0.items?.map(\.exercise).joined(separator: " + ") }
                    .joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if let skipped = w.skipped {
                Text(skipped.reason).font(.footnote).foregroundStyle(.secondary)
            }
            if let a = item.activity {
                Divider()
                ActivityHeadline(activity: a)
            } else if expanded, let exec = executionLabel(w.execution), item.status == .planned {
                Label(exec, systemImage: w.execution == "mywhoosh" ? "laptopcomputer" : "applewatch")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 14))
        .opacity(item.status == .skipped ? 0.55 : 1)
    }
}

struct StatusBadge: View {
    let status: WorkoutStatus
    var body: some View {
        if status != .planned {
            Label(status.title, systemImage: status.symbol)
                .labelStyle(.iconOnly)
                .foregroundStyle(status.color)
                .accessibilityLabel(status.title)
        }
    }
}

/// Planned workout: structure with absolute targets, then the result if done.
public struct PlannedWorkoutView: View {
    let item: PlannedItem

    public init(item: PlannedItem) { self.item = item }

    public var body: some View {
        let w = item.workout
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(w.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                            .font(.subheadline).foregroundStyle(.secondary)
                        if w.key { Chip(text: L("Key workout"), color: .yellow) }
                        Spacer()
                        if item.status != .planned { Chip(text: item.status.title, color: item.status.color) }
                    }
                    if let goal = w.goal { Text(goal).font(.body) }
                    if let s = w.resolved { StructureBar(structure: s, sport: w.sport, height: 40) }
                    if let exec = executionLabel(w.execution) {
                        Label(exec, systemImage: w.execution == "mywhoosh" ? "laptopcomputer" : "applewatch")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            if let skipped = w.skipped {
                Section(L("Skipped")) { Text(skipped.reason) }
            }
            if let s = w.resolved {
                Section(L("Steps")) { StepList(structure: s, sport: w.sport) }
            }
            if let s = w.strength {
                Section(L("Exercises")) { StrengthList(structure: s) }
            }
            if let notes = w.notes {
                Section(L("Notes")) { Text(LocalizedStringKey(notes)) }
            }
            if let a = item.activity {
                Section(L("Result")) {
                    NavigationLink {
                        ActivityView(activity: a)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.title ?? "").font(.subheadline.weight(.medium))
                            ActivityHeadline(activity: a)
                        }
                    }
                }
            }
        }
        .navigationTitle(w.title)
        .inlineTitle()
    }
}

/// "Updated 18:02" · "Offline · updated 18:02" — trust in what is on screen (principle 2).
struct SyncStatusLine: View {
    let status: SyncStatus
    var syncing = false

    var body: some View {
        HStack(spacing: 6) {
            if syncing {
                ProgressView().controlSize(.mini)
                Text("Syncing…", bundle: .module)
            } else if let at = status.lastSyncAt {
                if let err = status.lastError {
                    Image(systemName: err == "offline" ? "wifi.slash" : "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Text("Updated \(at.formatted(Self.style(for: at)))", bundle: .module)
            } else {
                Text("Not synced yet", bundle: .module)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    static func style(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()
    }
}
