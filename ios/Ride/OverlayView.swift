import SwiftUI
import TrainerKit
import Zone2Kit

struct OverlayView: View {
    var model: RideModel
    @AppStorage("opacity") private var opacity = 0.85
    @State private var hover = false

    private var account: RideAccount { model.account }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            plan
            // Three equal columns, unit under the number: three-digit power and heart rate must fit
            // side by side (they were truncated to "…" in one row with the units).
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                metric(model.power.map(String.init), unit: "W", color: color(model.power, for: .power) ?? .primary)
                metric(model.heartRate.map(String.init), unit: "bpm", color: color(model.heartRate, for: .hr) ?? .red)
                metric(model.cadence.map(String.init), unit: "rpm", color: color(model.cadence, for: .cadence) ?? .secondary)
            }
            HStack(spacing: 10) {
                Text(Formats.clock(Double(model.recorder.elapsed)))
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
            footer
        }
        .padding(12)
        .frame(width: 320)
        .background(.ultraThinMaterial.opacity(opacity), in: RoundedRectangle(cornerRadius: 14))
        .background(Color.black.opacity(opacity * 0.35), in: RoundedRectangle(cornerRadius: 14))
        .onHover { hover = $0 }
        .contextMenu { menu }
    }

    // MARK: Plan

    @ViewBuilder private var plan: some View {
        if model.state == .idle {
            picker
        } else if let p = model.player {
            if let step = p.current {
                stepCard(p, step)
            } else {
                Label("Plan done — ride on or stop", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.green)
            }
        } else if let w = model.chosen {
            Label(w.workout.title, systemImage: "calendar").font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    @ViewBuilder private var picker: some View {
        if !account.signedIn {
            Button("Sign in to load the plan") { Task { await account.signIn() } }
                .buttonStyle(.link).font(.caption)
        } else {
            Menu {
                ForEach(account.workouts) { item in
                    Button { model.choose(item) } label: {
                        Text(pickerTitle(item))
                    }
                }
                if account.workouts.isEmpty { Text("No bike workouts this week") }
                Divider()
                Button("Free ride") { model.choose(nil) }
                Button("Refresh plan") { Task { await account.refresh() } }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: model.workout == nil ? "bicycle" : "calendar")
                    Text(model.workout.map(pickerTitle) ?? String(localized: "Free ride")).lineLimit(1)
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
            if let w = model.workout?.workout, let line = summary(w) {
                Text(line).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func stepCard(_ p: StepPlayer, _ step: PlayStep) -> some View {
        let elapsed = model.recorder.elapsed
        let inStep = p.stepElapsed(elapsed)
        let left: String = if let s = p.remaining(elapsed) {
            Formats.clock(Double(s))
        } else if let m = p.remainingM(model.recorder.distanceM) {
            Formats.distance(m)
        } else {
            Formats.clock(Double(inStep))
        }
        let fraction: Double? = switch step.duration {
        case .time(let sec): Double(inStep) / Double(max(sec, 1))
        case .distance(let m): p.remainingM(model.recorder.distanceM).map { 1 - $0 / m }
        case .open: nil
        }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(stepName(step)).font(.headline).lineLimit(1)
                    if let t = step.target, t.unresolved == nil {
                        Text(([t] + step.secondary).filter { $0.unresolved == nil }.map { Formats.target($0, sport: .bike) }.joined(separator: " · "))
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    } else if let note = step.note {
                        Text(note).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Text(left)
                    .font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(p.remaining(elapsed).map { $0 <= 3 } == true ? .orange : .primary)
                    .contentTransition(.numericText())
            }
            if let fraction { ProgressView(value: min(max(fraction, 0), 1)).progressViewStyle(.linear).tint(tint(step)) }
            HStack(spacing: 6) {
                if let n = p.next {
                    Text("Next: \(nextLine(n))").lineLimit(1)
                } else {
                    Text("Last step")
                }
                Spacer(minLength: 0)
                Button { model.nextStep() } label: {
                    Image(systemName: "forward.end.fill")
                }
                .buttonStyle(.borderless)
                .help("Next step")
            }
            .font(.caption2).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var footer: some View {
        if model.lastSaved != nil || model.saveError != nil || account.upload != nil {
            HStack(spacing: 6) {
                switch account.upload {
                case .sending: ProgressView().controlSize(.mini); Text("Sending…")
                case .sent(let planned):
                    Image(systemName: "checkmark.icloud").foregroundStyle(.green)
                    if let planned { Text("Sent: \(planned)").lineLimit(1) } else { Text("Sent") }
                case .failed(let e): Image(systemName: "exclamationmark.icloud").foregroundStyle(.orange); Text(e).lineLimit(2)
                case nil: EmptyView()
                }
                Spacer(minLength: 0)
                if model.lastSaved != nil {
                    Button("Finder") { model.revealRides() }.buttonStyle(.link)
                }
            }
            .font(.caption2).foregroundStyle(.secondary)
            if let e = model.saveError { Text(e).font(.caption2).foregroundStyle(.orange) }
        }
        if let e = account.error, model.state == .idle {
            Text(e).font(.caption2).foregroundStyle(.orange).lineLimit(2)
        }
    }

    @ViewBuilder private var menu: some View {
        if account.signedIn {
            Text("Signed in: \(account.name ?? "zone2")\(account.isStaging ? " (staging)" : "")")
            Button("Refresh plan") { Task { await account.refresh() } }
            Button("Send unsent rides") { Task { await account.uploadPending() } }
            Button("Sign out") { Task { await account.signOut() } }
        } else {
            Button("Sign in…") { Task { await account.signIn() } }
        }
        Divider()
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

    // MARK: Pieces

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

    /// Against the current step's target: blue below, green inside, orange above (±3 % slack).
    private func color(_ value: Int?, for metric: Target.Metric) -> Color? {
        guard let value, model.state != .idle, let step = model.player?.current,
              let t = ([step.target] + step.secondary).compactMap({ $0 }).first(where: { $0.metric == metric && $0.unresolved == nil })
        else { return nil }
        let v = Double(value)
        if let low = t.low, v < low * 0.97 { return .blue }
        if let high = t.high, v > high * 1.03 { return .orange }
        return .green
    }

    private func tint(_ s: PlayStep) -> Color {
        switch s.kind {
        case .work: .orange
        case .warmup, .cooldown: .blue
        default: .gray
        }
    }

    private func stepName(_ s: PlayStep) -> String {
        var name = s.label ?? kindName(s.kind)
        if let rep = s.rep, let reps = s.reps { name += " \(rep)/\(reps)" }
        return name
    }

    private func kindName(_ k: Step.Kind) -> String {
        switch k {
        case .warmup: String(localized: "Warm-up")
        case .work: String(localized: "Work")
        case .recovery: String(localized: "Recovery")
        case .rest: String(localized: "Rest")
        case .cooldown: String(localized: "Cool-down")
        case .drill: String(localized: "Drill")
        }
    }

    private func nextLine(_ s: PlayStep) -> String {
        var parts = [stepName(s)]
        if let d = Formats.duration(s.duration) { parts.append(d) }
        if let t = s.target, t.unresolved == nil { parts.append(Formats.target(t, sport: .bike)) }
        return parts.joined(separator: " · ")
    }

    private func pickerTitle(_ item: PlannedItem) -> String {
        let w = item.workout
        let day: String = switch account.today.days(until: w.date) {
        case 0: String(localized: "today")
        case 1: String(localized: "tomorrow")
        case -1: String(localized: "yesterday")
        default: w.date.formatted(.dateTime.weekday(.abbreviated).day())
        }
        return "\(w.title) · \(day)\(item.status == .done ? " ✓" : "")"
    }

    /// "1 h 05 min · 4 × (4 min 250–265 W)" — length and the work steps.
    private func summary(_ w: PlannedWorkout) -> String? {
        let plan = RidePlan(w)
        guard !plan.steps.isEmpty else { return w.goal }
        var parts = [Formats.hoursMinutes(Double(plan.plannedSec))]
        if let work = plan.steps.first(where: { $0.kind == .work }) {
            var s = (work.reps.map { "\($0) × " } ?? "") + (Formats.duration(work.duration) ?? "")
            if let t = work.target, t.unresolved == nil { s += " " + Formats.target(t, sport: .bike) }
            parts.append(s)
        }
        return parts.joined(separator: " · ")
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
}
