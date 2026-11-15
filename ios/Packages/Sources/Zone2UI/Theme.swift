import SwiftUI
import Zone2Kit

/// Localized string from this package's String Catalog.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}

extension Sport {
    public var symbol: String {
        switch self {
        case .run: "figure.run"
        case .bike: "figure.outdoor.cycle"
        case .swim: "figure.pool.swim"
        case .strength: "figure.strengthtraining.traditional"
        case .other: "figure.mind.and.body"
        }
    }

    public var color: Color {
        switch self {
        case .run: .orange
        case .bike: .green
        case .swim: .cyan
        case .strength: .purple
        case .other: .gray
        }
    }

    static func symbol(_ sport: Sport, subSport: String?) -> String {
        switch subSport {
        case "indoor_bike": "figure.indoor.cycle"
        case "treadmill": "figure.run.treadmill"
        case "walk": "figure.walk"
        case "hike": "figure.hiking"
        default: sport.symbol
        }
    }
}

extension Step.Kind {
    var title: String {
        switch self {
        case .warmup: L("Warm-up")
        case .work: L("Work")
        case .recovery: L("Recovery")
        case .rest: L("Rest")
        case .cooldown: L("Cool-down")
        case .drill: L("Drill")
        }
    }

    /// Bar height in the structure profile (relative intensity by kind).
    var intensity: Double {
        switch self {
        case .work: 1
        case .drill: 0.75
        case .warmup, .cooldown: 0.45
        case .recovery, .rest: 0.28
        }
    }
}

extension WorkoutStatus {
    var title: String {
        switch self {
        case .planned: L("Planned")
        case .done: L("Done")
        case .skipped: L("Skipped")
        case .missed: L("Missed")
        }
    }

    var color: Color {
        switch self {
        case .planned: .secondary
        case .done: .green
        case .skipped: .secondary
        case .missed: .red
        }
    }

    var symbol: String {
        switch self {
        case .planned: "circle"
        case .done: "checkmark.circle.fill"
        case .skipped: "minus.circle"
        case .missed: "xmark.circle"
        }
    }
}

func executionLabel(_ execution: String) -> String? {
    switch execution {
    case "workoutkit": L("Workout app on watch")
    case "zone2_watch": L("zone2 on watch")
    case "mywhoosh": "MyWhoosh"
    default: nil
    }
}

extension LocalDate {
    /// "Today", "Tomorrow" or "Mon 16 Nov".
    func relativeTitle(today: LocalDate) -> String {
        if self == today { return L("Today") }
        if self == today.adding(days: 1) { return L("Tomorrow") }
        if self == today.adding(days: -1) { return L("Yesterday") }
        return formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }
}

/// Small rounded label (status, kind).
struct Chip: View {
    let text: String
    var color: Color = .secondary

    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
    }
}

// iOS-only APIs behind helpers, so the package still builds for `swift test` on macOS.
extension View {
    func inlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

extension Color {
    /// Card on a grouped background (white in light mode, raised gray in dark).
    static var card: Color {
        #if os(iOS)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    static var groupedBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }
}
