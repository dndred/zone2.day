import SwiftUI
import Zone2Kit

/// Headline numbers of an activity. With manual intervals the main one is shown first
/// (a parkrun inside warm-up through traffic lights), whole-workout totals after it.
struct ActivityHeadline: View {
    let activity: Activity

    var body: some View {
        let s = activity.summary
        VStack(alignment: .leading, spacing: 6) {
            if let main = mainInterval {
                HStack(spacing: 14) {
                    if let d = main.distanceM { Metric(Formats.distance(d)) }
                    Metric(Formats.clock(main.durationSec))
                    if let p = main.paceSecPerKm, activity.sport == .run { Metric(Formats.pace(p)) }
                    if let hr = main.avgHr { Metric("♥ \(Int(hr))") }
                }
                Text(totalsLine(s)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    if let d = s.distanceM { Metric(Formats.distance(d)) }
                    if let t = s.movingSec ?? s.elapsedSec { Metric(Formats.clock(t)) }
                    if let p = s.paceSecPerKm { Metric(Formats.pace(p)) }
                    else if let p = s.paceSecPer100m { Metric(Formats.pace100(p)) }
                    else if let v = s.speedKmh { Metric(String(format: "%.1f km/h", v)) }
                    if let hr = s.hr?.avg { Metric("♥ \(Int(hr))") }
                }
            }
        }
    }

    /// The longest-effort manual interval: highest-HR one, ties → longest.
    private var mainInterval: Lap? {
        guard let xs = activity.summary.intervals, xs.count > 1 else { return nil }
        return xs.max { ($0.avgHr ?? 0, $0.durationSec) < ($1.avgHr ?? 0, $1.durationSec) }
    }

    private func totalsLine(_ s: ActivitySummary) -> String {
        var parts: [String] = [L("Total")]
        if let d = s.distanceM { parts.append(Formats.distance(d)) }
        if let t = s.elapsedSec { parts.append(Formats.clock(t)) }
        return parts.joined(separator: " · ")
    }
}

private struct Metric: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.headline.monospacedDigit())
    }
}

/// Full activity screen.
public struct ActivityView: View {
    let activity: Activity
    let planned: PlannedWorkout?

    public init(activity: Activity, planned: PlannedWorkout? = nil) {
        self.activity = activity
        self.planned = planned
    }

