import Charts
import SwiftUI
import Zone2Kit

/// The activity's curves in one card: a metric switch (heart rate, pace or speed, power, cadence,
/// elevation), an area chart with the average line, manual intervals shaded, and scrubbing that
/// shows the value at a point. Heart rate is coloured by the athlete's zones. Offline cache only.
struct ActivityChartCard: View {
    let activity: Activity
    let streams: ActivityStreams
    let zones: ZoneSet?
    var plan: [PlanWindow] = []
    @State private var metric: Metric?
    @State private var selected: Double?

    enum Metric: String, CaseIterable, Identifiable {
        case hr, pace, speed, power, cadence, elevation
        var id: String { rawValue }

        var title: String {
            switch self {
            case .hr: L("Heart rate")
            case .pace: L("Pace")
            case .speed: L("Speed")
            case .power: L("Power")
            case .cadence: L("Cadence")
            case .elevation: L("Elevation")
            }
        }

        /// The plan metric drawn on this chart as target bands.
        var targetMetric: Target.Metric? {
            switch self {
            case .hr: .hr
            case .pace: .pace
            case .speed: .speed
            case .power: .power
            case .cadence: .cadence
            case .elevation: nil
            }
        }

        var color: Color {
            switch self {
            case .hr: .heartRate
            case .pace, .speed: .brand
            case .power: .power
            case .cadence: .cadence
            case .elevation: .elevation
            }
        }
    }

    struct Point: Identifiable {
        let id: Int
        let minute: Double
        let value: Double
        /// Run of consecutive samples: a gap (no signal, a stop) starts a new one, so the line
        /// breaks instead of bridging it with a made-up curve.
        let segment: Int
    }

    private func points(_ name: String, transform: (Double) -> Double? = { $0 }) -> [Point] {
        guard let xs = streams.series(name) else { return [] }
        let t = streams.t
        var out: [Point] = []
        var segment = 0, last = -1
        for (i, v) in xs.enumerated() {
            guard let v, i < t.count, let y = transform(v) else { continue }
            if last >= 0 && i - last > 2 { segment += 1 }
            last = i
            out.append(Point(id: i, minute: t[i] / 60, value: y, segment: segment))
        }
        return out
    }

    private func data(_ m: Metric) -> [Point] {
        switch m {
        case .hr: points("heartRate") { $0 > 30 ? $0 : nil }
        // Pace in min/km, faster at the top; stops (< 0.5 m/s) are gaps, not spikes.
        case .pace: points("speed") { $0 > 0.5 ? min(1000 / $0 / 60, 15) : nil }
        case .speed: points("speed") { $0 > 0.5 ? $0 * 3.6 : nil }
        case .power: points(activity.sport == .bike ? "cyclingPower" : "runningPower") { $0 > 0 ? $0 : nil }
        case .cadence: points("cadence") { $0 > 0 ? $0 : nil }
        case .elevation: points("altitude")
        }
    }

    private var available: [Metric] {
        let speedMetric: Metric = activity.sport == .bike ? .speed : .pace
        let order: [Metric] = [.hr, speedMetric, .power, .cadence, .elevation]
        return order.filter { m in
            if m == .pace && !(activity.sport == .run || activity.sport == .other) { return false }
            return data(m).count > 2
        }
    }

    var body: some View {
        let metrics = available
        if let current = metric.flatMap({ metrics.contains($0) ? $0 : nil }) ?? metrics.first {
            let pts = data(current)
            VStack(alignment: .leading, spacing: Space.m) {
                if metrics.count > 1 {
                    // In one row when they fit; else scrolling edge to edge under the card's sides.
                    ViewThatFits(in: .horizontal) {
                        chips(metrics, current)
                        ScrollView(.horizontal, showsIndicators: false) {
                            chips(metrics, current).padding(.horizontal, Space.l)
                        }
                        .padding(.horizontal, -Space.l)
                    }
                }
                readout(current, pts)
                chart(current, pts)
            }
            .card()
            .sensoryFeedback(.selection, trigger: metric)
        }
    }

