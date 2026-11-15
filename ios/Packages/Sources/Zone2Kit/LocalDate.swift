import Foundation

/// A calendar date without time ("2026-11-16"), as the plan uses it (dates are in the athlete's
/// time zone, docs/03-data-model.md). Arithmetic and formatting go through a UTC calendar so the
/// device's own zone never shifts a date.
public struct LocalDate: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let iso: String

    public init?(_ iso: String) {
        guard LocalDate.parse(iso) != nil else { return nil }
        self.iso = iso
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let d = LocalDate(raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(raw)"))
        }
        self = d
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(iso)
    }

    public var description: String { iso }
    public static func < (a: LocalDate, b: LocalDate) -> Bool { a.iso < b.iso }

    static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        c.firstWeekday = 2
        return c
    }()

    private static func parse(_ iso: String) -> Date? {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard iso.count == 10, parts.count == 3 else { return nil }
        let comps = DateComponents(year: parts[0], month: parts[1], day: parts[2])
        guard let date = utc.date(from: comps),
              utc.component(.day, from: date) == parts[2] else { return nil }
        return date
    }

    /// Midnight UTC of this date — only for formatting with a UTC formatter.
    public var utcDate: Date { LocalDate.parse(iso)! }

    init(utcDate: Date) {
        let c = LocalDate.utc.dateComponents([.year, .month, .day], from: utcDate)
        iso = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    /// Today in a time zone (the athlete's, not the device's).
    public static func today(in timeZone: TimeZone, now: Date = Date()) -> LocalDate {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.year, .month, .day], from: now)
        return LocalDate(String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!))!
    }

    public func adding(days: Int) -> LocalDate {
        LocalDate(utcDate: LocalDate.utc.date(byAdding: .day, value: days, to: utcDate)!)
    }

    /// Monday of this date's week.
    public var weekStart: LocalDate {
        let weekday = LocalDate.utc.component(.weekday, from: utcDate) // 1 = Sunday
        return adding(days: -((weekday + 5) % 7))
    }

    public func days(until end: LocalDate) -> Int {
        LocalDate.utc.dateComponents([.day], from: utcDate, to: end.utcDate).day!
    }

    /// Formatted with the user's locale, e.g. "Mon 16 Nov".
    public func formatted(_ style: Date.FormatStyle) -> String {
        var s = style
        s.timeZone = TimeZone(identifier: "UTC")!
        return utcDate.formatted(s)
    }
}