    public var body: some View {
        let s = activity.summary
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text(activity.title ?? activity.sport.rawValue).font(.title3.weight(.semibold))
                    } icon: {
                        Image(systemName: Sport.symbol(activity.sport, subSport: activity.subSport))
                            .foregroundStyle(activity.sport.color)
                    }
                    Text([activity.date.formatted(.dateTime.weekday(.wide).day().month(.wide)), activity.startLocal]
                        .compactMap { $0 }.joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(.secondary)
                    ActivityHeadline(activity: activity)
                }
                .padding(.vertical, 4)
            }

            if let intervals = s.intervals, !intervals.isEmpty {
                Section(L("Intervals")) { LapTable(laps: intervals, sport: activity.sport) }
            }

            Section(L("Summary")) {
                row(L("Distance"), s.distanceM.map { Formats.distance($0) + (s.distanceKind == "virtual" ? " ⓥ" : "") })
                row(L("Moving time"), s.movingSec.map(Formats.clock))
                row(L("Elapsed"), s.elapsedSec.map(Formats.clock))
                row(L("Pace"), s.paceSecPerKm.map(Formats.pace) ?? s.paceSecPer100m.map(Formats.pace100))
                row(L("Speed"), s.speedKmh.map { String(format: "%.1f km/h", $0) })
                row(L("Heart rate"), s.hr.flatMap { hr in hr.avg.map { "\(Int($0)) / \(Int(hr.max ?? $0)) bpm" } })
                row(L("Cadence"), (s.running?.cadenceSpm.map { "\(Int($0)) spm" }) ?? s.cycling?.cadenceAvg.map { "\(Int($0)) rpm" })
                row(L("Power"), (s.running?.powerAvg ?? s.cycling?.powerAvg).map { "\(Int($0)) W" })
                row(L("Elevation gain"), s.elevationGainM.map { "\(Int($0)) m" })
                row(L("Energy"), s.energyKcal.map { "\(Int($0)) kcal" })
                row(L("Weather"), s.weather.flatMap { w in w.tempC.map { String(format: "%.0f °C", $0) + (w.humidityPct.map { " · \(Int($0))%" } ?? "") } })
                if let r = s.running {
                    row(L("Stride length"), r.strideLengthM.map { String(format: "%.2f m", $0) })
                    row(L("Vertical oscillation"), r.verticalOscillationCm.map { String(format: "%.1f cm", $0) })
                    row(L("Ground contact"), r.groundContactMs.map { "\(Int($0)) ms" })
                }
                if let sw = s.swim {
                    row(L("Pool"), sw.poolLengthM.map { "\(Int($0)) m" })
                    row(L("Lengths"), sw.lengths.map(String.init))
                }
            }

            let splits = activity.laps.filter { $0.kind == "split_km" }
            let segments = activity.laps.filter { $0.kind == "segment" || $0.kind == "lap" }
            if !segments.isEmpty {
                Section(L("Segments")) { LapTable(laps: segments, sport: activity.sport) }
            }
            if !splits.isEmpty {
                Section(L("Splits")) { LapTable(laps: splits, sport: activity.sport) }
            }

            if let notes = activity.athleteNotes {
                Section(L("Athlete notes")) { Text(notes) }
            }
            if let notes = activity.coachNotes {
                Section(L("Coach notes")) { Text(LocalizedStringKey(notes)) }
            }
            if let planned {
                Section(L("Plan")) {
                    NavigationLink {
                        PlannedWorkoutView(item: PlannedItem(workout: planned, activity: nil, status: .done))
                    } label: {
                        Label(planned.title, systemImage: planned.sport.symbol)
                    }
                }
            }
            Section {
                row(L("Source"), [activity.source, activity.device].compactMap { $0 }.joined(separator: " · "))
                if s.detail == "summary_only" {
                    Text("Totals only: this copy has no heart rate or power samples.", bundle: .module)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle(activity.date.formatted(.dateTime.day().month(.abbreviated)))
        .inlineTitle()
    }

    @ViewBuilder
    private func row(_ title: String, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            LabeledContent(title) { Text(value).monospacedDigit() }
        }
    }
}

/// Laps as a compact table: distance, time, pace (or speed), HR, cadence.
struct LapTable: View {
    let laps: [Lap]
    let sport: Sport

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 6) {
            GridRow {
                Text("#", bundle: .module).gridColumnAlignment(.leading)
                Text("Distance", bundle: .module)
                Text("Time", bundle: .module)
                Text(sport == .bike ? "km/h" : "/km")
                Text("♥")
                Text("Cad.", bundle: .module)
            }
            .font(.caption).foregroundStyle(.secondary)
            ForEach(Array(laps.enumerated()), id: \.offset) { i, lap in
                GridRow {
                    Text("\(i + 1)").foregroundStyle(.secondary)
                    Text(lap.distanceM.map { Formats.distance($0) } ?? "–")
                    Text(Formats.clock(lap.durationSec))
                    Text(sport == .bike ? (lap.speedKmh.map { String(format: "%.1f", $0) } ?? "–") : (lap.paceSecPerKm.map(Formats.clock) ?? "–"))
                    Text(lap.avgHr.map { "\(Int($0))" } ?? "–")
                    Text(lap.cadence.map { "\(Int($0))" } ?? "–")
                }
                .font(.subheadline.monospacedDigit())
            }
        }
    }
}

/// Row for lists (Activities tab, unplanned activities in a day).
struct ActivityRow: View {
    let activity: Activity
    var showDate = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: Sport.symbol(activity.sport, subSport: activity.subSport))
                .font(.title3)
                .foregroundStyle(activity.isRecovery ? .secondary : activity.sport.color)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(activity.title ?? activity.sport.rawValue).font(.subheadline.weight(.medium)).lineLimit(1)
                    Spacer()
                    Text([showDate ? activity.date.formatted(.dateTime.day().month(.abbreviated)) : nil, activity.startLocal]
                        .compactMap { $0 }.joined(separator: " "))
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !activity.isRecovery { ActivityHeadline(activity: activity) }
            }
        }
        .opacity(activity.isRecovery ? 0.6 : 1)
    }
}
