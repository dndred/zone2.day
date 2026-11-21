import SwiftUI
import Zone2Kit

/// Workout card on Today. Plan and fact are one object (principle 4): once done, the card
/// shows the result under the plan. Expanded: the next open workout of the day.
struct WorkoutCard: View {
    let item: PlannedItem
    var expanded = true
    var onWatch = false

    var body: some View {
        let w = item.workout
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                SportBadge(sport: w.sport, subSport: w.subSport, size: expanded ? 44 : 36, muted: item.status == .skipped)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(eyebrow, color: w.key ? .brand : .secondary)
                    Text(w.title)
                        .font(expanded ? .title3.weight(.bold) : .headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                StatusBadge(status: item.status).font(.title2)
            }
            if let goal = w.goal, expanded {
                MarkdownText(goal, style: .compact).font(.subheadline).foregroundStyle(.secondary)
            }
            if let s = w.resolved {
                StructureBar(structure: s, sport: w.sport, height: expanded ? 40 : 20)
                if expanded && item.activities.isEmpty {
                    PlanStats(estimate: PlanEstimate(s, sport: w.sport), sport: w.sport, size: 20)
                }
            } else if let s = w.strength, expanded {
                Text(s.items.compactMap { $0.exercise?.exercise ?? $0.items?.map(\.exercise).joined(separator: " + ") }
                    .joined(separator: " · "))
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
            }
            if let skipped = w.skipped {
                Label(skipped.reason, systemImage: "minus.circle").font(.footnote).foregroundStyle(.secondary)
            }
            if !item.activities.isEmpty {
                Divider()
                if item.activities.count > 1 { PartsTotal(item: item) }
                ForEach(item.activities) { ActivityHeadline(activity: $0, size: expanded ? 22 : 18) }
            } else if expanded, item.status == .planned {
                DeliveryLabel(execution: w.execution, onWatch: onWatch)
            }
        }
        .card()
        .opacity(item.status == .skipped ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var eyebrow: String {
        let w = item.workout
        return ([w.sport.title] + (w.key ? [L("Key workout")] : [])).joined(separator: " · ")
    }
}

/// Planned time, distance and main target as small headline stats.
struct PlanStats: View {
    let estimate: PlanEstimate
    let sport: Sport
    var size: CGFloat = 22

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            StatTile(label: L("Time"), value: "≈" + Formats.clock(estimate.seconds), size: size)
            if let d = estimate.distanceM {
                let p = Formats.distanceParts(d)
                StatTile(label: L("Distance"), value: p.value, unit: p.unit, size: size)
            }
            if let t = estimate.mainTarget {
                let p = targetParts(t, sport: sport)
                StatTile(label: L("Target"), value: p.value, unit: p.unit, size: size)
            }
        }
    }
}

/// "≤ 150" + "bpm": the target's number apart from its unit (RPE stays whole).
func targetParts(_ t: Target, sport: Sport) -> (value: String, unit: String?) {
    let s = Formats.target(t, sport: sport)
    guard t.metric != .rpe, let space = s.lastIndex(of: " ") else { return (s, nil) }
    return (String(s[..<space]), String(s[s.index(after: space)...]))
}

/// "Total · 19.0 km · 1:52:10" when one workout was recorded in several parts.
struct PartsTotal: View {
    let item: PlannedItem

    var body: some View {
        HStack(spacing: Space.m) {
            Eyebrow(L("Total"))
            if let d = item.totalDistanceM { Text(Formats.distance(d)) }
            if let t = item.totalMovingSec { Text(Formats.clock(t)) }
        }
        .font(.subheadline.weight(.semibold).monospacedDigit())
    }
}

/// "Changed 10 Nov: easier after the race" — why the coach changed it last.
struct LastChangeLine: View {
    let change: PlannedWorkout.LastChange
    /// Shown only at the bottom of the workout detail (history, not the plan); whole reason by default.
    var lineLimit: Int? = nil

    var body: some View {
        if let why = change.why, !why.isEmpty {
            let when = change.date.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? ""
            Label {
                Text("Changed \(when): \(why)", bundle: .module)
            } icon: {
                Image(systemName: "pencil.line")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(lineLimit)
            .fixedSize(horizontal: false, vertical: lineLimit == nil)
        }
    }
}

/// Where the workout will be done, and for the watch whether it is already there (principle 2).
struct DeliveryLabel: View {
    let execution: String
    let onWatch: Bool

