import MapKit
import SwiftUI
import Zone2Kit

/// Headline numbers of an activity. With manual intervals the main one is shown first
/// (a parkrun inside warm-up through traffic lights), whole-workout totals after it.
struct ActivityHeadline: View {
    let activity: Activity
    var size: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: Space.m) {
                ForEach(stats) { s in StatTile(label: s.label, value: s.value, unit: s.unit, size: size) }
            }
            if mainInterval != nil {
                Text(totalsLine(activity.summary)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }

    private var stats: [Stat] {
        let s = activity.summary
        var out: [Stat] = []
        if let main = mainInterval {
            if let d = main.distanceM { out.append(distanceStat(d)) }
            out.append(Stat(label: L("Time"), value: Formats.clock(main.durationSec)))
            if let p = main.paceSecPerKm, activity.sport == .run { out.append(Stat(label: L("Pace"), value: Formats.clock(p), unit: Units.current.perKm)) }
            if let hr = main.avgHr { out.append(Stat(label: L("Heart rate"), value: "\(Int(hr))")) }
            return out
        }
        if let d = s.distanceM { out.append(distanceStat(d)) }
        if let t = s.movingSec ?? s.elapsedSec { out.append(Stat(label: L("Time"), value: Formats.clock(t))) }
        if let p = s.paceSecPerKm, activity.sport != .bike {
            out.append(Stat(label: L("Pace"), value: Formats.clock(p), unit: Units.current.perKm))
        } else if let p = s.paceSecPer100m {
            out.append(Stat(label: L("Pace"), value: Formats.clock(p), unit: Units.current.per100m))
        } else if let v = s.speedKmh {
            out.append(Stat(label: L("Speed"), value: v.formatted(.number.precision(.fractionLength(1))), unit: Units.current.kmh))
        }
        if let hr = s.hr?.avg { out.append(Stat(label: L("Heart rate"), value: "\(Int(hr))")) }
        return Array(out.prefix(4))
    }

    private func distanceStat(_ m: Double) -> Stat {
        let p = Formats.distanceParts(m)
        return Stat(label: L("Distance"), value: p.value, unit: p.unit)
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

/// Full activity screen: route, headline numbers, the main chart, zones, splits, details, words.
public struct ActivityView: View {
    @Environment(\.planContext) private var context
    @Environment(\.athleteProfile) private var profile
    @State private var streams: ActivityStreams?
    /// The fetch has finished (with curves or without): placeholders give way to content or vanish.
    @State private var fetched = false
    let activity: Activity
    /// The plan this activity fulfils: its steps shade the chart (plan vs fact).
    let planned: PlannedWorkout?
    /// A link back to the plan; off when the screen was opened from that plan.
    let linkToPlan: Bool

    public init(activity: Activity, planned: PlannedWorkout? = nil, linkToPlan: Bool = true) {
        self.activity = activity
        self.planned = planned
        self.linkToPlan = linkToPlan
    }

    /// Curves are expected (full detail) but not here yet: blocks that need them hold their place.
    private var loading: Bool { streams == nil && !fetched && activity.summary.detail != "summary_only" }

    public var body: some View {
        let s = activity.summary
        let hrZones = profile.hrZones(for: activity.sport)
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                header

                if let streams, let pieces = RouteMap.pieces(streams, zones: hrZones, fallback: activity.sport.color) {
                    RouteMap(pieces: pieces)
                        .frame(height: 220)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                } else if loading, (s.routePoints ?? 0) > 1, s.indoor != true {
                    LoadingCard(height: 220)
                }

                StatGrid(stats: mainStats, columns: 3, size: 26).card()

                if let streams {
                    ActivityChartCard(activity: activity, streams: streams, zones: hrZones,
                                      plan: planned.flatMap { PlanWindow.windows($0, profile: profile) } ?? [])
                } else if loading {
                    ChartPlaceholder()
                }

                if let zones = hrZones, let hr = streams?.series("heartRate"), let b = streams?.bucketSec {
                    let secs = zones.seconds(in: hr, bucketSec: b)
                    if secs.reduce(0, +) > 0 {
                        SectionTitle(L("Heart rate zones"), trailing: zones.edwardsTrimp(secs).map { "TRIMP \($0)" })
                        ZoneDistribution(zones: zones, seconds: secs).card()
                    }
                } else if loading, let zones = hrZones, s.hr?.avg != nil {
                    SectionTitle(L("Heart rate zones"))
                    ZoneDistribution(zones: zones, seconds: Array(repeating: 0, count: zones.count))
                        .loadingPlaceholder(true)
                        .card()
                }

                if let streams {
                    let best = StreamMath.bestPower(streams, channel: powerChannel)
                    if best.count >= 2 {
                        SectionTitle(L("Power curve"))
                        PowerCurveCard(best: best, zones: profile.powerZones(for: activity.sport)).card()
                    }
                } else if loading, (s.cycling?.powerAvg ?? s.running?.powerAvg) != nil {
                    // As many rows as durations fit the recording, with stand-in numbers.
                    let fit = StreamMath.powerDurations.filter { Double($0) <= (s.elapsedSec ?? 0) }
                    if fit.count >= 2 {
                        SectionTitle(L("Power curve"))
                        PowerCurveCard(best: fit.map { StreamMath.BestPower(seconds: $0, watts: 200) }, zones: nil)
                            .loadingPlaceholder(true)
                            .card()
                    }
                }

                if let intervals = s.intervals, intervals.count > 1 {
                    SectionTitle(L("Intervals"))
                    LapTable(laps: intervals, sport: activity.sport).card()
                }
                let splits = activity.laps.filter { $0.kind == "split_km" }
                if splits.count > 1 {
                    SectionTitle(L("Splits"))
                    SplitsView(splits: splits, sport: activity.sport, climb: climbPerKm).card()
                }
                let segments = activity.laps.filter { $0.kind == "segment" || $0.kind == "lap" }
                if !segments.isEmpty {
                    SectionTitle(L("Segments"))
                    LapTable(laps: segments, sport: activity.sport).card()
                }

                let details = detailStats
                if !details.isEmpty {
                    SectionTitle(L("Details"))
                    StatGrid(stats: details, columns: 2, size: 20).card()
                }

                if let notes = activity.athleteNotes {
                    SectionTitle(L("Athlete notes"))
                    MarkdownText(notes).card()
                }
                if let notes = activity.coachNotes {
                    SectionTitle(L("Coach notes"))
                    HStack(alignment: .top, spacing: Space.m) {
                        Capsule().fill(Color.brand.gradient).frame(width: 3)
                        MarkdownText(notes)
                    }
                    .card()
                }
                if let planned, linkToPlan {
                    SectionTitle(L("Plan"))
                    NavigationLink {
                        PlannedWorkoutView(item: PlannedItem(workout: planned, activities: [], status: .done))
                    } label: {
                        HStack(spacing: Space.m) {
                            SportBadge(sport: planned.sport, subSport: planned.subSport, size: 32)
                            Text(planned.title).font(.headline).lineLimit(2)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                        .card()
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 4) {
                    let source = [activity.source, activity.device].compactMap { $0 }.joined(separator: " · ")
                    if !source.isEmpty { Label(source, systemImage: "applewatch").font(.caption) }
                    if s.detail == "summary_only" {
                        Text("Totals only: this copy has no heart rate or power samples.", bundle: .module).font(.caption)
                    }
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, Space.xs)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
        }
        .background(Color.groupedBackground)
        .task {
            guard let context, s.detail != "summary_only" else { return }
            let id = activity.id
            // Cached curves at once; else fetch, then take what landed (or give up the placeholders).
            if let cached = try? context.store.streams(id), cached.columns["lat"] != nil {
                streams = cached
            }
            Task {
                await context.loadStreams(id)
                if let loaded = try? context.store.streams(id) { streams = loaded }
                fetched = true
            }
            do {
                for try await cached in context.store.observeStreams(id) where cached != nil { streams = cached }
            } catch {}
        }
        .navigationTitle(activity.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        .inlineTitle()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Space.m) {
            SportBadge(sport: activity.sport, subSport: activity.subSport, size: 52, muted: activity.isRecovery)
            VStack(alignment: .leading, spacing: 2) {
                Eyebrow([activity.date.formatted(.dateTime.weekday(.wide).day().month(.wide)), activity.startLocal]
                    .compactMap { $0 }.joined(separator: " · "))
                Text(activity.title ?? activity.sport.title).font(.title2.weight(.bold))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Space.s)
    }

    /// Strava-style top block: distance, time, pace (speed); then heart rate, climb, energy.
    private var mainStats: [Stat] {
        let s = activity.summary
        let u = Units.current
        var first: [Stat] = []
        if let d = s.distanceM {
            let p = Formats.distanceParts(d)
            // Virtual distance (trainer, treadmill): marked in the label, the number stays clean.
            first.append(Stat(label: L("Distance") + (s.distanceKind == "virtual" ? " ⓥ" : ""), value: p.value, unit: p.unit))
        }
        if let t = s.movingSec ?? s.elapsedSec { first.append(Stat(label: L("Time"), value: Formats.clock(t))) }
        if let p = s.paceSecPerKm, activity.sport != .bike {
            first.append(Stat(label: L("Avg pace"), value: Formats.clock(p), unit: u.perKm))
        } else if let p = s.paceSecPer100m {
            first.append(Stat(label: L("Avg pace"), value: Formats.clock(p), unit: u.per100m))
        } else if let v = s.speedKmh {
            first.append(Stat(label: L("Avg speed"), value: v.formatted(.number.precision(.fractionLength(1))), unit: u.kmh))
        }
        var second: [Stat] = []
        if let hr = s.hr?.avg { second.append(Stat(label: L("Avg heart rate"), value: "\(Int(hr))", unit: u.bpm)) }
        // The load's slot is known up front (heart rate and zones), so the grid doesn't reflow
        // when the value arrives: the server's TRIMP, else from the curves, "–" meanwhile.
        if s.hr?.avg != nil, profile.hrZones(for: activity.sport) != nil, s.detail != "summary_only" {
            let load = s.analysis?.trimp.map { Int($0.rounded()) } ?? trimp
            if load != nil || loading {
                second.append(Stat(label: L("Load"), value: load.map { "\($0)" } ?? "–", unit: "TRIMP"))
            }
        }
        // Grade-adjusted pace (as Strava's GAP): only when the hills change it.
        if let gap = s.analysis?.gapSecPerKm, let p = s.paceSecPerKm, abs(gap - p) >= 3 {
            second.append(Stat(label: L("GAP"), value: Formats.clock(gap), unit: u.perKm))
        }
        if let p = s.cycling?.powerAvg ?? s.running?.powerAvg { second.append(Stat(label: L("Avg power"), value: "\(Int(p))", unit: u.watt)) }
        if let e = s.elevationGainM, e >= 1 { second.append(Stat(label: L("Elevation gain"), value: "\(Int(e))", unit: u.m)) }
        if let k = s.energyKcal { second.append(Stat(label: L("Energy"), value: "\(Int(k))", unit: u.kcal)) }
        if let hr = s.hr?.max { second.append(Stat(label: L("Max heart rate"), value: "\(Int(hr))", unit: u.bpm)) }
        // Fill the first row from the second when it is short (strength: time only).
        while first.count < 3 && !second.isEmpty { first.append(second.removeFirst()) }
        return first + second.prefix(6)
    }

    private var powerChannel: String { activity.sport == .bike ? "cyclingPower" : "runningPower" }

    /// Climbing per km for the splits table, when the curves have altitude and the climb is real.
    private var climbPerKm: [Double]? {
        guard let s = streams, let climb = StreamMath.elevationGainPerKm(s), climb.reduce(0, +) >= 5 else { return nil }
        return climb
    }

    /// Heart-rate load of the workout (Edwards TRIMP from time in zones), once the curve is cached.
    private var trimp: Int? {
        guard let zones = profile.hrZones(for: activity.sport), let s = streams, let hr = s.series("heartRate") else { return nil }
        return zones.edwardsTrimp(zones.seconds(in: hr, bucketSec: s.bucketSec))
    }

    private var detailStats: [Stat] {
        let s = activity.summary
        let u = Units.current
        var out: [Stat] = []
        if let t = s.elapsedSec, t - (s.movingSec ?? t) >= 30 { out.append(Stat(label: L("Elapsed"), value: Formats.clock(t))) }
        if let c = s.running?.cadenceSpm { out.append(Stat(label: L("Cadence"), value: "\(Int(c))", unit: u.spm)) }
        if let c = s.cycling?.cadenceAvg { out.append(Stat(label: L("Cadence"), value: "\(Int(c))", unit: u.rpm)) }
        if let p = s.cycling?.powerMax { out.append(Stat(label: L("Max power"), value: "\(Int(p))", unit: u.watt)) }
        if let r = s.running {
            if let v = r.strideLengthM { out.append(Stat(label: L("Stride length"), value: v.formatted(.number.precision(.fractionLength(2))), unit: u.m)) }
            if let v = r.verticalOscillationCm { out.append(Stat(label: L("Vertical oscillation"), value: v.formatted(.number.precision(.fractionLength(1))), unit: u.cm)) }
            if let v = r.groundContactMs { out.append(Stat(label: L("Ground contact"), value: "\(Int(v))", unit: u.ms)) }
        }
        if let sw = s.swim {
            if let v = sw.poolLengthM { out.append(Stat(label: L("Pool"), value: "\(Int(v))", unit: u.m)) }
            if let v = sw.lengths { out.append(Stat(label: L("Lengths"), value: "\(v)")) }
        }
        if let w = s.weather, let t = w.tempC {
            out.append(Stat(label: L("Weather"), value: String(format: "%.0f°", t), unit: w.humidityPct.map { "· \(Int($0))%" }))
        }
        if let d = s.analysis?.decoupling {
            // Pa:HR / Pw:HR: under 5 % the aerobic base held for the whole steady part.
            out.append(Stat(label: d.metric == "power" ? L("Pw:HR drift") : L("Pa:HR drift"),
                            value: d.pct.formatted(.number.precision(.fractionLength(1))), unit: "%"))
        }
        if let rpe = activity.rpe { out.append(Stat(label: "RPE", value: rpe.formatted())) }
        return out
    }
}

// MARK: - Route

/// The route over a quiet map, coloured by heart-rate zone where the pulse is known (as in
/// HealthFit), else in the sport colour; start and finish as dots. Not interactive: the screen
/// scrolls over it.
struct RouteMap: View {
    struct Piece: Identifiable {
        let id: Int
        let coordinates: [CLLocationCoordinate2D]
        let color: Color
    }

    let pieces: [Piece]

    /// Route points with the zone of the heart rate at each; a new piece starts where the zone
    /// changes (sharing the boundary point so the line stays whole).
    static func pieces(_ s: ActivityStreams, zones: ZoneSet?, fallback: Color) -> [Piece]? {
        guard let lat = s.series("lat"), let lon = s.series("lon") else { return nil }
        let hr = s.series("heartRate")
        var out: [Piece] = []
        var current: [CLLocationCoordinate2D] = []
        var color: Color?
        var lastZone: Int?
        for i in 0..<min(lat.count, lon.count) {
            guard let a = lat[i], let b = lon[i] else { continue }
            let c = CLLocationCoordinate2D(latitude: a, longitude: b)
            let z = zones.flatMap { zs in (hr?[i] ?? nil).map { zs.displayZone(of: $0) } } ?? lastZone
            if z != lastZone, !current.isEmpty {
                out.append(Piece(id: out.count, coordinates: current + [c], color: color ?? fallback))
                current = []
            }
            current.append(c)
            color = z.map { Color.zone($0) } ?? fallback
            lastZone = z
        }
        if current.count > 1 || (!current.isEmpty && !out.isEmpty) {
            out.append(Piece(id: out.count, coordinates: current, color: color ?? fallback))
        }
        let total = out.reduce(0) { $0 + $1.coordinates.count }
        return total > 1 ? out : nil
    }

    private var all: [CLLocationCoordinate2D] { pieces.flatMap(\.coordinates) }

    private var region: MKCoordinateRegion {
        let lats = all.map(\.latitude), lons = all.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!, minLon = lons.min()!, maxLon = lons.max()!
        return MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2),
            span: MKCoordinateSpan(latitudeDelta: max((maxLat - minLat) * 1.4, 0.004), longitudeDelta: max((maxLon - minLon) * 1.4, 0.004))
        )
    }

    var body: some View {
        Map(initialPosition: .region(region), interactionModes: []) {
            MapPolyline(coordinates: all)
                .stroke(.white, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
            ForEach(pieces) { p in
                MapPolyline(coordinates: p.coordinates)
                    .stroke(p.color, style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
            if let start = all.first {
                Annotation("", coordinate: start) { Circle().fill(.green).stroke(.white, lineWidth: 2).frame(width: 12, height: 12) }
            }
            if let end = all.last {
                Annotation("", coordinate: end) { Circle().fill(.red).stroke(.white, lineWidth: 2).frame(width: 12, height: 12) }
            }
        }
        .mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll))
        .accessibilityHidden(true)
    }
}

// MARK: - Zones

/// Time per heart-rate zone as bars (Z1 at the top), with the zone's range and share.
struct ZoneDistribution: View {
    let zones: ZoneSet
    let seconds: [Double]

    var body: some View {
        let total = max(seconds.reduce(0, +), 1)
        let peak = max(seconds.max() ?? 1, 1)
        VStack(spacing: Space.m) {
            ForEach(Array(seconds.enumerated()), id: \.offset) { i, sec in
                let z = i + 1
                HStack(spacing: Space.m) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(verbatim: "Z\(z)").font(.subheadline.weight(.bold)).foregroundStyle(Color.zone(min(z, 5)))
                        Text(rangeLabel(z)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 64, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.1))
                            RoundedRectangle(cornerRadius: 4).fill(Color.zone(min(z, 5)).gradient)
                                .frame(width: sec > 0 ? max(4, geo.size.width * sec / peak) : 0)
                        }
                    }
                    .frame(height: 18)
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(Formats.clock(sec)).font(.subheadline.weight(.semibold).monospacedDigit())
                        Text(verbatim: "\(Int((sec / total * 100).rounded()))%").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    .frame(width: 58, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func rangeLabel(_ z: Int) -> String {
        let r = zones.range(of: z)
        switch (r.low, r.high) {
        case let (nil, h?): return "< \(Int(h) + 1)"
        case let (l?, nil): return "≥ \(Int(l))"
        case let (l?, h?): return "\(Int(l))–\(Int(h))"
        default: return ""
        }
    }
}

// MARK: - Splits and laps

/// Kilometre splits as in Strava: pace with a bar (longer = faster) and heart rate.
struct SplitsView: View {
    let splits: [Lap]
    let sport: Sport
    /// Metres climbed per km (from the curves), Strava's "Elev" column.
    var climb: [Double]?

    private func speed(_ l: Lap) -> Double? {
        if let p = l.paceSecPerKm, p > 0 { return 1000 / p }
        return l.speedKmh.map { $0 / 3.6 }
    }

    var body: some View {
        let speeds = splits.compactMap(speed)
        let lo = speeds.min() ?? 0, hi = speeds.max() ?? 1
        let fastest = speeds.max()
        Grid(alignment: .leading, horizontalSpacing: Space.m, verticalSpacing: 10) {
            GridRow {
                Text(Units.current.km)
                Text(sport == .bike ? Units.current.kmh : L("Pace"))
                Color.clear.frame(height: 1).gridCellUnsizedAxes(.vertical)
                if climb != nil { Text(verbatim: "↑ \(Units.current.m)").gridColumnAlignment(.trailing) }
                Text(verbatim: "♥").gridColumnAlignment(.trailing)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            ForEach(Array(splits.enumerated()), id: \.offset) { i, lap in
                let v = speed(lap)
                GridRow {
                    Text(label(i, lap)).foregroundStyle(.secondary)
                    Text(value(lap)).fontWeight(.semibold)
                    GeometryReader { geo in
                        let f = v.map { hi > lo ? 0.3 + 0.7 * ($0 - lo) / (hi - lo) : 1 } ?? 0
                        Capsule()
                            .fill((v == fastest ? sport.color : sport.color.opacity(0.45)).gradient)
                            .frame(width: geo.size.width * f, height: 10)
                            .frame(maxHeight: .infinity)
                    }
                    .frame(height: 16)
                    if let climb {
                        Text(i < climb.count ? "\(Int(climb[i].rounded()))" : "–").foregroundStyle(.secondary)
                            .gridColumnAlignment(.trailing)
                    }
                    Text(lap.avgHr.map { "\(Int($0))" } ?? "–").foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                }
                .font(.subheadline.monospacedDigit())
            }
        }
    }

    /// Kilometre number; a short last split shows its length ("0.4").
    private func label(_ i: Int, _ lap: Lap) -> String {
        if let d = lap.distanceM, d < 950 {
            return (d / 1000).formatted(.number.precision(.fractionLength(1)))
        }
        return "\(i + 1)"
    }

    private func value(_ lap: Lap) -> String {
        if sport == .bike { return lap.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–" }
        return lap.paceSecPerKm.map(Formats.clock) ?? "–"
    }
}

/// Laps as a compact table: distance, time, pace (or speed), HR, cadence.
struct LapTable: View {
    let laps: [Lap]
    let sport: Sport

    var body: some View {
        Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow {
                Text("#", bundle: .module).gridColumnAlignment(.leading)
                Text("Distance", bundle: .module)
                Text("Time", bundle: .module)
                Text(sport == .bike ? Units.current.kmh : Units.current.perKm)
                Text("♥")
                Text("Cad.", bundle: .module)
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(laps.enumerated()), id: \.offset) { i, lap in
                GridRow {
                    Text("\(i + 1)").foregroundStyle(.secondary)
                    Text(lap.distanceM.map { Formats.distance($0) } ?? "–")
                    Text(Formats.clock(lap.durationSec)).fontWeight(.semibold)
                    Text(sport == .bike ? (lap.speedKmh.map { $0.formatted(.number.precision(.fractionLength(1))) } ?? "–") : (lap.paceSecPerKm.map(Formats.clock) ?? "–"))
                    Text(lap.avgHr.map { "\(Int($0))" } ?? "–")
                    Text(lap.cadence.map { "\(Int($0))" } ?? "–").foregroundStyle(.secondary)
                }
                .font(.subheadline.monospacedDigit())
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Row for unplanned activities in a day.
struct ActivityRow: View {
    let activity: Activity

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.m) {
                SportBadge(sport: activity.sport, subSport: activity.subSport, size: 36, muted: activity.isRecovery)
                VStack(alignment: .leading, spacing: 1) {
                    Eyebrow([activity.sport.title, activity.startLocal].compactMap { $0 }.joined(separator: " · "))
                    Text(activity.title ?? activity.sport.title).font(.headline).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            if !activity.isRecovery { ActivityHeadline(activity: activity, size: 20) }
        }
        .opacity(activity.isRecovery ? 0.7 : 1)
    }
}
