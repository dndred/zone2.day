import Foundation

/// GATT UUIDs we use (16-bit, as CBUUID strings).
public enum GATT {
    public static let fitnessMachine = "1826"
    public static let indoorBikeData = "2AD2"
    public static let cyclingPower = "1818"
    public static let cyclingPowerMeasurement = "2A63"
    public static let heartRate = "180D"
    public static let heartRateMeasurement = "2A37"
}

/// FTMS Indoor Bike Data (0x2AD2), Bluetooth FTMS 1.0 §4.9. Only the fields we show/record.
public struct IndoorBikeData: Equatable, Sendable {
    public var speedKmh: Double?
    public var cadenceRpm: Double?
    public var powerW: Int?
    public var heartRate: Int?

    public init(speedKmh: Double? = nil, cadenceRpm: Double? = nil, powerW: Int? = nil, heartRate: Int? = nil) {
        self.speedKmh = speedKmh
        self.cadenceRpm = cadenceRpm
        self.powerW = powerW
        self.heartRate = heartRate
    }

    /// nil when the packet is shorter than its flags say.
    public init?(_ d: [UInt8]) {
        var r = ByteReader(d)
        guard let flags = r.u16() else { return nil }
        func has(_ bit: Int) -> Bool { flags & (1 << bit) != 0 }
        // bit 0 = "More Data": when 0, Instantaneous Speed is present.
        if !has(0) { guard let v = r.u16() else { return nil }; speedKmh = Double(v) / 100 }
        if has(1) { guard r.skip(2) else { return nil } } // average speed
        if has(2) { guard let v = r.u16() else { return nil }; cadenceRpm = Double(v) / 2 }
        if has(3) { guard r.skip(2) else { return nil } } // average cadence
        if has(4) { guard r.skip(3) else { return nil } } // total distance
        if has(5) { guard r.skip(2) else { return nil } } // resistance level
        if has(6) { guard let v = r.s16() else { return nil }; powerW = v }
        if has(7) { guard r.skip(2) else { return nil } } // average power
        if has(8) { guard r.skip(5) else { return nil } } // expended energy
        if has(9) { guard let v = r.u8() else { return nil }; heartRate = v }
    }
}

/// Heart Rate Measurement (0x2A37). `bpm == nil` when the sensor sends 0 (no reading, e.g.
/// HeartCast between watch updates) — show "no heart rate", do not record zeros.
public struct HeartRateMeasurement: Equatable, Sendable {
    public var bpm: Int?

    public init?(_ d: [UInt8]) {
        var r = ByteReader(d)
        guard let flags = r.u8() else { return nil }
        let v = flags & 1 == 0 ? r.u8() : r.u16()
        guard let v else { return nil }
        bpm = v > 0 ? v : nil
    }
}

/// Cycling Power Measurement (0x2A63): flags + instantaneous power (sint16). Fallback when a
/// trainer has no FTMS.
public struct CyclingPowerMeasurement: Equatable, Sendable {
    public var powerW: Int

    public init?(_ d: [UInt8]) {
        var r = ByteReader(d)
        guard r.u16() != nil, let p = r.s16() else { return nil }
        powerW = p
    }
}

struct ByteReader {
    let d: [UInt8]
    var i = 0
    init(_ d: [UInt8]) { self.d = d }

    mutating func u8() -> Int? {
        guard i < d.count else { return nil }
        defer { i += 1 }
        return Int(d[i])
    }

    mutating func u16() -> Int? {
        guard i + 1 < d.count else { return nil }
        defer { i += 2 }
        return Int(d[i]) | Int(d[i + 1]) << 8
    }

    mutating func s16() -> Int? { u16().map { Int(Int16(bitPattern: UInt16($0))) } }

    mutating func skip(_ n: Int) -> Bool {
        guard i + n <= d.count else { return false }
        i += n
        return true
    }
}
