import Charts
import SwiftUI
import Zone2Kit

/// Heart rate and pace (bike: speed) over time, plus power when recorded. Manual intervals
/// are shaded so the main effort stands out. Data comes from the offline cache only.
struct ActivityCharts: View {
    let activity: Activity
    let streams: ActivityStreams

    private struct Point: Identifiable {
        let id: Int
        let minute: Double
        let value: Double
    }

    private func points(_ name: String, transform: (Double) -> Double? = { $0 }) -> [Point] {
        guard let xs = streams.series(name) else { return [] }
        let t = streams.t
        return xs.enumerated().compactMap { i, v in
            guard let v, i < t.count, let y = transform(v) else { return nil }
            return Point(id: i, minute: t[i] / 60, value: y)
        }
    }

    private var intervals: [Lap] { (activity.summary.intervals?.count ?? 0) > 1 ? activity.summary.intervals! : [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            let hr = points("heartRate")
            if !hr.isEmpty {
                chart(L("Heart rate"), hr, color: .red, unit: Units.current.bpm)
            }
            if activity.sport == .bike {
                let speed = points("speed") { $0 > 0.5 ? $0 * 3.6 : nil }
                if !speed.isEmpty { chart(L("Speed"), speed, color: activity.sport.color, unit: Units.current.kmh) }
            } else if activity.sport == .run {
                // Pace in min/km, faster at the top; stops (< 0.5 m/s) are gaps, not spikes.
                let pace = points("speed") { $0 > 0.5 ? min(1000 / $0 / 60, 12) : nil }
                if !pace.isEmpty { chart(L("Pace"), pace, color: activity.sport.color, unit: Units.current.perKm, reversed: true) }
            }
            let power = points(activity.sport == .bike ? "cyclingPower" : "runningPower")
            if !power.isEmpty { chart(L("Power"), power, color: .purple, unit: Units.current.watt) }
        }
    }

    @ViewBuilder
    private func chart(_ title: String, _ data: [Point], color: Color, unit: String, reversed: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(title), \(unit)").font(.caption).foregroundStyle(.secondary)
            Chart {
                ForEach(Array(intervals.enumerated()), id: \.offset) { i, lap in
                    if i % 2 == 1 {
                        RectangleMark(xStart: .value("from", lap.startSec / 60), xEnd: .value("to", (lap.startSec + lap.durationSec) / 60))
                            .foregroundStyle(color.opacity(0.08))
                    }
                }
                ForEach(data) { p in
                    LineMark(x: .value("min", p.minute), y: .value(title, p.value))
                        .foregroundStyle(color)
                        .interpolationMethod(.monotone)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false, reversed: reversed))
            .chartYAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel {
                        if let y = v.as(Double.self) {
                            Text(reversed ? Formats.clock(y * 60) : String(Int(y.rounded())))
                        }
                    }
                }
            }
            .chartXAxis {
                AxisMarks { v in
                    AxisGridLine()
                    AxisValueLabel { if let m = v.as(Double.self) { Text(Formats.clock(m * 60)) } }
                }
            }
            .frame(height: 140)
        }
    }
}
