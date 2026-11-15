import Foundation
import Testing
@testable import Zone2Kit

private final class Sink: @unchecked Sendable {
    var sent: [String] = []
    var fail: Error?
}

@Test func outboxSendsReplacesAndBacksOff() async throws {
    let store = try LocalStore()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    try store.enqueue(id: "delivery-report", kind: "delivery", payload: Data("v1".utf8), now: t0)
    try store.enqueue(id: "delivery-report", kind: "delivery", payload: Data("v2".utf8), now: t0) // replaces
    #expect(try store.outboxAll().map { String(decoding: $0.payload, as: UTF8.self) } == ["v2"])

    let sink = Sink()
    let sender = OutboxSender(store: store) { item in
        if let e = sink.fail { throw e }
        sink.sent.append(item.id)
    }

    sink.fail = URLError(.notConnectedToInternet)
    #expect(await sender.flush(now: t0) == 0)
    #expect(try store.outboxAll().first?.attempts == 1)
    #expect(try store.outboxAll().first?.lastError == "offline")
    #expect(await sender.flush(now: t0.addingTimeInterval(10)) == 0) // not due yet (30 s backoff)
    #expect(try store.dueOutbox(now: t0.addingTimeInterval(31)).count == 1)

    sink.fail = nil
    #expect(await sender.flush(now: t0.addingTimeInterval(31)) == 1)
    #expect(sink.sent == ["delivery-report"])
    #expect(try store.outboxAll().isEmpty)
}

@Test func outboxParksClientErrors() {
    #expect(OutboxSender.delay(APIError.status(400, body: ""), attempts: 0) == 24 * 3600)
    #expect(OutboxSender.delay(APIError.status(429, body: ""), attempts: 2) == 120)
    #expect(OutboxSender.delay(APIError.status(503, body: ""), attempts: 20) == 6 * 3600)
}

@Test func deviceIdIsStableAcrossResync() throws {
    let store = try LocalStore()
    let id = try store.deviceId()
    try store.reset()
    #expect(try store.deviceId() == id)
}

@Test func deliveryReportEncodesForServer() throws {
    let report = DeliveryReport(
        deviceId: "dev-1", deviceName: "iPhone", model: "iPhone17,1", appVersion: "0.1.0",
        lastPullAt: Date(timeIntervalSince1970: 0), cursor: "42", error: nil,
        items: [DeliveryReportItem(plannedWorkoutId: "w", version: 3, date: "2026-11-16", warnings: nil)]
    )
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as! [String: Any]
    #expect(json["lastPullAt"] as? String == "1970-01-01T00:00:00Z")
    let watch = json["watch"] as! [String: Any]
    let item = (watch["items"] as! [[String: Any]])[0]
    #expect(item["version"] as? Int == 3 && item["date"] as? String == "2026-11-16")
}