    var body: some View {
        if execution == "workoutkit" {
            if onWatch {
                Pill(text: L("On watch"), systemImage: "applewatch.radiowaves.left.and.right", color: .green)
            } else {
                Pill(text: L("Not on watch yet"), systemImage: "applewatch.slash")
            }
        } else if let exec = executionLabel(execution) {
            Pill(text: exec, systemImage: execution == "mywhoosh" ? "laptopcomputer" : "applewatch")
        }
    }
}

struct StatusBadge: View {
    let status: WorkoutStatus
    var body: some View {
        if status != .planned {
            Image(systemName: status.symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(status.color)
                .accessibilityLabel(status.title)
        }
    }
}

/// Planned workout: structure with absolute targets, then the result if done.
public struct PlannedWorkoutView: View {
    let item: PlannedItem
    let onWatch: Bool

    public init(item: PlannedItem, onWatch: Bool = false) {
        self.item = item
        self.onWatch = onWatch
    }

    public var body: some View {
        let w = item.workout
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header(w)

                if let s = w.resolved {
                    VStack(alignment: .leading, spacing: Space.l) {
                        StructureBar(structure: s, sport: w.sport, height: 84, showsAxis: true)
                        PlanStats(estimate: PlanEstimate(s, sport: w.sport), sport: w.sport, size: 24)
                        if item.status == .planned {
                            DeliveryLabel(execution: w.execution, onWatch: onWatch)
                        }
                    }
                    .card()
                } else if item.status == .planned, w.sport != .strength {
                    DeliveryLabel(execution: w.execution, onWatch: onWatch)
                }

                if let skipped = w.skipped {
                    Label(skipped.reason, systemImage: "minus.circle")
                        .font(.subheadline)
                        .card()
                }

                if w.sport == .strength && item.status != .skipped {
                    NavigationLink {
                        GymView(workout: w)
                    } label: {
                        Label(item.status == .done ? L("Open gym log") : L("Start in the gym"),
                              systemImage: "figure.strengthtraining.traditional")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .buttonBorderShape(.capsule)
                    .controlSize(.large)
                }

                if let s = w.resolved {
                    SectionTitle(L("Steps"))
                    StepList(structure: s, sport: w.sport).card(padding: Space.l)
                }
                if let s = w.strength {
                    SectionTitle(L("Exercises"))
                    StrengthList(structure: s).card()
                }
                if let notes = w.notes {
                    SectionTitle(L("Notes"))
                    MarkdownText(notes).card()
                }
                if !item.activities.isEmpty {
                    SectionTitle(L("Result"))
                    if item.activities.count > 1 { PartsTotal(item: item).padding(.horizontal, Space.xs) }
                    ForEach(item.activities) { a in
                        NavigationLink {
                            ActivityView(activity: a, planned: w, linkToPlan: false)
                        } label: {
                            ActivityResultCard(activity: a)
                        }
                        .buttonStyle(.plain)
                    }
                }
                // The coach's change log is history, not the plan: last, below the result.
                if let change = w.lastChange, let why = change.why, !why.isEmpty {
                    LastChangeLine(change: change).padding(.horizontal, Space.xs).padding(.top, Space.s)
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
        .background(Color.groupedBackground)
        .navigationTitle(w.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        .inlineTitle()
    }

    private func header(_ w: PlannedWorkout) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                SportBadge(sport: w.sport, subSport: w.subSport, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Eyebrow(w.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    Text(w.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack(spacing: Space.s) {
                if w.key { Pill(text: L("Key workout"), systemImage: "star.fill", color: .brand) }
                if item.status != .planned {
                    Pill(text: item.status.title, systemImage: item.status.symbol, color: item.status.color)
                }
            }
            if let goal = w.goal {
                MarkdownText(goal, style: .compact).font(.body).foregroundStyle(.secondary)
            }
        }
        .padding(.top, Space.s)
    }
}

/// A recorded activity under its plan: title, time of day and the headline numbers.
struct ActivityResultCard: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                SportBadge(sport: activity.sport, subSport: activity.subSport, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(activity.title ?? activity.sport.title).font(.headline).lineLimit(1)
                    if let start = activity.startLocal {
                        Text(start).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            ActivityHeadline(activity: activity, size: 22)
        }
        .card()
        .contentShape(Rectangle())
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
                if let err = status.watchError {
                    Text("· ", bundle: .module) + Text(Image(systemName: "applewatch.slash")) + Text(" " + Self.watchError(err))
                } else if !status.onWatch.isEmpty {
                    Text("· ", bundle: .module) + Text(Image(systemName: "applewatch")) + Text(" \(status.onWatch.count)")
                }
            } else {
                Text("Not synced yet", bundle: .module)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    static func watchError(_ err: String) -> String {
        switch err {
        case "not authorized": L("no access to Workout")
        case "no watch": L("no watch")
        default: err
        }
    }

    static func style(for date: Date) -> Date.FormatStyle {
        Calendar.current.isDateInToday(date) ? .dateTime.hour().minute() : .dateTime.day().month(.abbreviated).hour().minute()
    }
}
