import SwiftUI
import TrainerKit

struct OverlayView: View {
    var model: RideModel
    @AppStorage("opacity") private var opacity = 0.85
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Three equal columns, unit under the number: three-digit power and heart rate must fit
            // side by side (they were truncated to "…" in one row with the units).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                metric(model.power.map(String.init), unit: "W", color: .primary)
                metric(model.heartRate.map(String.init), unit: "bpm", color: .red)
                metric(model.cadence.map(String.init), unit: "rpm", color: .secondary)
            }
            HStack(spacing: 10) {
                Text(clock(model.recorder.elapsed))
                    .font(.system(.title3, design: .rounded).monospacedDigit().weight(.medium))
                    .foregroundStyle(model.state == .paused ? .orange : .primary)
                if let avg = model.recorder.averagePower {
                    Text("avg \(avg) W").foregroundStyle(.secondary)
                }
                if let np = model.recorder.normalizedPower {
                    Text("NP \(np)").foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                controls.opacity(hover || model.state != .recording ? 1 : 0.25)
            }
            .font(.caption.monospacedDigit())
            HStack(spacing: 10) {
                status(model.link.trainer, icon: "bicycle", empty: String(localized: "Turn the trainer on"))
                status(model.link.heart, icon: "heart", empty: String(localized: "Start HeartCast"))
                Spacer(minLength: 0)
            }
            .font(.caption2)
            if model.lastSaved != nil {
                Button("Saved — show in Finder") { model.revealRides() }
                    .buttonStyle(.link).font(.caption2)
            }
            if let e = model.saveError { Text(e).font(.caption2).foregroundStyle(.orange) }
        }
        .padding(12)
        .frame(width: 320)
        .background(.ultraThinMaterial.opacity(opacity), in: RoundedRectangle(cornerRadius: 14))
        .background(Color.black.opacity(opacity * 0.35), in: RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .contextMenu {
            Menu("Opacity") {
                ForEach([1.0, 0.85, 0.6, 0.4], id: \.self) { v in
                    Button("\(Int(v * 100)) %") { opacity = v }
                }
            }
            Button("Find devices again") { model.link.reset() }
            Button("Open rides folder") { model.revealRides() }
            if model.state != .idle { Button("Discard ride", role: .destructive) { model.discard() } }
            Divider()
            Button("Quit") { NSApplication.shared.terminate(nil) }
        }
    }

    private func metric(_ value: String?, unit: String, color: Color) -> some View {
        VStack(spacing: 0) {
            Text(value ?? "--")
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(value == nil ? .secondary : color)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .contentTransition(.numericText())
            Text(unit).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var controls: some View {
        HStack(spacing: 6) {
            switch model.state {
            case .idle:
                Button { model.start() } label: { Image(systemName: "record.circle") }
                    .help("Start recording")
            case .recording:
                Button { model.pause() } label: { Image(systemName: "pause.fill") }.help("Pause")
                Button { model.stop() } label: { Image(systemName: "stop.fill") }.help("Stop and save")
            case .paused:
                Button { model.start() } label: { Image(systemName: "play.fill") }.help("Resume")
                Button { model.stop() } label: { Image(systemName: "stop.fill") }.help("Stop and save")
            }
        }
        .buttonStyle(.borderless)
        .font(.body)
    }

    private func status(_ s: TrainerLink.Status, icon: String, empty: String) -> some View {
        let (text, color): (String, Color) = switch s {
        case .off: (String(localized: "Bluetooth off"), .orange)
        case .searching: (empty, .orange)
        case let .connecting(n): (n, .yellow)
        case let .connected(n): (n, .green)
        }
        return Label {
            Text(text).lineLimit(1).truncationMode(.middle)
        } icon: {
            Image(systemName: icon).foregroundStyle(color)
        }
        .foregroundStyle(.secondary)
    }

    private func clock(_ s: Int) -> String {
        s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}
