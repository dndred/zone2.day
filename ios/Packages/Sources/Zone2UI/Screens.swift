import SwiftUI
import Zone2Kit

/// What screens need from the app: offline store to read, a way to pull now, sync state.
public struct PlanContext: Sendable {
    public let store: LocalStore
    public let refresh: @Sendable () async -> Void
    /// Sends queued local changes (gym log) now; offline it just returns.
    public let send: @Sendable () async -> Void
    /// Fetches an activity's curves into the offline cache (screens observe the cache).
    public let loadStreams: @Sendable (String) async -> Void

    public init(store: LocalStore, refresh: @escaping @Sendable () async -> Void,
                send: @escaping @Sendable () async -> Void = {},
                loadStreams: @escaping @Sendable (String) async -> Void = { _ in }) {
        self.store = store
        self.refresh = refresh
        self.send = send
        self.loadStreams = loadStreams
    }
}

// MARK: - Today

public struct TodayView: View {
    let context: PlanContext
    let syncing: Bool
    @State private var snap: PlanSnapshot?

    public init(context: PlanContext, syncing: Bool) {
        self.context = context
        self.syncing = syncing
    }

    public var body: some View {
        NavigationStack {
            ScrollView {
                if let snap {
                    // Full width even when the day is empty ("Rest day"), or the background shrinks.
                    content(snap).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .background(Color.groupedBackground)
            .navigationTitle(L("Today"))
            .refreshable { await context.refresh() }
            .task {
                do {
                    // The whole current week (strip and volume) plus the next days.
                    for try await s in context.store.observe(pastDays: 6, futureDays: 7) { snap = s }
                } catch {}
            }
        }
        .environment(\.athleteProfile, snap?.profile ?? Profile())
    }

    @ViewBuilder
    private func content(_ snap: PlanSnapshot) -> some View {
        let today = snap.today
        VStack(alignment: .leading, spacing: Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow(today.formatted(.dateTime.weekday(.wide).day().month(.wide)), color: .brand)
                SyncStatusLine(status: snap.status, syncing: syncing)
            }
            .padding(.horizontal, Space.xs)

            WeekCard(snap: snap)

            if let day = snap.day(today) {
                let firstOpen = day.planned.first { $0.status == .planned }?.id
                if day.planned.isEmpty && day.unplanned.isEmpty {
                    HStack(spacing: Space.m) {
                        Image(systemName: "leaf.fill")
                            .font(.title2)
                            .foregroundStyle(Color.zone(3).gradient)
                            .frame(width: 44, height: 44)
                            .background(Color.zone(3).opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Rest day", bundle: .module).font(.title3.weight(.bold))
                            Text("Recovery is part of the plan.", bundle: .module).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .card()
                }
                ForEach(day.planned) { item in
                    NavigationLink {
                        if item.workout.sport == .strength && item.status != .skipped {
                            GymView(workout: item.workout)
                        } else {
                            PlannedWorkoutView(item: item, onWatch: snap.status.onWatch.contains(item.id))
                        }
                    } label: {
                        WorkoutCard(item: item, expanded: item.id == firstOpen || item.status == .done || firstOpen == nil,
                                    onWatch: snap.status.onWatch.contains(item.id))
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.unplanned) { a in
                    NavigationLink { ActivityView(activity: a) } label: {
                        ActivityRow(activity: a).card()
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.journal) { j in
                    Label { MarkdownText(j.text, style: .compact) } icon: { Image(systemName: "note.text") }
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, Space.xs)
                }
            }

            let upcoming = snap.days.filter { $0.date > today && $0.date <= today.adding(days: 4) && !$0.isEmpty }
            if !upcoming.isEmpty {
                SectionTitle(L("Next days"))
                VStack(spacing: 0) {
                    ForEach(upcoming) { day in
                        DayRows(day: day, today: today, onWatch: snap.status.onWatch, titleLines: 2)
                            .padding(.horizontal, Space.l)
                            .padding(.vertical, Space.m)
                        if day.id != upcoming.last?.id { Divider().padding(.leading, 68) }
                    }
                }
                .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            }
        }
        .padding(.horizontal, Space.l)
        .padding(.bottom, Space.xl)
    }
}

/// The current week on Today: title (tap → the coach's header), a strip of seven days with a dot
/// per workout, and done volume against the plan.
struct WeekCard: View {
    let snap: PlanSnapshot
    @State private var showHeader = false

    var body: some View {
        let start = snap.today.weekStart
        let days = (0..<7).map { start.adding(days: $0) }
        let week = snap.weeks[start]
        let volume = WeekVolume(days: snap.days.filter { $0.date.weekStart == start })
        VStack(alignment: .leading, spacing: Space.m) {
            Button {
                withAnimation(.snappy) { showHeader.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Eyebrow(start.formatted(.dateTime.day().month(.abbreviated)) + " – "
                            + start.adding(days: 6).formatted(.dateTime.day().month(.abbreviated)))
                        Text(week?.title ?? L("This week")).font(.headline).multilineTextAlignment(.leading)
                    }
                    Spacer()
                    if week?.header != nil {
                        Image(systemName: "chevron.down")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(showHeader ? 180 : 0))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(week?.header == nil)
            if showHeader, let header = week?.header {
                MarkdownText(header, style: .compact).font(.subheadline).foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                ForEach(days, id: \.self) { date in
                    DayDot(date: date, day: snap.day(date), today: snap.today).frame(maxWidth: .infinity)
                }
            }

            if volume.plannedSec > 0 || volume.doneSec > 0 {
                Divider()
                HStack(alignment: .bottom, spacing: Space.l) {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            StatValue(value: Formats.hoursMinutes(volume.doneSec), size: 20)
                            if volume.plannedSec > 0 {
                                Text("of ≈\(Formats.hoursMinutes(volume.plannedSec))", bundle: .module)
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        if volume.plannedSec > 0 {
                            ProgressTrack(fraction: volume.doneSec / volume.plannedSec)
                        }
                    }
                    if volume.runM > 0 {
                        let p = Formats.distanceParts(volume.runM)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(Sport.run.title).font(.caption).foregroundStyle(.secondary)
                            StatValue(value: p.value, unit: p.unit, size: 20)
                        }
                    }
                }
            }
        }
        .card()
    }
}

/// One day of the week strip: weekday, number (today filled), a dot per workout.
struct DayDot: View {
    let date: LocalDate
    let day: Day?
    let today: LocalDate

    var body: some View {
        let isToday = date == today
        VStack(spacing: 6) {
            Text(date.formatted(.dateTime.weekday(.narrow)))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(isToday ? Color.brand : .secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.subheadline.weight(isToday ? .bold : .medium).monospacedDigit())
                .foregroundStyle(isToday ? .white : date < today ? .secondary : .primary)
                .frame(width: 32, height: 32)
                .background(Circle().fill(isToday ? Color.brand : .clear))
            HStack(spacing: 3) {
                ForEach(dots) { d in
                    Group {
                        if d.filled {
                            Circle().fill(d.color)
                        } else {
                            Circle().strokeBorder(d.color, lineWidth: 1.5)
                        }
                    }
                    .frame(width: 7, height: 7)
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .combine)
    }

    private struct DotItem: Identifiable {
        let id: String
        let color: Color
        let filled: Bool
    }

    private var dots: [DotItem] {
        guard let day else { return [] }
        let planned = day.planned.map { item in
            DotItem(id: item.id,
                    color: item.status == .skipped || item.status == .missed ? Color.secondary.opacity(0.5) : item.workout.sport.color,
                    filled: item.status == .done)
        }
        let extra = day.unplanned.filter { !$0.isRecovery }.map { DotItem(id: $0.id, color: $0.sport.color, filled: true) }
        return Array((planned + extra).prefix(4))
    }
}

/// Done and planned time of a week; run distance.
struct WeekVolume {
    var doneSec = 0.0
    var plannedSec = 0.0
    var runM = 0.0

    init(days: [Day]) {
        let acts = days.flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }.filter { !$0.isRecovery }
        doneSec = acts.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +)
        runM = acts.filter { $0.sport == .run }.compactMap(\.summary.distanceM).reduce(0, +)
        plannedSec = days.flatMap(\.planned).filter { $0.status != .skipped }.compactMap { item -> Double? in
            if let s = item.workout.resolved { return PlanEstimate(s, sport: item.workout.sport).seconds }
            // Strength has no length in the plan: count what was done, else ~45 min.
            if item.workout.sport == .strength {
                return item.activities.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +).nonZero ?? 45 * 60
            }
            return nil
        }.reduce(0, +)
    }
}

private extension Double {
    var nonZero: Double? { self == 0 ? nil : self }
}

/// Lines of one day with the date in a column: "ВТ 17 | 🏃 Easy 45 min".
struct DayRows: View {
    let day: Day
    let today: LocalDate
    var onWatch: Set<String> = []
    /// Two on Today (few days, room to read), one in the calendar (many days, scan fast).
    var titleLines = 1

    var body: some View {
        let isToday = day.date == today
        HStack(alignment: .top, spacing: Space.m) {
            VStack(spacing: 0) {
                Text(day.date.formatted(.dateTime.weekday(.abbreviated)).uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(isToday ? Color.brand : .secondary)
                Text(day.date.formatted(.dateTime.day()))
                    .font(.title3.weight(.bold).monospacedDigit())
                    .foregroundStyle(isToday ? Color.brand : day.date < today ? .secondary : .primary)
            }
            .frame(width: 40)

            VStack(alignment: .leading, spacing: Space.s) {
                ForEach(day.events) { e in
                    NavigationLink { EventView(event: e) } label: {
                        HStack(spacing: Space.s) {
                            Image(systemName: "flag.checkered")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .frame(width: 30, height: 30)
                                .background(Color.brand.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            Text(e.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.planned) { item in
                    NavigationLink { PlannedWorkoutView(item: item, onWatch: onWatch.contains(item.id)) } label: {
                        DayItemRow(sport: item.workout.sport, subSport: item.workout.subSport, title: item.workout.title,
                                   subtitle: subtitle(item), key: item.workout.key, muted: item.status == .skipped,
                                   titleLines: titleLines) {
                            if item.status == .planned && onWatch.contains(item.id) {
                                Image(systemName: "applewatch").font(.caption).foregroundStyle(.green)
                            }
                            StatusBadge(status: item.status).font(.title3)
                        }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.unplanned) { a in
                    NavigationLink { ActivityView(activity: a) } label: {
                        DayItemRow(sport: a.sport, subSport: a.subSport, title: a.title ?? a.sport.title,
                                   subtitle: activityLine(a), key: false, muted: a.isRecovery, titleLines: titleLines) { EmptyView() }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(day.journal) { j in
                    Label { Text(MarkdownText.preview(j.text)) } icon: { Image(systemName: "note.text") }
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                if day.isEmpty {
                    Text(L("Day off")).font(.subheadline).foregroundStyle(.tertiary)
                        .frame(minHeight: 30)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Done → what was recorded; planned → what the plan adds up to; skipped → why.
    private func subtitle(_ item: PlannedItem) -> String? {
        if let skipped = item.workout.skipped { return skipped.reason }
        if !item.activities.isEmpty {
            var parts: [String] = []
            if let d = item.totalDistanceM { parts.append(Formats.distance(d)) }
            if let t = item.totalMovingSec { parts.append(Formats.clock(t)) }
            return parts.joined(separator: " · ")
        }
        if let s = item.workout.resolved {
            let e = PlanEstimate(s, sport: item.workout.sport)
            return (["≈" + Formats.hoursMinutes(e.seconds)] + (e.distanceM.map { [Formats.distance($0)] } ?? []))
                .joined(separator: " · ")
        }
        return nil
    }

    private func activityLine(_ a: Activity) -> String? {
        var parts: [String] = []
        if let d = a.summary.distanceM { parts.append(Formats.distance(d)) }
        if let t = a.summary.movingSec ?? a.summary.elapsedSec { parts.append(Formats.clock(t)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// Sport badge, title (+ key star), a grey line under it, trailing status.
struct DayItemRow<Trailing: View>: View {
    let sport: Sport
    let subSport: String?
    let title: String
    let subtitle: String?
    let key: Bool
    let muted: Bool
    var titleLines = 1
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Space.m) {
            SportBadge(sport: sport, subSport: subSport, size: 30, muted: muted)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold)).lineLimit(titleLines)
                    if key { Image(systemName: "star.fill").font(.caption2).foregroundStyle(Color.brand) }
                }
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
        .opacity(muted ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - Calendar

/// Weeks from history to the end of the plan. Opens on the current week; scrolling up loads
/// older weeks page by page; it ends at the last planned week, never in empty future weeks.
public struct CalendarView: View {
    let context: PlanContext
    let syncing: Bool
    @State private var snap: PlanSnapshot?
    @State private var pastDays = Self.pageDays
    /// Week kept in place while an older page loads above it.
    @State private var anchor: LocalDate?
    /// Set once the athlete scrolls: before that the top is visible only until the jump to today.
    @State private var scrolled = false
    @State private var nearTop = false

    static let pageDays = 8 * 7

    public init(context: PlanContext, syncing: Bool) {
        self.context = context
        self.syncing = syncing
    }

    public var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    if let snap {
                        LazyVStack(alignment: .leading, spacing: Space.xl) {
                            SyncStatusLine(status: snap.status, syncing: syncing)
                            if snap.hasEarlier {
                                ProgressView().frame(maxWidth: .infinity)
                            }
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
                .onScrollPhaseChange { _, phase in
                    if phase == .interacting { scrolled = true; loadEarlier() }
                }
                // Less than a screen above the viewport → load the previous page.
                .onScrollGeometryChange(for: Bool.self) { g in
                    g.contentOffset.y + g.contentInsets.top < g.containerSize.height
                } action: { _, near in
                    nearTop = near
                    loadEarlier()
                }
                .onChange(of: snap?.today) { _, today in
                    if let today { proxy.scrollTo(today.weekStart, anchor: .top) }
                }
                .onChange(of: snap?.days.first?.date) {
                    guard let week = anchor else { return }
                    // After the new weeks are laid out, or the jump lands short of the anchor.
                    Task { @MainActor in
                        proxy.scrollTo(week, anchor: .top)
                        anchor = nil
                        loadEarlier() // still near the top (a fast fling) → keep going
                    }
                }
            }
            .navigationTitle(L("Calendar"))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    NavigationLink { WeeklyProgressView(store: context.store) } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                    .accessibilityLabel(L("Progress"))
                }
            }
            .refreshable { await context.refresh() }
            .task(id: pastDays) {
                do {
                    for try await s in context.store.observeCalendar(pastDays: pastDays) { snap = s }
                } catch {}
            }
        }
        .environment(\.athleteProfile, snap?.profile ?? Profile())
    }

    private func loadEarlier() {
        guard scrolled, nearTop, anchor == nil, let snap, snap.hasEarlier, let first = snap.days.first else { return }
        anchor = first.date.weekStart
        pastDays += Self.pageDays
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
        let isCurrent = start == today.weekStart
        VStack(alignment: .leading, spacing: Space.s) {
            Button {
                withAnimation(.snappy) { showHeader.toggle() }
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow(start.formatted(.dateTime.day().month(.abbreviated)) + " – "
                        + start.adding(days: 6).formatted(.dateTime.day().month(.abbreviated)),
                        color: isCurrent ? .brand : .secondary)
                    HStack(alignment: .firstTextBaseline) {
                        Text(info?.title ?? "").font(.title3.weight(.bold)).multilineTextAlignment(.leading)
                        Spacer()
                        if info?.header != nil || info?.review != nil {
                            Image(systemName: "chevron.down")
                                .font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(showHeader ? 180 : 0))
                        }
                    }
                    WeekVolumeChips(days: days)
                    if showHeader {
                        ForEach([info?.header, info?.review].compactMap { $0 }, id: \.self) { text in
                            MarkdownText(text, style: .compact).font(.footnote).foregroundStyle(.secondary)
                                .padding(.top, 4)
                        }
                    }
                }
                .padding(.horizontal, Space.xs)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(info?.header == nil && info?.review == nil)

            VStack(spacing: 0) {
                ForEach(days) { day in
                    DayRows(day: day, today: today, onWatch: onWatch)
                        .padding(.horizontal, Space.l)
                        .padding(.vertical, day.isEmpty ? Space.s : Space.m)
                        .background(day.date == today ? Color.brand.opacity(0.07) : .clear)
                    if day.id != days.last?.id { Divider().padding(.leading, 68) }
                }
            }
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        }
    }
}

/// Done volume of a week by sport: a chip per sport ("🏃 32 km", "🚴 1 h 05 min") and the total time.
struct WeekVolumeChips: View {
    let days: [Day]

    var body: some View {
        let acts = days.flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }.filter { !$0.isRecovery }
        if !acts.isEmpty {
            let bySport = Dictionary(grouping: acts, by: \.sport)
            let total = acts.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +)
            // One row when it fits, else it scrolls (four sports and the total rarely fit).
            ViewThatFits(in: .horizontal) {
                chips(bySport, total)
                ScrollView(.horizontal, showsIndicators: false) { chips(bySport, total) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func chips(_ bySport: [Sport: [Activity]], _ total: Double) -> some View {
        HStack(spacing: Space.s) {
            ForEach(Sport.allCases.filter { bySport[$0] != nil }, id: \.self) { sport in
                let xs = bySport[sport]!
                let dist = xs.compactMap(\.summary.distanceM).reduce(0, +)
                let time = xs.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +)
                HStack(spacing: 4) {
                    Image(systemName: sport.symbol).font(.caption2.weight(.semibold))
                    Text(sport == .strength || dist == 0 ? Formats.hoursMinutes(time) : Formats.distance(dist))
                        .font(.caption.weight(.semibold).monospacedDigit())
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .foregroundStyle(sport.color)
                .background(sport.color.opacity(0.12), in: Capsule())
                .fixedSize()
            }
            Text(Formats.hoursMinutes(total)).font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, Space.xs)
        }
    }
}
