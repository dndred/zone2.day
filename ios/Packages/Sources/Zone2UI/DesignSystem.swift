import SwiftUI
import Zone2Kit

// Design system (docs/07-ios-app.md §4): one zone scale, sport colours, cards, big numbers with
// small units, section titles. Screens compose these instead of styling ad hoc.

// MARK: - Tokens

enum Space {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
}

enum Radius {
    static let card: CGFloat = 22
    static let inner: CGFloat = 14
    static let bar: CGFloat = 3
}

extension Color {
    /// Hex colour that may differ in dark mode (brighter, so it holds contrast on black).
    init(light: UInt32, dark: UInt32? = nil) {
        #if os(iOS)
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? (dark ?? light) : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
        #else
        let hex = light
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
        #endif
    }

    /// Brand orange #FF5A1F (International Orange, as on Apple Watch Ultra). Same value as the
    /// app's AccentColor asset; a token so the package (snapshot tests, previews) doesn't depend on it.
    static let brand = Color(light: 0xFF5A1F)

    /// Zone scale Z1–Z5 shared by plan profiles, charts and zone bars: grey, blue, green, amber,
    /// red. Z4 leans amber so it never reads as the brand orange.
    static func zone(_ z: Int) -> Color {
        switch z {
        case ...1: Color(light: 0x98A2B3, dark: 0x8C96A8)
        case 2: Color(light: 0x2E90FA, dark: 0x53A6FF)
        case 3: Color(light: 0x12B76A, dark: 0x32D583)
        case 4: Color(light: 0xF79009, dark: 0xFDB022)
        default: Color(light: 0xF04438, dark: 0xFF6B5E)
        }
    }

    static let heartRate = Color(light: 0xF04438, dark: 0xFF6B5E)
    static let power = Color(light: 0x7A5AF8, dark: 0x9B8AFB)
    static let cadence = Color(light: 0x0BA5EC, dark: 0x36BFFA)
    static let elevation = Color(light: 0x667085, dark: 0x98A2B3)
}

// MARK: - Card

struct CardModifier: ViewModifier {
    var padding: CGFloat = Space.l

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.card, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

extension View {
    /// Content on a raised card (white in light mode, raised grey in dark).
    func card(padding: CGFloat = Space.l) -> some View { modifier(CardModifier(padding: padding)) }
}

// MARK: - Text styles

/// Small uppercase label above a value or a group ("DISTANCE", "RUN · KEY").
struct Eyebrow: View {
    let text: String
    var color: Color = .secondary

    init(_ text: String, color: Color = .secondary) {
        self.text = text
        self.color = color
    }

    var body: some View {
        Text(text.uppercased(with: .current))
            .font(.caption2.weight(.semibold))
            .tracking(0.6)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Title of a block on a scrolling screen, outside cards ("Splits", "Heart rate zones").
struct SectionTitle: View {
    let text: String
    var trailing: String?

    init(_ text: String, trailing: String? = nil) {
        self.text = text
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.weight(.bold))
            Spacer()
            if let trailing {
                Text(trailing).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.top, Space.s)
    }
}

/// A number with its unit smaller after it: "11,1 km", "5:50 /km". Digits are monospaced so
/// columns of numbers line up.
struct StatValue: View {
    let value: String
    var unit: String?
    var size: CGFloat = 28
    var weight: Font.Weight = .semibold
    var color: Color = .primary
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let size = Self.scaled(size, typeSize)
        let number = Text(value).font(.system(size: size, weight: weight).monospacedDigit()).foregroundStyle(color)
        let unitText = Text(unit.map { " " + $0 } ?? "").font(.system(size: size * 0.55, weight: .medium)).foregroundStyle(.secondary)
        Text("\(number)\(unitText)")
            .lineLimit(1)
            .minimumScaleFactor(0.6)
    }
}

extension StatValue {
    /// A fixed number size scaled with Dynamic Type like a title, at most ×1.6 (big numbers
    /// already read well; the line shrinks to fit rather than wrap).
    static func scaled(_ size: CGFloat, _ typeSize: DynamicTypeSize) -> CGFloat {
        #if os(iOS)
        let traits = UITraitCollection(preferredContentSizeCategory: UIContentSizeCategory(typeSize))
        return min(UIFontMetrics(forTextStyle: .title1).scaledValue(for: size, compatibleWith: traits), size * 1.6)
        #else
        return size
        #endif
    }
}

/// Label above a big number (Strava-style headline stat).
struct StatTile: View {
    let label: String
    let value: String
    var unit: String?
    var size: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            StatValue(value: value, unit: unit, size: size)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct Stat: Identifiable {
    let label: String
    let value: String
    var unit: String?
    var id: String { label }
}

/// Stats in rows of `columns`, hairlines between rows.
struct StatGrid: View {
    let stats: [Stat]
    var columns = 3
    var size: CGFloat = 26

