import SwiftUI
import Zone2Kit

/// What screens need from the app: offline store to read, a way to pull now, sync state.
public struct PlanContext: Sendable {
    public let store: LocalStore
    public let refresh: @Sendable () async -> Void

    public init(store: LocalStore, refresh: @escaping @Sendable () async -> Void) {
        self.store = store
        self.refresh = refresh
    }
}

// MARK: - Today

public struct TodayView: View {
    let context: PlanContext
    let syncing: Bool
    @State private var snap: PlanSnapshot?
    @State private var events: [PlanEvent] = []
    @State private var showWeekHeader = false

    public init(context: PlanContext, syncing: Bool) {
        self.context = context
        self.syncing = syncing
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let snap {
                    content(snap)
                }
            }
            .background(Color.groupedBackground)
            .navigationTitle(L("Today"))
            .refreshable { await context.refresh() }
            .task {
                do {
                    for try await s in context.store.observe(pastDays: 0, futureDays: 4) { snap = s }
                } catch {}
            }
            .task {
                do {
                    for try await e in context.store.observeEvents() { events = e }
                } catch {}
            }
        }
    }

    @ViewBuilder
    private func content(_ snap: PlanSnapshot) -> some View {
        let today = snap.today
        VStack(alignment: .leading, spacing: 16) {
            SyncStatusLine(status: snap.status, syncing: syncing)

            if let week = snap.weeks[today.weekStart], week.title != nil || week.header != nil {
                Button {
                    withAnimation(.snappy) { showWeekHeader.toggle() }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(week.title ?? L("This week")).font(.headline)
                            Spacer()
                            if week.header != nil {
                                Image(systemName: showWeekHeader ? "chevron.up" : "chevron.down")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if showWeekHeader, let header = week.header {
                            Text(LocalizedStringKey(header)).font(.subheadline).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.plain)
            }

            if let day = snap.day(today) {
                let firstOpen = day.planned.first { $0.status == .planned }?.id
                if day.planned.isEmpty && day.unplanned.isEmpty {
                    Text("Rest day", bundle: .module)
                        .font(.title3).foregroundStyle(.secondary)
                        .padding(.vertical, 8)
                }
                ForEach(day.planned) { item in
                    NavigationLink {
                        PlannedWorkoutView(item: item, onWatch: snap.status.onWatch.contains(item.id))
                    } label: {
                        WorkoutCard(item: item, expanded: item.id == firstOpen || item.status == .done || firstOpen == nil,
                                    onWatch: snap.status.onWatch.contains(item.id))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.unplanned) { a in
                    NavigationLink { ActivityView(activity: a) } label: {
                        ActivityRow(activity: a)
                            .padding(14)
                            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.journal) { j in
                    Label(j.text, systemImage: "note.text").font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let next = events.first(where: { $0.isConfirmed && $0.dateFrom >= today }) {
                EventCountdown(event: next, today: today)
            }

            let upcoming = snap.days.filter { $0.date > today && !$0.isEmpty }
            if !upcoming.isEmpty {
                Text("Next days", bundle: .module).font(.headline).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(upcoming) { day in
                        DayRows(day: day, today: today, onWatch: snap.status.onWatch)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        if day.id != upcoming.last?.id { Divider().padding(.leading, 14) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 24)
    }
}

struct EventCountdown: View {
    let event: PlanEvent
    let today: LocalDate

    var body: some View {
        HStack {
            Image(systemName: "flag.checkered")
            VStack(alignment: .leading) {
                Text(event.name).font(.subheadline.weight(.medium))
                Text(event.dateFrom.formatted(.dateTime.day().month(.wide))).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(today.days(until: event.dateFrom)) d", bundle: .module).font(.headline.monospacedDigit())
        }
        .padding(14)
        .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// Compact lines of one day: "Tue 17 Nov  🏃 Easy 45 min".
struct DayRows: View {
    let day: Day
    let today: LocalDate
    var onWatch: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(day.date.relativeTitle(today: today))
                .font(.caption.weight(.semibold))
                .foregroundStyle(day.date == today ? Color.accentColor : .secondary)
            ForEach(day.events) { e in
                Label(e.name, systemImage: "flag.checkered").font(.subheadline.weight(.medium))
            }
            ForEach(day.planned) { item in
                NavigationLink { PlannedWorkoutView(item: item, onWatch: onWatch.contains(item.id)) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Sport.symbol(item.workout.sport, subSport: item.workout.subSport))
                            .foregroundStyle(item.workout.sport.color)
                            .frame(width: 22)
                        Text(item.workout.title).font(.subheadline).lineLimit(1)
                        if item.workout.key { Image(systemName: "star.fill").font(.caption2).foregroundStyle(.yellow) }
                        Spacer()
                        if let a = item.activity, let d = a.summary.distanceM {
                            Text(Formats.distance(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        if item.status == .planned && onWatch.contains(item.id) {
                            Image(systemName: "applewatch").font(.caption).foregroundStyle(.green)
                        }
                        StatusBadge(status: item.status)
                    }
                    .opacity(item.status == .skipped ? 0.5 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(day.unplanned) { a in
                NavigationLink { ActivityView(activity: a) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: Sport.symbol(a.sport, subSport: a.subSport))
                            .foregroundStyle(a.isRecovery ? .secondary : a.sport.color)
                            .frame(width: 22)
                        Text(a.title ?? a.sport.rawValue).font(.subheadline).lineLimit(1)
                        Spacer()
                        if let d = a.summary.distanceM {
                            Text(Formats.distance(d)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green.opacity(a.isRecovery ? 0.4 : 1))
                    }
                    .opacity(a.isRecovery ? 0.6 : 1)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(day.journal) { j in
                Label(j.text, systemImage: "note.text").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

// MARK: - Calendar

public struct CalendarView: View {
    let context: PlanContext
    let syncing: Bool
    @State private var snap: PlanSnapshot?

    static let pastDays = 8 * 7
    static let futureDays = 6 * 7

    public init(context: PlanContext, syncing: Bool) {
        self.context = context
        self.syncing = syncing
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let snap {
                        LazyVStack(alignment: .leading, spacing: 18) {
                            SyncStatusLine(status: snap.status, syncing: syncing)
                            ForEach(weeks(snap), id: \.start) { week in
                                WeekSection(start: week.start, days: week.days, info: snap.weeks[week.start], today: snap.today,
                                            onWatch: snap.status.onWatch)
                                    .id(week.start)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    }
                }
                .background(Color.groupedBackground)
                .onChange(of: snap?.today) { _, today in
                    if let today { proxy.scrollTo(today.weekStart, anchor: .top) }
                }
            }
            .navigationTitle(L("Calendar"))
            .refreshable { await context.refresh() }
            .task {
                do {
                    for try await s in context.store.observe(pastDays: Self.pastDays, futureDays: Self.futureDays) { snap = s }
                } catch {}
            }
        }
    }

    private func weeks(_ snap: PlanSnapshot) -> [(start: LocalDate, days: [Day])] {
        let grouped = Dictionary(grouping: snap.days) { $0.date.weekStart }
        return grouped.keys.sorted().map { ($0, grouped[$0]!.sorted { $0.date < $1.date }) }
    }
}

struct WeekSection: View {
    let start: LocalDate
    let days: [Day]
    let info: Week?
    let today: LocalDate
    var onWatch: Set<String> = []
    @State private var showHeader = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(.snappy) { showHeader.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(start.formatted(.dateTime.day().month(.abbreviated)) + " – "
                        + start.adding(days: 6).formatted(.dateTime.day().month(.abbreviated)))
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Text(info?.title ?? "").font(.headline)
                        Spacer()
                        Text(volume).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    if showHeader {
                        ForEach([info?.header, info?.review].compactMap { $0 }, id: \.self) { text in
                            Text(LocalizedStringKey(text)).font(.footnote).foregroundStyle(.secondary)
                                .multilineTextAlignment(.leading)
                                .padding(.top, 4)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(info?.header == nil && info?.review == nil)

            VStack(spacing: 0) {
                ForEach(days) { day in
                    if day.isEmpty {
                        HStack {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).day()))
                                .font(.caption).foregroundStyle(.tertiary)
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 6)
                    } else {
                        DayRows(day: day, today: today, onWatch: onWatch)
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(day.date == today ? Color.accentColor.opacity(0.08) : .clear)
                    }
                    if day.id != days.last?.id { Divider().padding(.leading, 14) }
                }
            }
            .background(Color.card, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    /// Done volume of the week: "run 32 km · 4 h 10 min".
    private var volume: String {
        let acts = days.flatMap { $0.planned.compactMap(\.activity) + $0.unplanned }.filter { !$0.isRecovery }
        guard !acts.isEmpty else { return "" }
        let run = acts.filter { $0.sport == .run }.compactMap(\.summary.distanceM).reduce(0, +)
        let time = acts.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +)
        var parts: [String] = []
        if run > 0 { parts.append(L("run \(Formats.distance(run))")) }
        parts.append(Formats.hoursMinutes(time))
        return parts.joined(separator: " · ")
    }
}

// MARK: - Activities

public struct ActivitiesView: View {
    let context: PlanContext
    @State private var activities: [Activity] = []
    @AppStorage("activities.showRecovery") private var showRecovery = false

    public init(context: PlanContext) { self.context = context }

    public var body: some View {
        NavigationStack {
            List {
                ForEach(activities.filter { showRecovery || !$0.isRecovery }) { a in
                    NavigationLink { ActivityView(activity: a) } label: { ActivityRow(activity: a, showDate: true) }
                }
            }
            .overlay {
                if activities.isEmpty {
                    ContentUnavailableView(L("No activities yet"), systemImage: "figure.run")
                }
            }
            .navigationTitle(L("Activities"))
            .toolbar {
                Toggle(isOn: $showRecovery) {
                    Label(L("Show recovery"), systemImage: "figure.mind.and.body")
                }
            }
            .refreshable { await context.refresh() }
            .task {
                do {
                    for try await xs in context.store.observeActivities() { activities = xs }
                } catch {}
            }
        }
    }
}
