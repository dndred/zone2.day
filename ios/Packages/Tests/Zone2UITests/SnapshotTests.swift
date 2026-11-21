import Foundation
import SwiftUI
import Testing
import Zone2Kit
@testable import Zone2UI

// Snapshot tests of the design system's components (docs/08-dev-harness.md: PNGs in the repo, the
// agent opens them and sees the UI). iOS only: run with `just snapshots` (iOS simulator); on macOS
// `swift test` skips them. Data: the demo feed (fixtures/sync/demo-feed.json) on 17 Nov 2026,
// a synthetic heart-rate/speed curve, the athlete's real zone layout.
// Missing reference → written; `just snapshots-update` rewrites all; a mismatch writes
// `<name>.failed.png` next to the reference.

#if os(iOS)
import UIKit

private let snapshotsDir = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "__Snapshots__")
private let repoRoot = URL(filePath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

@MainActor
private enum Fixture {
    static let profile: Profile = {
        let json = #"{"timezone":"Asia/Barnaul","run":{"maxHr":186,"hrZones":[140,153,162,172],"lthr":{"low":167,"high":171,"basis":"Progressive parkruns, June 2026"},"thresholdPaceSecPerKm":{"low":295,"high":310}},"bike":{"ftp":200}}"#
        return try! JSONDecoder().decode(Profile.self, from: Data(json.utf8))
    }()

    /// The demo week as the app sees it on Tuesday 17 Nov 2026, 12:00 in Barnaul.
    static let snap: PlanSnapshot = {
        let data = try! Data(contentsOf: repoRoot.appending(path: "fixtures/sync/demo-feed.json"))
        let page = try! JSONDecoder().decode(SyncPage.self, from: data)
        let store = try! LocalStore()
        try! store.apply(page)
        let now = ISO8601DateFormatter().date(from: "2026-11-17T05:00:00Z")!
        let monday = LocalDate("2026-11-09")!
        return try! store.snapshot(from: monday, to: monday.adding(days: 13), now: now)
    }()

    /// The demo store with the run's curves cached, as screens read them.
    static let store: LocalStore = {
        let data = try! Data(contentsOf: repoRoot.appending(path: "fixtures/sync/demo-feed.json"))
        let store = try! LocalStore()
        try! store.apply(try! JSONDecoder().decode(SyncPage.self, from: data))
        try! store.saveStreams(streams, activityId: "a-park")
        return store
    }()

    static let context = PlanContext(store: store, refresh: {})

    /// The same data, but the curves are still on their way (a slow network).
    static let loadingContext: PlanContext = {
        let data = try! Data(contentsOf: repoRoot.appending(path: "fixtures/sync/demo-feed.json"))
        let store = try! LocalStore()
        try! store.apply(try! JSONDecoder().decode(SyncPage.self, from: data))
        return PlanContext(store: store, refresh: {}, loadStreams: { _ in try? await Task.sleep(for: .seconds(30)) })
    }()

    static func item(_ id: String) -> PlannedItem {
        snap.days.flatMap(\.planned).first { $0.id == id }!
    }

    static func activity(_ id: String) -> Activity {
        snap.days.flatMap { $0.planned.flatMap(\.activities) + $0.unplanned }.first { $0.id == id }!
    }

    /// Warm-up, a 25-minute effort, cool-down; a 3-minute gap without heart rate.
    static let streams: ActivityStreams = {
        let n = 300, dur = 5191.0
        let t = (0..<n).map { Double($0) * dur / Double(n) }
        func effort(_ x: Double) -> Bool { x >= 2408 && x < 3934 }
        let hr: [Double?] = t.map { x in
            if x > 900 && x < 1080 { return nil }
            return effort(x) ? 150 + 18 * min((x - 2408) / 900, 1) + 2 * sin(x / 60) : 128 + 8 * sin(x / 300) + (x > 3934 ? 8 : 0)
        }
        let speed: [Double?] = t.map { x in effort(x) ? 3.6 + 0.1 * sin(x / 90) : 2.75 + 0.15 * sin(x / 200) }
        let power: [Double?] = speed.map { $0.map { $0 * 72 } }
        let none = [Double?](repeating: nil, count: n)
        return ActivityStreams(bucketSec: dur / Double(n), columns: ["t": t, "heartRate": hr, "speed": speed, "runningPower": power,
                                                                     "lat": none, "lon": none])
    }()
}

@MainActor
private func assertSnapshot<V: View>(_ view: V, _ name: String, width: CGFloat = 402,
                                     size: DynamicTypeSize = .large) throws {
    for scheme in [ColorScheme.light, .dark] {
        let file = "\(name)-\(scheme == .light ? "light" : "dark")\(size == .large ? "" : "-xxxl")"
        let content = view
            .padding(16)
            .frame(width: width)
            .background(Color(uiColor: .systemGroupedBackground))
            .environment(\.colorScheme, scheme)
            .environment(\.dynamicTypeSize, size)
            .environment(\.athleteProfile, Fixture.profile)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let png = try #require(renderer.uiImage?.pngData(), "render \(file)")
        try record(png, file)
    }
}

/// A whole screen as on the phone: a real hosting controller in a window as tall as the screen's
/// content (navigation bar, scroll view and charts included), after its tasks have loaded data.
@MainActor
private func assertScreen<V: View>(_ view: V, _ name: String, height: CGFloat = 2200,
                                    context: PlanContext = Fixture.context) async throws {
    for scheme in [ColorScheme.light, .dark] {
        let file = "screen-\(name)-\(scheme == .light ? "light" : "dark")"
        let host = UIHostingController(rootView: view
            .environment(\.athleteProfile, Fixture.profile)
            .environment(\.planContext, context))
        host.overrideUserInterfaceStyle = scheme == .light ? .light : .dark
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 402, height: height))
        window.overrideUserInterfaceStyle = host.overrideUserInterfaceStyle
        window.rootViewController = host
        window.isHidden = false
        // Let `.task` observations deliver the store's data and charts lay out.
        for _ in 0..<12 {
            try await Task.sleep(for: .milliseconds(100))
            host.view.setNeedsLayout()
            host.view.layoutIfNeeded()
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        // No window scene in a hostless test run, so render the layer tree rather than the screen.
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { ctx in
            window.layer.render(in: ctx.cgContext)
        }
        window.isHidden = true
        try record(try #require(image.pngData()), file)
    }
}

/// Writes a missing reference (or all with UPDATE_SNAPSHOTS), else compares with it.
private func record(_ png: Data, _ file: String) throws {
    let url = snapshotsDir.appending(path: "\(file).png")
    let failed = snapshotsDir.appending(path: "\(file).failed.png")
    try? FileManager.default.removeItem(at: failed)
    try FileManager.default.createDirectory(at: snapshotsDir, withIntermediateDirectories: true)
    if ProcessInfo.processInfo.environment["UPDATE_SNAPSHOTS"] != nil || !FileManager.default.fileExists(atPath: url.path()) {
        try png.write(to: url)
        return
    }
    let reference = try Data(contentsOf: url)
    if let diff = difference(png, reference), diff > 0.002 {
        try png.write(to: failed)
        Issue.record("\(file): \(String(format: "%.2f", diff * 100)) % of pixels differ, see \(failed.lastPathComponent)")
    }
}

/// Share of pixels that differ noticeably; nil when sizes match exactly and so do bytes.
private func difference(_ a: Data, _ b: Data) -> Double? {
    if a == b { return nil }
    guard let ia = UIImage(data: a)?.cgImage, let ib = UIImage(data: b)?.cgImage else { return 1 }
    guard ia.width == ib.width, ia.height == ib.height else { return 1 }
    func rgba(_ img: CGImage) -> [UInt8] {
        var buf = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &buf, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return buf
    }
    let pa = rgba(ia), pb = rgba(ib)
    var differing = 0
    for i in stride(from: 0, to: pa.count, by: 4) where
        abs(Int(pa[i]) - Int(pb[i])) + abs(Int(pa[i + 1]) - Int(pb[i + 1])) + abs(Int(pa[i + 2]) - Int(pb[i + 2])) > 24 {
        differing += 1
    }
    return Double(differing) / Double(pa.count / 4)
}

@Suite(.serialized) @MainActor struct Snapshots {
    @Test func workoutCards() throws {
        try assertSnapshot(WorkoutCard(item: Fixture.item("w-bike"), expanded: true, onWatch: false), "workout-card-planned")
        try assertSnapshot(WorkoutCard(item: Fixture.item("w-park"), expanded: true), "workout-card-done")
        try assertSnapshot(WorkoutCard(item: Fixture.item("w-skip"), expanded: false), "workout-card-skipped")
        try assertSnapshot(WorkoutCard(item: Fixture.item("w-bike"), expanded: true), "workout-card-planned", size: .xxxLarge)
    }

    @Test func week() throws {
        try assertSnapshot(WeekCard(snap: Fixture.snap), "week-card")
        let start = LocalDate("2026-11-16")!
        let days = Fixture.snap.days.filter { $0.date.weekStart == start }
        // The calendar's rows without their links (ImageRenderer can't draw a NavigationStack,
        // and links outside one render disabled).
        try assertSnapshot(VStack(alignment: .leading, spacing: 12) {
            WeekVolumeChips(days: Fixture.snap.days.filter { $0.date.weekStart == LocalDate("2026-11-09")! })
            VStack(alignment: .leading, spacing: 12) {
                ForEach(days.flatMap(\.planned)) { item in
                    DayItemRow(sport: item.workout.sport, subSport: item.workout.subSport, title: item.workout.title,
                               subtitle: item.workout.skipped?.reason, key: item.workout.key,
                               muted: item.status == .skipped) { StatusBadge(status: item.status).font(.title3) }
                }
            }
            .card()
        }, "calendar-rows")
    }

    @Test func plan() throws {
        let w = Fixture.item("w-bike").workout
        try assertSnapshot(VStack(alignment: .leading, spacing: 16) {
            StructureBar(structure: w.resolved!, sport: w.sport, height: 84, showsAxis: true)
            PlanStats(estimate: PlanEstimate(w.resolved!, sport: w.sport), sport: w.sport, size: 24)
        }.card(), "plan-structure")
        try assertSnapshot(StepList(structure: w.resolved!, sport: w.sport).card(), "plan-steps")
    }

    @Test func activity() throws {
        let a = Fixture.activity("a-park")
        try assertSnapshot(ActivityResultCard(activity: a), "activity-result")
        try assertSnapshot(ActivityChartCard(activity: a, streams: Fixture.streams, zones: Fixture.profile.hrZones(for: .run)),
                           "activity-chart-hr")
        let zones = Fixture.profile.hrZones(for: .run)!
        try assertSnapshot(ZoneDistribution(zones: zones, seconds: zones.seconds(in: Fixture.streams.series("heartRate")!,
                                                                                    bucketSec: Fixture.streams.bucketSec)).card(),
                           "activity-zones")
        let splits = a.laps.filter { $0.kind == "split_km" }
        if splits.count > 1 { try assertSnapshot(SplitsView(splits: splits, sport: .run).card(), "activity-splits") }
        if let laps = a.summary.intervals { try assertSnapshot(LapTable(laps: laps, sport: .run).card(), "activity-intervals") }
    }

    @Test func screens() async throws {
        try await assertScreen(NavigationStack { PlannedWorkoutView(item: Fixture.item("w-bike")) }, "planned-workout", height: 1500)
        try await assertScreen(NavigationStack { ActivityView(activity: Fixture.activity("a-park")) }, "activity", height: 2600)
        // While the curves load, placeholders hold the blocks' places: the sections below the
        // chart sit where they will be once loaded (compare with screen-activity).
        try await assertScreen(NavigationStack { ActivityView(activity: Fixture.activity("a-park")) }, "activity-loading",
                               height: 2600, context: Fixture.loadingContext)
    }

    @Test func fitness() throws {
        // 12 weeks of 3 build weeks + 1 easy week; long run on Sundays.
        let start = LocalDate("2026-08-31")!
        var loads: [LocalDate: Double] = [:]
        for i in 0..<84 {
            let d = start.adding(days: i), week = i / 7, weekday = i % 7
            guard weekday != 4 else { continue }
            let base = (week % 4 == 3 ? 40.0 : 60.0 + Double(week) * 3)
            loads[d] = weekday == 6 ? base * 2.2 : base
        }
        try assertSnapshot(FitnessCard(days: Fitness.series(loads: loads, to: start.adding(days: 83))), "fitness")
    }

    @Test func powerCurve() throws {
        // A ride: 10 min warm-up, 3 × (8 min at 230 W / 4 min at 140 W), cool-down; 10-s buckets.
        var watts: [Double?] = Array(repeating: 130, count: 60)
        for _ in 0..<3 { watts += Array(repeating: 230, count: 48) + Array(repeating: 140, count: 24) }
        watts += Array(repeating: 110, count: 30)
        let s = ActivityStreams(bucketSec: 10, columns: ["t": watts.indices.map { Double($0) * 10 }, "cyclingPower": watts])
        try assertSnapshot(PowerCurveCard(best: StreamMath.bestPower(s, channel: "cyclingPower"),
                                          zones: Fixture.profile.powerZones(for: .bike)).card(), "power-curve")
        let a = Fixture.activity("a-park")
        try assertSnapshot(SplitsView(splits: a.laps.filter { $0.kind == "split_km" }, sport: .run, climb: [4, 18, 2, 11, 0]).card(),
                           "activity-splits-climb")
    }

    @Test func zones() throws {
        try assertSnapshot(ZoneTable(zones: Fixture.profile.hrZones(for: .run)!, maxHr: 186, unit: "bpm").card(), "zones-hr")
        try assertSnapshot(ZoneTable(zones: Fixture.profile.powerZones(for: .bike)!, maxHr: nil, unit: "W").card(), "zones-power")
    }
}
#endif
