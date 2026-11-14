import Foundation
import Testing
@testable import Zone2Kit

@Test func crc32KnownVector() {
    #expect(Gzip.crc32(Data("123456789".utf8)) == 0xCBF4_3926)
}

/// Round-trip through the system gzip — the same format the server's DecompressionStream expects.
@Test func gzipIsReadableBySystemGzip() throws {
    let text = String(repeating: "{\"heartRate\":[0,5,140]} ", count: 2000)
    let gz = try Gzip.compress(Data(text.utf8))
    #expect(gz.count < text.utf8.count / 5)
    let file = FileManager.default.temporaryDirectory.appending(path: "zone2-\(UUID()).gz")
    try gz.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
    p.arguments = ["-dc", file.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    try p.run()
    let out = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    #expect(p.terminationStatus == 0)
    #expect(String(decoding: out, as: UTF8.self) == text)
}
