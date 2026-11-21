import Charts
import SwiftUI
import Zone2Kit

/// Weekly volume over the last 12 weeks (like Strava's progress chart): stacked bars by sport,
/// time or distance, the 12-week average as a line; tap a week to see its totals by sport.
/// Recovery activities don't count. Offline store only.
public struct WeeklyProgressView: View {
    let store: LocalStore
    @State private var snap: PlanSnapshot?
    @State private var metric: Metric = .time
    @State private var selected: Date?

    static let weeks = 12

    public init(store: LocalStore) { self.store = store }

    enum Metric: String, CaseIterable, Identifiable {
        case time, distance
        var id: String { rawValue }
        var title: String { self == .time ? L("Time") : L("Distance") }
    }

    struct Bar: Identifiable {
        let week: LocalDate
        let sport: Sport
        let seconds: Double
        let meters: Double
        var id: String { week.iso + sport.rawValue }
    }

    public var body: some View {
        ScrollView {
            if let snap {
                content(snap).padding(.horizontal, Space.l).padding(.bottom, Space.xl)
            }
        }
        .overlay { if snap == nil { ProgressView() } }
        .background(Color.groupedBackground)
        .navigationTitle(L("Progress"))
        .inlineTitle()
        .task {
            do {
                // The whole stored history (the snapshot keeps ~90 days): fitness needs a run-up.
                for try await s in store.observe(pastDays: 400, futureDays: 0) { snap = s }
            } catch {}
        }
    }

