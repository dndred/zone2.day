import Foundation

/// RFC 1952 gzip on top of Foundation's raw DEFLATE (`.zlib` = RFC 1951 without header).
/// The server detects gzip by magic bytes (backend/src/ingest/healthkit.ts).
public enum Gzip {
    public static func compress(_ data: Data) throws -> Data {
        let deflated = try (data as NSData).compressed(using: .zlib) as Data
        var out = Data([0x1f, 0x8b, 0x08, 0x00, 0, 0, 0, 0, 0x00, 0x03]) // magic, deflate, no flags, mtime 0, unix
        out.append(deflated)
        appendLE(&out, crc32(data))
        appendLE(&out, UInt32(truncatingIfNeeded: data.count))
        return out
    }

    private static func appendLE(_ d: inout Data, _ v: UInt32) {
        withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) }
    }

    private static let table: [UInt32] = (0..<256).map { n -> UInt32 in
        var c = UInt32(n)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    public static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        data.withUnsafeBytes { buf in
            for b in buf { c = table[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        }
        return c ^ 0xFFFF_FFFF
    }
}