    private func chips(_ metrics: [Metric], _ current: Metric) -> some View {
        HStack(spacing: Space.s) {
            ForEach(metrics) { m in
                Button {
                    withAnimation(.snappy) { metric = m; selected = nil }
                } label: {
                    Text(m.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(m == current ? Color.white : .primary)
                        .background(Capsule().fill(m == current ? AnyShapeStyle(m.color.gradient) : AnyShapeStyle(Color.secondary.opacity(0.12))))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Readout

    private func format(_ m: Metric, _ v: Double) -> (String, String?) {
        let u = Units.current
        switch m {
        case .hr: return ("\(Int(v.rounded()))", u.bpm)
        case .pace: return (Formats.clock(v * 60), u.perKm)
        case .speed: return (v.formatted(.number.precision(.fractionLength(1))), u.kmh)
        case .power: return ("\(Int(v.rounded()))", u.watt)
        case .cadence: return ("\(Int(v.rounded()))", activity.sport == .bike ? u.rpm : u.spm)
        case .elevation: return ("\(Int(v.rounded()))", u.m)
        }
    }

    private func average(_ m: Metric, _ pts: [Point]) -> Double {
        guard !pts.isEmpty else { return 0 }
        // Pace averages as speed (time-weighted), not as the mean of min/km.
        if m == .pace { return 1 / (pts.map { 1 / $0.value }.reduce(0, +) / Double(pts.count)) }
        return pts.map(\.value).reduce(0, +) / Double(pts.count)
    }

    private func nearest(_ pts: [Point], _ minute: Double) -> Point? {
        pts.min { abs($0.minute - minute) < abs($1.minute - minute) }
    }

    @ViewBuilder
    private func readout(_ m: Metric, _ pts: [Point]) -> some View {
        let avg = average(m, pts)
        let peak = m == .pace ? pts.map(\.value).min() : pts.map(\.value).max()
        HStack(alignment: .lastTextBaseline, spacing: Space.l) {
            if let sel = selected, let p = nearest(pts, sel) {
                let (v, u) = format(m, p.value)
                VStack(alignment: .leading, spacing: 0) {
                    Text(Formats.clock(p.minute * 60)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    StatValue(value: v, unit: u, size: 26, color: color(m, p.value))
                }
            } else {
                let (v, u) = format(m, avg)
                VStack(alignment: .leading, spacing: 0) {
                    Text(L("Average")).font(.caption).foregroundStyle(.secondary)
                    StatValue(value: v, unit: u, size: 26)
                }
                if m == .pace, let gap = activity.summary.analysis?.gapSecPerKm {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("GAP")).font(.caption).foregroundStyle(.secondary)
                        StatValue(value: Formats.clock(gap), unit: Units.current.perKm, size: 18, weight: .medium)
                    }
                }
                if let peak, m != .elevation {
                    let (pv, pu) = format(m, peak)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(m == .pace ? L("Best") : L("Max")).font(.caption).foregroundStyle(.secondary)
                        StatValue(value: pv, unit: pu, size: 18, weight: .medium)
                    }
                } else if m == .elevation, let lo = pts.map(\.value).min(), let hi = pts.map(\.value).max() {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(L("Range")).font(.caption).foregroundStyle(.secondary)
                        StatValue(value: "\(Int(lo))–\(Int(hi))", unit: Units.current.m, size: 18, weight: .medium)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .animation(nil, value: selected)
    }

    private func color(_ m: Metric, _ v: Double) -> Color {
        if m == .hr, let zones { return .zone(zones.displayZone(of: v)) }
        return m.color
    }

    // MARK: Chart

    private var intervals: [Lap] { (activity.summary.intervals?.count ?? 0) > 1 ? activity.summary.intervals! : [] }

    /// Y range: pace and speed ignore the slowest/fastest 2 % so a stop or a GPS jump doesn't flatten the line.
    private func domain(_ m: Metric, _ pts: [Point]) -> ClosedRange<Double> {
        let vs = pts.map(\.value).sorted()
        var lo = vs.first ?? 0, hi = vs.last ?? 1
        // Outliers: a GPS jump, a stop, the first seconds before the strap reads.
        if m != .elevation, vs.count > 20 {
            lo = vs[Int(Double(vs.count) * 0.02)]
            hi = vs[Int(Double(vs.count) * 0.98)]
        }
        let pad = max((hi - lo) * 0.12, m == .elevation ? 5 : m == .pace ? 0.1 : 2)
        return (lo - pad)...(hi + pad)
    }

    /// A piece of the curve drawn in one colour: a run of samples in one zone (heart rate) or
    /// the whole segment. Neighbouring pieces share the boundary sample so the line stays whole.
    struct Piece: Identifiable {
        let id: Int
        let piece: Int
        let zone: Int?
        let minute: Double
        let value: Double
    }

    private func pieces(_ m: Metric, _ pts: [Point]) -> [Piece] {
        let byZone = m == .hr ? zones : nil
        var out: [Piece] = []
        var piece = 0
        var prev: Point?
        var prevZone: Int?
        for p in pts {
            let z = byZone?.displayZone(of: p.value)
            if let q = prev {
                if q.segment != p.segment {
                    piece += 1
                } else if z != prevZone {
                    piece += 1
                    // Repeat the boundary sample at the start of the new piece.
                    out.append(Piece(id: out.count, piece: piece, zone: z, minute: q.minute, value: q.value))
                }
            }
            out.append(Piece(id: out.count, piece: piece, zone: z, minute: p.minute, value: p.value))
            prev = p
            prevZone = z
        }
        return out
    }

    @ViewBuilder
    private func chart(_ m: Metric, _ pts: [Point]) -> some View {
        let dom = withPlan(domain(m, pts), m)
        let reversed = m == .pace
        let base = reversed ? dom.upperBound : dom.lowerBound
        let avg = average(m, pts)
        let fill = LinearGradient(colors: [m.color.opacity(0.3), m.color.opacity(0.02)],
                                  startPoint: reversed ? .bottom : .top, endPoint: reversed ? .top : .bottom)
        let parts = pieces(m, pts)
        Chart {
            // Plan vs fact: each planned step's target as a band behind the curve.
            ForEach(plan.filter { $0.target.metric == m.targetMetric }) { w in
                let band = w.band(m, domain: dom)
                RectangleMark(xStart: .value("from", w.fromMin), xEnd: .value("to", w.toMin),
                              yStart: .value("low", band.lowerBound), yEnd: .value("high", band.upperBound))
                    .foregroundStyle(Color.zone(w.zone).opacity(0.22))
            }
            ForEach(Array(intervals.enumerated()), id: \.offset) { i, lap in
                if i % 2 == 1 {
                    RectangleMark(xStart: .value("from", lap.startSec / 60), xEnd: .value("to", (lap.startSec + lap.durationSec) / 60))
                        .foregroundStyle(Color.secondary.opacity(0.08))
                }
            }
            ForEach(parts) { p in
                AreaMark(x: .value("min", p.minute), yStart: .value("base", base), yEnd: .value(m.title, clamp(p.value, dom)),
                         series: .value("piece", p.piece))
                    .foregroundStyle(p.zone.map { AnyShapeStyle(Color.zone($0).opacity(0.18)) } ?? AnyShapeStyle(fill))
                    .interpolationMethod(.monotone)
            }
            ForEach(parts) { p in
                LineMark(x: .value("min", p.minute), y: .value(m.title, clamp(p.value, dom)), series: .value("piece", p.piece))
                    .foregroundStyle(p.zone.map { Color.zone($0) } ?? m.color)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            if m != .elevation {
                RuleMark(y: .value("avg", avg))
                    .foregroundStyle(Color.primary.opacity(0.35))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
            if let sel = selected, let p = nearest(pts, sel) {
                RuleMark(x: .value("sel", p.minute))
                    .foregroundStyle(Color.primary.opacity(0.25))
                PointMark(x: .value("sel", p.minute), y: .value(m.title, clamp(p.value, dom)))
                    .symbolSize(70)
                    .foregroundStyle(color(m, p.value))
            }
        }
        .chartYScale(domain: reversed ? [dom.upperBound, dom.lowerBound] : [dom.lowerBound, dom.upperBound])
        .chartXScale(domain: 0...(streams.t.last.map { $0 / 60 } ?? 1))
        .chartXSelection(value: $selected)
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { v in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                AxisValueLabel {
                    if let y = v.as(Double.self) {
                        Text(m == .pace ? Formats.clock(y * 60) : m == .speed ? y.formatted(.number.precision(.fractionLength(0))) : String(Int(y.rounded())))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { v in
                AxisValueLabel { if let x = v.as(Double.self) { Text(Formats.clock(x * 60)) } }
            }
        }
        .frame(height: 200)
        .sensoryFeedback(.selection, trigger: selected.map { Int($0) })
    }

    /// Widens the range to hold the plan's closed targets, so a band is never cut by the top.
    private func withPlan(_ dom: ClosedRange<Double>, _ m: Metric) -> ClosedRange<Double> {
        let bands = plan.filter { $0.target.metric == m.targetMetric && $0.target.low != nil && $0.target.high != nil }
            .map { $0.band(m, domain: dom) }
        guard !bands.isEmpty else { return dom }
        let lo = min(dom.lowerBound, bands.map(\.lowerBound).min()!), hi = max(dom.upperBound, bands.map(\.upperBound).max()!)
        let pad = (hi - lo) * 0.04
        return (lo == dom.lowerBound ? lo : lo - pad)...(hi == dom.upperBound ? hi : hi + pad)
    }

    private func clamp(_ v: Double, _ r: ClosedRange<Double>) -> Double { min(max(v, r.lowerBound), r.upperBound) }
}

/// A planned step on the activity's time axis: its target and zone. Only for plans whose steps
/// are all measured in time (a step by distance has no fixed place on a time axis).
struct PlanWindow: Identifiable {
    let id: Int
    let fromMin: Double
    let toMin: Double
    let target: Target
    let zone: Int

    static func windows(_ w: PlannedWorkout, profile: Profile) -> [PlanWindow]? {
        guard let s = w.resolved else { return nil }
        var out: [PlanWindow] = []
        var t = 0.0
        var timed = true
        func add(_ step: Step) {
            guard case .time(let sec) = step.duration else { timed = false; return }
            if let target = step.target, target.unresolved == nil {
                out.append(PlanWindow(id: out.count, fromMin: t / 60, toMin: (t + Double(sec)) / 60, target: target,
                                      zone: Intensity.zone(of: step, sport: w.sport, profile: profile)))
            }
            t += Double(sec)
        }
        for node in s.steps {
            switch node {
            case .step(let step): add(step)
            case .repeats(_, let count, let steps): for _ in 0..<count { steps.forEach(add) }
            }
        }
        return timed && !out.isEmpty ? out : nil
    }

    /// The target in the chart's units; an open side runs to the edge of the chart.
    func band(_ m: ActivityChartCard.Metric, domain: ClosedRange<Double>) -> ClosedRange<Double> {
        func conv(_ v: Double) -> Double {
            switch m {
            case .pace: v / 60
            case .speed: v * 3.6
            default: v
            }
        }
        var lo = target.low.map(conv), hi = target.high.map(conv)
        // Pace: low is the faster bound (fewer seconds per km).
        if m == .pace { swap(&lo, &hi) }
        let a = lo ?? (m == .pace ? domain.upperBound : domain.lowerBound)
        let b = hi ?? (m == .pace ? domain.lowerBound : domain.upperBound)
        return min(a, b)...max(a, b)
    }
}

/// Best average power over 1–60 min (Strava's power curve, HealthFit's mean-maximal power):
/// a curve over the durations, points coloured by power zone when FTP is known, and a table.
struct PowerCurveCard: View {
    let best: [StreamMath.BestPower]
    let zones: ZoneSet?

    private func label(_ sec: Int) -> String {
        sec < 3600 ? "\(sec / 60) \(Units.current.min)" : "\(sec / 3600) \(Units.current.hour)"
    }

    private func color(_ w: Double) -> Color { zones.map { .zone($0.displayZone(of: w)) } ?? .power }

    var body: some View {
        // The range of the curve, not from zero: the drop from 1 to 60 min is what it shows.
        let ws = best.map(\.watts)
        let span = max((ws.max() ?? 1) - (ws.min() ?? 0), 20)
        let lo = max((ws.min() ?? 0) - span * 0.6, 0), hi = (ws.max() ?? 1) + span * 0.25
        VStack(alignment: .leading, spacing: Space.m) {
            Chart {
                ForEach(best, id: \.seconds) { b in
                    AreaMark(x: .value("duration", label(b.seconds)), yStart: .value("base", lo), yEnd: .value("W", b.watts))
                        .foregroundStyle(LinearGradient(colors: [Color.power.opacity(0.25), Color.power.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("duration", label(b.seconds)), y: .value("W", b.watts))
                        .foregroundStyle(Color.power)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
                    PointMark(x: .value("duration", label(b.seconds)), y: .value("W", b.watts))
                        .foregroundStyle(color(b.watts))
                        .symbolSize(40)
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                    AxisValueLabel()
                }
            }
            .chartYScale(domain: lo...hi)
            .frame(height: 150)
            // Two columns of "5 min · 151 W", the bar in the zone's colour.
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Space.l), GridItem(.flexible())], alignment: .leading, spacing: 8) {
                ForEach(best, id: \.seconds) { b in
                    HStack(spacing: Space.s) {
                        Capsule().fill(color(b.watts)).frame(width: 4, height: 16)
                        Text(label(b.seconds)).foregroundStyle(.secondary)
                        Spacer(minLength: 4)
                        Text("\(Int(b.watts.rounded())) \(Units.current.watt)").fontWeight(.semibold)
                    }
                    .font(.subheadline.monospacedDigit())
                }
            }
        }
    }
}