    static func bars(_ snap: PlanSnapshot) -> (weeks: [LocalDate], bars: [Bar]) {
        let current = snap.today.weekStart
        let weeks = (0..<weeks).map { current.adding(days: -7 * (weeks - 1 - $0)) }
        var bars: [Bar] = []
        for w in weeks {
            let acts = snap.days.filter { $0.date.weekStart == w }
                .flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }
                .filter { !$0.isRecovery }
            for sport in Sport.allCases {
                let xs = acts.filter { $0.sport == sport }
                guard !xs.isEmpty else { continue }
                bars.append(Bar(week: w, sport: sport,
                                seconds: xs.compactMap { $0.summary.movingSec ?? $0.summary.elapsedSec }.reduce(0, +),
                                meters: xs.compactMap(\.summary.distanceM).reduce(0, +)))
            }
        }
        return (weeks, bars)
    }

    private func value(_ b: Bar) -> Double { metric == .time ? b.seconds / 3600 : b.meters / 1000 }

    private func total(_ bars: [Bar]) -> String {
        metric == .time ? Formats.hoursMinutes(bars.map(\.seconds).reduce(0, +))
            : Formats.distance(bars.map(\.meters).reduce(0, +))
    }

    @ViewBuilder
    private func content(_ snap: PlanSnapshot) -> some View {
        let (weeks, all) = Self.bars(snap)
        let bars = metric == .distance ? all.filter { $0.meters > 0 } : all
        let week = selected.map { LocalDate.today(in: TimeZone(identifier: "UTC")!, now: $0).weekStart } ?? snap.today.weekStart
        let ofWeek = bars.filter { $0.week == week }
        let perWeek = weeks.map { w in bars.filter { $0.week == w }.map(value).reduce(0, +) }
        let average = perWeek.reduce(0, +) / Double(max(perWeek.count, 1))
        VStack(alignment: .leading, spacing: Space.l) {
            Picker(L("Metric"), selection: $metric) {
                ForEach(Metric.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.top, Space.s)

            VStack(alignment: .leading, spacing: Space.m) {
                Eyebrow(week.formatted(.dateTime.day().month(.abbreviated)) + " – "
                    + week.adding(days: 6).formatted(.dateTime.day().month(.abbreviated)),
                    color: week == snap.today.weekStart ? .brand : .secondary)
                StatValue(value: total(ofWeek), size: 30)
                Chart {
                    ForEach(bars) { b in
                        BarMark(x: .value("week", b.week.utcDate, unit: .weekOfYear), y: .value(metric.title, value(b)))
                            .foregroundStyle(b.sport.color.gradient)
                            .opacity(b.week == week ? 1 : 0.45)
                            .cornerRadius(3)
                    }
                    RuleMark(y: .value("avg", average))
                        .foregroundStyle(Color.primary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                }
                // A tap (or a drag along the bars) picks the week and it stays picked.
                .chartGesture { proxy in
                    DragGesture(minimumDistance: 0).onChanged { g in
                        if let d: Date = proxy.value(atX: g.location.x) { selected = d }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: weeks.enumerated().filter { $0.offset % 3 == 2 }.map(\.element.utcDate)) { v in
                        AxisValueLabel(format: .dateTime.day().month(.abbreviated), centered: true)
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 200)
                .sensoryFeedback(.selection, trigger: week)
                HStack(spacing: 4) {
                    Text("12-week average", bundle: .module)
                    Text(metric == .time ? Formats.hoursMinutes(average * 3600) : Formats.distance(average * 1000))
                        .monospacedDigit()
                }
                .font(.footnote).foregroundStyle(.secondary)
            }
            .card()

            // Shown once enough history has a load (a few weeks), else the curves mean little.
            let acts = snap.days.flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }
            let loads = Fitness.loads(acts)
            if loads.count >= 10 {
                SectionTitle(L("Training load"))
                FitnessCard(days: Fitness.series(loads: loads, to: snap.today))
            }

            if !ofWeek.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(ofWeek.enumerated()), id: \.element.id) { i, b in
                        if i > 0 { Divider().padding(.leading, 44) }
                        HStack(spacing: Space.m) {
                            SportBadge(sport: b.sport, size: 30)
                            Text(b.sport.title).font(.subheadline.weight(.semibold))
                            Spacer()
                            if b.meters > 0 {
                                Text(Formats.distance(b.meters)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            Text(Formats.hoursMinutes(b.seconds)).font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        .padding(.vertical, Space.s)
                    }
                }
                .card()
            }
        }
    }
}

/// Fitness, fatigue and form (as HealthFit's training load screen): today's three numbers, the
/// fitness area and fatigue line over the last weeks, form as bars below (green fresh, orange
/// loaded). Load is the server's TRIMP per activity.
struct FitnessCard: View {
    let days: [Fitness.Day]
    var lastDays = 84

    static let fitnessColor = Color(light: 0x2E90FA, dark: 0x53A6FF)
    static let fatigueColor = Color(light: 0xEE46BC, dark: 0xF670C7)

    var body: some View {
        let shown = Array(days.suffix(lastDays))
        if let today = shown.last {
            VStack(alignment: .leading, spacing: Space.m) {
                HStack(alignment: .top, spacing: Space.m) {
                    tile(L("Fitness"), today.fitness, Self.fitnessColor)
                    tile(L("Fatigue"), today.fatigue, Self.fatigueColor)
                    tile(L("Form"), today.form, today.form >= 0 ? .zone(3) : .zone(4))
                }
                Chart {
                    ForEach(shown, id: \.date) { d in
                        AreaMark(x: .value("day", d.date.utcDate, unit: .day), y: .value(L("Fitness"), d.fitness),
                                 series: .value("s", "fitness"))
                            .foregroundStyle(LinearGradient(colors: [Self.fitnessColor.opacity(0.3), Self.fitnessColor.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("day", d.date.utcDate, unit: .day), y: .value(L("Fitness"), d.fitness),
                                 series: .value("s", "fitness"))
                            .foregroundStyle(Self.fitnessColor)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                        LineMark(x: .value("day", d.date.utcDate, unit: .day), y: .value(L("Fatigue"), d.fatigue),
                                 series: .value("s", "fatigue"))
                            .foregroundStyle(Self.fatigueColor)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                }
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                        AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                        AxisValueLabel()
                    }
                }
                .frame(height: 150)
                Chart {
                    ForEach(shown, id: \.date) { d in
                        BarMark(x: .value("day", d.date.utcDate, unit: .day), y: .value(L("Form"), d.form))
                            .foregroundStyle(d.form >= 0 ? Color.zone(3) : Color.zone(4))
                    }
                    RuleMark(y: .value("zero", 0)).foregroundStyle(Color.secondary.opacity(0.4))
                }
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in AxisValueLabel() }
                }
                .frame(height: 60)
                Text("Load is TRIMP from heart-rate zones; fitness averages 42 days, fatigue 7.", bundle: .module)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .card()
        }
    }

    private func tile(_ label: String, _ value: Double, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 7, height: 7)
                Text(label).font(.footnote).foregroundStyle(.secondary)
            }
            StatValue(value: value.formatted(.number.precision(.fractionLength(0))), size: 26)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