    var body: some View {
        let rows = stride(from: 0, to: stats.count, by: columns).map { Array(stats[$0..<min($0 + columns, stats.count)]) }
        VStack(alignment: .leading, spacing: Space.m) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                if i > 0 { Divider() }
                HStack(alignment: .top, spacing: Space.m) {
                    ForEach(row) { s in StatTile(label: s.label, value: s.value, unit: s.unit, size: size) }
                    ForEach(0..<(columns - row.count), id: \.self) { _ in Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }
}

// MARK: - Badges

/// Sport glyph on a filled rounded square in the sport colour (as in Fitness and HealthFit).
struct SportBadge: View {
    let sport: Sport
    var subSport: String?
    var size: CGFloat = 36
    var muted = false

    var body: some View {
        Image(systemName: Sport.symbol(sport, subSport: subSport))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
                    .fill((muted ? Color.gray : sport.color).gradient)
            )
            .accessibilityHidden(true)
    }
}

/// Status or delivery as a tinted capsule with an icon.
struct Pill: View {
    let text: String
    var systemImage: String?
    var color: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage { Image(systemName: systemImage).imageScale(.small) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .foregroundStyle(color)
        .background(color.opacity(0.13), in: Capsule())
    }
}

/// Thin progress track.
struct ProgressTrack: View {
    let fraction: Double
    var color: Color = .brand
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.15))
                Capsule().fill(color.gradient)
                    .frame(width: max(height, geo.size.width * min(max(fraction, 0), 1)))
                    .opacity(fraction > 0 ? 1 : 0)
            }
        }
        .frame(height: height)
    }
}

/// Ring of progress with a label inside (gym sets done).
struct ProgressRing<Label: View>: View {
    let fraction: Double
    var color: Color = .brand
    var lineWidth: CGFloat = 6
    @ViewBuilder let label: () -> Label

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.15), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(fraction, 0), 1))
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.snappy, value: fraction)
            label()
        }
    }
}

// MARK: - Loading

extension View {
    /// While `active`: the view keeps its size but is hidden, a spinner sits in its middle.
    /// Content that loads later takes a placeholder of its own height, so the screen doesn't jump.
    func loadingPlaceholder(_ active: Bool) -> some View {
        opacity(active ? 0 : 1)
            .overlay { if active { ProgressView() } }
            .allowsHitTesting(!active)
            .accessibilityHidden(active)
    }
}

/// A card-sized grey block with a spinner, for content whose final shape is unknown.
struct LoadingCard: View {
    var height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
            .fill(Color.card)
            .frame(height: height)
            .overlay { ProgressView() }
            .accessibilityLabel(L("Loading"))
    }
}

// MARK: - Athlete profile in the environment

private struct AthleteProfileKey: EnvironmentKey {
    static let defaultValue = Profile()
}

extension EnvironmentValues {
    /// Thresholds and zones of the athlete (plan profiles, zone charts). Set at each tab's stack.
    var athleteProfile: Profile {
        get { self[AthleteProfileKey.self] }
        set { self[AthleteProfileKey.self] = newValue }
    }
}
