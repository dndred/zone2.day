#if DEBUG
import SwiftUI

struct S1SpikeView: View {
    @StateObject private var spike = S1Spike()

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        Task { await spike.runAll() }
                    } label: {
                        Label(spike.running ? "Running…" : "Run S1 checks", systemImage: "play.circle.fill")
                    }
                    .disabled(spike.running)
                    Button(role: .destructive) {
                        Task { await spike.removeSpikeWorkouts() }
                    } label: {
                        Label("Remove scheduled test workouts", systemImage: "trash")
                    }
                    .disabled(spike.running)
                } footer: {
                    Text("Report: Documents/s1-report.json")
                }
                Section("Results") {
                    ForEach(spike.entries) { e in
                        VStack(alignment: .leading, spacing: 2) {
                            Label(e.step, systemImage: e.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(e.ok ? .green : .red)
                                .font(.subheadline.weight(.semibold))
                            Text(e.detail).font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .navigationTitle("Spike S1")
        }
    }
}
#endif
