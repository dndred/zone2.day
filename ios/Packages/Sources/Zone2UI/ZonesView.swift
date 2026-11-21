import SwiftUI
import Zone2Kit

/// Thresholds and zones (Profile, docs/07-ios-app.md §3.6): read-only, set by the coach. Each
/// threshold with its range and basis; heart-rate zones as a scale and a table; bike power zones
/// from FTP; swim CSS. Zones are built as on the server (Zone2Kit/Zones.swift).
public struct ZonesView: View {
    let store: LocalStore
    @State private var profile = Profile()
    @State private var loaded = false

    public init(store: LocalStore) { self.store = store }

    public static var title: String { L("Thresholds & zones") }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.l) {
                let run = thresholdStats(profile.run, sport: .run)
                if !run.isEmpty || profile.hrZones(for: .run) != nil {
                    sportHeader(.run)
                    if !run.isEmpty { thresholdCard(run) }
                    if let z = profile.hrZones(for: .run) { ZoneTable(zones: z, maxHr: profile.run.maxHr, unit: Units.current.bpm).card() }
                }
                let bike = thresholdStats(profile.bike, sport: .bike)
                let power = profile.powerZones(for: .bike)
                if !bike.isEmpty || power != nil || profile.bike.hrZones != nil {
                    sportHeader(.bike)
                    if !bike.isEmpty { thresholdCard(bike) }
                    if let power { ZoneTable(zones: power, maxHr: nil, unit: Units.current.watt).card() }
                    if let z = profile.bike.hrZones, !z.isEmpty {
                        ZoneTable(zones: ZoneSet(metric: .hr, bounds: z), maxHr: profile.bike.maxHr, unit: Units.current.bpm).card()
                    }
                }
                let swim = thresholdStats(profile.swim, sport: .swim)
                if !swim.isEmpty {
                    sportHeader(.swim)
                    thresholdCard(swim)
                }
                Text("Thresholds and zones are set by the coach; ask in the chat to change them.", bundle: .module)
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, Space.xs)
            }
            .padding(.horizontal, Space.l)
            .padding(.bottom, Space.xl)
            .opacity(loaded ? 1 : 0)
        }
        .background(Color.groupedBackground)
        .overlay {
            if !loaded {
                ProgressView()
            } else if profile.hrZones(for: .run) == nil && thresholdStats(profile.run, sport: .run).isEmpty
                && thresholdStats(profile.bike, sport: .bike).isEmpty {
                ContentUnavailableView(L("No thresholds yet"), systemImage: "heart.text.clipboard")
            }
        }
        .navigationTitle(Self.title)
        .inlineTitle()
        .task {
            do {
                for try await p in store.observeProfile() { profile = p; loaded = true }
            } catch {}
        }
    }

    private func sportHeader(_ sport: Sport) -> some View {
        HStack(spacing: Space.m) {
            SportBadge(sport: sport, size: 30)
            Text(sport.title).font(.title3.weight(.bold))
        }
        .padding(.top, Space.s)
    }

    struct ThresholdStat: Identifiable {
        let label: String
        let value: String
        let unit: String?
        let basis: String?
        var id: String { label }
    }

    private func thresholdStats(_ p: Profile.SportProfile, sport: Sport) -> [ThresholdStat] {
        let u = Units.current
        func range(_ key: String, _ f: (Double) -> String) -> (String, String?)? {
            guard let t = p.detail[key] else { return nil }
            if let lo = t.low, let hi = t.high, lo != hi { return ("\(f(lo))–\(f(hi))", t.basis) }
            return (f(t.value), t.basis)
        }
        let int = { (x: Double) in "\(Int(x.rounded()))" }
        var out: [ThresholdStat] = []
        if let (v, b) = range("lthr", int) { out.append(ThresholdStat(label: L("Threshold heart rate"), value: v, unit: u.bpm, basis: b)) }
        if let (v, b) = range("thresholdPaceSecPerKm", Formats.clock) { out.append(ThresholdStat(label: L("Threshold pace"), value: v, unit: u.perKm, basis: b)) }
        if let (v, b) = range("ftp", int) { out.append(ThresholdStat(label: "FTP", value: v, unit: u.watt, basis: b)) }
        if let (v, b) = range("cssSecPer100m", Formats.clock) { out.append(ThresholdStat(label: "CSS", value: v, unit: u.per100m, basis: b)) }
        if let m = p.maxHr { out.append(ThresholdStat(label: L("Max heart rate"), value: int(m), unit: u.bpm, basis: nil)) }
        if let r = p.restingHr { out.append(ThresholdStat(label: L("Resting heart rate"), value: int(r), unit: u.bpm, basis: nil)) }
        return out
    }

    private func thresholdCard(_ stats: [ThresholdStat]) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(stats.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                VStack(alignment: .leading, spacing: 4) {
                    StatTile(label: s.label, value: s.value, unit: s.unit, size: 26)
                    if let basis = s.basis {
                        Text(basis).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .card()
    }
}

/// Zones as a coloured scale (width = range of the zone) and rows: name, range.
struct ZoneTable: View {
    let zones: ZoneSet
    /// Top of the scale for heart rate; power's last zone gets the width of the one before it.
    let maxHr: Double?
    let unit: String

    private func name(_ z: Int) -> String {
        if zones.count == 7 {
            return [L("Active recovery"), L("Endurance"), L("Tempo"), L("Threshold"), L("VO₂max"), L("Anaerobic"), L("Neuromuscular")][z - 1]
        }
        let five = [L("Recovery zone"), L("Aerobic base"), L("Tempo"), L("Threshold"), L("VO₂max")]
        return z - 1 < five.count ? five[z - 1] : "Z\(z)"
    }

    var body: some View {
        let b = zones.bounds
        let step = b.count > 1 ? b[b.count - 1] - b[b.count - 2] : 10
        let lo = max((b.first ?? 0) - step * 1.5, 0)
        let hi = max(maxHr ?? ((b.last ?? 0) + step), (b.last ?? 0) + 1)
        let edges = [lo] + b + [hi]
        VStack(alignment: .leading, spacing: Space.m) {
            Eyebrow(zones.metric == .hr ? L("Heart rate zones") : L("Power zones"))
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(1...zones.count, id: \.self) { z in
                        let w = (edges[z] - edges[z - 1]) / (hi - lo)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.zone(min(z, 5)).gradient)
                            .opacity(z > 5 ? 0.6 + 0.2 * Double(7 - z) : 1)
                            .frame(width: max(geo.size.width * w - 2, 4))
                    }
                }
            }
            .frame(height: 14)
            VStack(spacing: 0) {
                ForEach(1...zones.count, id: \.self) { z in
                    if z > 1 { Divider().padding(.leading, 44) }
                    HStack(spacing: Space.m) {
                        Text(verbatim: "Z\(z)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 32, height: 22)
                            .background(Color.zone(min(z, 5)).gradient.opacity(z > 5 ? 0.6 + 0.2 * Double(7 - z) : 1),
                                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                        Text(name(z)).font(.subheadline)
                        Spacer()
                        Text(range(z)).font(.subheadline.weight(.semibold).monospacedDigit())
                    }
                    .padding(.vertical, 8)
                }
            }
        }
    }

    private func range(_ z: Int) -> String {
        let r = zones.range(of: z)
        switch (r.low, r.high) {
        case let (nil, h?): return "< \(Int(h) + 1) \(unit)"
        case let (l?, nil): return "≥ \(Int(l)) \(unit)"
        case let (l?, h?): return "\(Int(l))–\(Int(h)) \(unit)"
        default: return ""
        }
    }
}
