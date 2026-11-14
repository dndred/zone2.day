import Foundation

/// Contract with the server: backend/src/domain/healthkit.ts (`HealthKitDump`, schema 1).
/// Fixture shared by both test suites: fixtures/healthkit/contract-v1.json.
public struct HealthKitDump: Codable, Sendable, Equatable {
    public var schema: Int = 1
    public var exportedAt: String
    public var app: AppInfo?
    public var workout: Workout
    /// Key = HKQuantityTypeIdentifier without the "HKQuantityTypeIdentifier" prefix.
    public var samples: [String: SampleSeries]
    /// [tOffsetSec, lat, lon, altitudeM, hAccM, vAccM, speedMps, courseDeg]
    public var route: [[Double]]

    public init(exportedAt: String, app: AppInfo?, workout: Workout, samples: [String: SampleSeries], route: [[Double]]) {
        self.exportedAt = exportedAt
        self.app = app
        self.workout = workout
        self.samples = samples
        self.route = route
    }

    public struct AppInfo: Codable, Sendable, Equatable {
        public var version: String
        public init(version: String) { self.version = version }
    }

    public struct Source: Codable, Sendable, Equatable {
        public var name: String
        public var bundleId: String
        public init(name: String, bundleId: String) {
            self.name = name
            self.bundleId = bundleId
        }
    }

    public struct Device: Codable, Sendable, Equatable {
        public var name: String?
        public var model: String?
        public var hardwareVersion: String?
        public var softwareVersion: String?
        public init(name: String?, model: String?, hardwareVersion: String?, softwareVersion: String?) {
            self.name = name
            self.model = model
            self.hardwareVersion = hardwareVersion
            self.softwareVersion = softwareVersion
        }
    }

    public struct Activity: Codable, Sendable, Equatable {
        public var uuid: String
        public var activityType: Int
        public var start: String
        public var end: String?
        public var location: String?
        public var metadata: [String: MetaValue]
        public init(uuid: String, activityType: Int, start: String, end: String?, location: String?, metadata: [String: MetaValue]) {
            self.uuid = uuid
            self.activityType = activityType
            self.start = start
            self.end = end
            self.location = location
            self.metadata = metadata
        }
    }

    public struct Event: Codable, Sendable, Equatable {
        public var type: String
        public var start: String
        public var end: String
        public var metadata: [String: MetaValue]
        public init(type: String, start: String, end: String, metadata: [String: MetaValue]) {
            self.type = type
            self.start = start
            self.end = end
            self.metadata = metadata
        }
    }

    public struct Workout: Codable, Sendable, Equatable {
        public var uuid: String
        public var activityType: Int
        public var start: String
        public var end: String
        public var durationSec: Double
        public var totalDistanceM: Double?
        public var totalEnergyKcal: Double?
        public var source: Source
        public var device: Device?
        public var metadata: [String: MetaValue]
        public var activities: [Activity]
        public var events: [Event]
        public init(uuid: String, activityType: Int, start: String, end: String, durationSec: Double, totalDistanceM: Double?, totalEnergyKcal: Double?, source: Source, device: Device?, metadata: [String: MetaValue], activities: [Activity], events: [Event]) {
            self.uuid = uuid
            self.activityType = activityType
            self.start = start
            self.end = end
            self.durationSec = durationSec
            self.totalDistanceM = totalDistanceM
            self.totalEnergyKcal = totalEnergyKcal
            self.source = source
            self.device = device
            self.metadata = metadata
            self.activities = activities
            self.events = events
        }
    }

    public struct SampleSeries: Codable, Sendable, Equatable {
        public var unit: String
        /// [startOffsetSec, endOffsetSec, value]
        public var values: [[Double]]
        public init(unit: String, values: [[Double]]) {
            self.unit = unit
            self.values = values
        }
    }

    /// HealthKit metadata value: string | number | bool | quantity {value, unit}.
    public enum MetaValue: Codable, Sendable, Equatable {
        case string(String)
        case number(Double)
        case bool(Bool)
        case quantity(value: Double, unit: String)

        private struct Q: Codable { let value: Double; let unit: String }

        public init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let b = try? c.decode(Bool.self) { self = .bool(b) }
            else if let n = try? c.decode(Double.self) { self = .number(n) }
            else if let s = try? c.decode(String.self) { self = .string(s) }
            else {
                let q = try c.decode(Q.self)
                self = .quantity(value: q.value, unit: q.unit)
            }
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let s): try c.encode(s)
            case .number(let n): try c.encode(n)
            case .bool(let b): try c.encode(b)
            case .quantity(let value, let unit): try c.encode(Q(value: value, unit: unit))
            }
        }
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

/// ISO 8601 with fractional seconds — the format the dump uses for all timestamps.
public enum DumpTime {
    nonisolated(unsafe) private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    public static func string(_ date: Date) -> String { formatter.string(from: date) }
}
