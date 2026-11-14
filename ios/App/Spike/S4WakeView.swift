#if DEBUG
import SwiftUI

struct S4WakeView: View {
    @State private var events: [WakeMonitor.Event] = []

    var body: some View {
        NavigationStack {
            List {
                Section("By trigger") {
                    ForEach(summary, id: \.0) { trigger, count, last in
                        LabeledContent(trigger) {
                            Text("\(count) · \(last.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption.monospacedDigit())
                        }
                    }
                }
                Section("Last 50") {
                    ForEach(events.suffix(50).reversed()) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(e.trigger) · \(e.state)").font(.subheadline.weight(.semibold))
                            Text("\(e.at.formatted(date: .abbreviated, time: .standard)) · net \(e.net) \(e.ms)ms")
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Spike S4")
            .refreshable { events = WakeMonitor.load() }
            .task { events = WakeMonitor.load() }
        }
    }

    private var summary: [(String, Int, Date)] {
        Dictionary(grouping: events, by: \.trigger)
            .map { ($0.key, $0.value.count, $0.value.map(\.at).max() ?? .distantPast) }
            .sorted { $0.0 < $1.0 }
    }
}
#endif
