@preconcurrency import CoreBluetooth
import Foundation
import Observation
import TrainerKit

/// Bluetooth side of the ride: the smart trainer (FTMS) and a heart-rate sensor (HeartCast on the
/// iPhone, or any chest strap). Connects to the first of each it sees, reconnects on drop.
@MainActor @Observable
final class TrainerLink: NSObject {
    enum Status: Equatable {
        case off, searching, connecting(String), connected(String)
        var name: String? {
            switch self {
            case let .connecting(n), let .connected(n): n
            default: nil
            }
        }
    }

    private(set) var trainer: Status = .off { didSet { if trainer != oldValue { log("trainer \(trainer)") } } }
    private(set) var heart: Status = .off { didSet { if heart != oldValue { log("heart \(heart)") } } }

    /// Raw readings → RideModel.
    @ObservationIgnored var onTrainer: ((IndoorBikeData) -> Void)?
    @ObservationIgnored var onHeart: ((Int?) -> Void)?

    @ObservationIgnored private var packets = 0
    @ObservationIgnored private var lastPacket: [String: Date] = [:]
    @ObservationIgnored private var central: CBCentralManager!
    @ObservationIgnored private var trainerPeripheral: CBPeripheral?
    @ObservationIgnored private var heartPeripheral: CBPeripheral?

    private static let ftms = CBUUID(string: GATT.fitnessMachine)
    private static let hrs = CBUUID(string: GATT.heartRate)
    private static let trainerKey = "trainerPeripheral", heartKey = "heartPeripheral"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    private func poweredOn() {
        // Known devices first: a trainer advertises only 1–2 min after power-on, but a pending
        // connect to a known peripheral completes whenever it shows up.
        for (key, isTrainer) in [(Self.trainerKey, true), (Self.heartKey, false)] {
            guard let s = UserDefaults.standard.string(forKey: key), let id = UUID(uuidString: s),
                  let p = central.retrievePeripherals(withIdentifiers: [id]).first else { continue }
            connect(p, trainer: isTrainer)
        }
        for p in central.retrieveConnectedPeripherals(withServices: [Self.hrs]) where heartPeripheral == nil {
            connect(p, trainer: false)
        }
        scanIfNeeded()
    }

    private func scanIfNeeded() {
        guard central.state == .poweredOn else { return }
        let missing = (trainerPeripheral == nil ? [Self.ftms] : []) + (heartPeripheral == nil ? [Self.hrs] : [])
        if missing.isEmpty {
            central.stopScan()
        } else {
            if trainerPeripheral == nil { trainer = .searching }
            if heartPeripheral == nil { heart = .searching }
            central.scanForPeripherals(withServices: missing)
        }
    }

    private func connect(_ p: CBPeripheral, trainer isTrainer: Bool) {
        let name = p.name ?? "?"
        p.delegate = self
        if isTrainer {
            trainerPeripheral = p
            trainer = .connecting(name)
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.trainerKey)
        } else {
            heartPeripheral = p
            heart = .connecting(name)
            UserDefaults.standard.set(p.identifier.uuidString, forKey: Self.heartKey)
        }
        central.connect(p)
        scanIfNeeded()
    }

    /// Forget both devices and search again (e.g. to pick another trainer).
    func reset() {
        for p in [trainerPeripheral, heartPeripheral].compactMap({ $0 }) { central.cancelPeripheralConnection(p) }
        trainerPeripheral = nil
        heartPeripheral = nil
        UserDefaults.standard.removeObject(forKey: Self.trainerKey)
        UserDefaults.standard.removeObject(forKey: Self.heartKey)
        scanIfNeeded()
    }

    fileprivate func stateChanged(_ state: CBManagerState) {
        log("bluetooth state \(state.rawValue) (5 = on, 3 = unauthorized)")
        if state == .poweredOn { poweredOn() } else { trainer = .off; heart = .off }
    }

    fileprivate func discovered(_ p: CBPeripheral, services: [String]) {
        if trainerPeripheral == nil, services.contains(GATT.fitnessMachine) { connect(p, trainer: true) }
        else if heartPeripheral == nil, services.contains(GATT.heartRate), p != trainerPeripheral { connect(p, trainer: false) }
    }

    fileprivate func connected(_ p: CBPeripheral) {
        log("connected \(p.name ?? "?")")
        p.discoverServices([Self.ftms, Self.hrs])
    }

    fileprivate func disconnected(_ p: CBPeripheral, _ error: String? = nil) {
        log("disconnected \(p.name ?? "?") \(error ?? "")")
        if p == trainerPeripheral { trainer = .connecting(p.name ?? "?"); onTrainer?(IndoorBikeData()) }
        if p == heartPeripheral { heart = .connecting(p.name ?? "?"); onHeart?(nil) }
        central.connect(p) // pending until it is back in range / advertising
    }

    fileprivate func ready(_ p: CBPeripheral, characteristic uuid: String) {
        if uuid == GATT.indoorBikeData, p == trainerPeripheral { trainer = .connected(p.name ?? "?") }
        if uuid == GATT.heartRateMeasurement, p == heartPeripheral { heart = .connected(p.name ?? "?") }
    }

    fileprivate func value(_ p: CBPeripheral, characteristic uuid: String, bytes: [UInt8]) {
        packets += 1
        let now = Date()
        if let last = lastPacket[uuid], now.timeIntervalSince(last) > 2 {
            log(String(format: "gap %.1f s in %@ from %@", now.timeIntervalSince(last), uuid, p.name ?? "?"))
        }
        lastPacket[uuid] = now
        if packets % 50 == 1 { log("\(p.name ?? "?") \(uuid) #\(packets) " + bytes.map { String(format: "%02x", $0) }.joined(separator: " ")) }
        if uuid == GATT.indoorBikeData, let d = IndoorBikeData(bytes) { onTrainer?(d) }
        if uuid == GATT.heartRateMeasurement, let m = HeartRateMeasurement(bytes) { onHeart?(m.bpm) }
    }
}

extension TrainerLink: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ c: CBCentralManager) {
        let s = c.state
        MainActor.assumeIsolated { stateChanged(s) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                                    advertisementData a: [String: Any], rssi: NSNumber) {
        let services = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (a[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        // Filtered scan: whatever matched is one of ours even if the advert hides the UUID (iPhone).
        let matched = services.isEmpty ? [GATT.heartRate] : services.map(\.uuidString)
        MainActor.assumeIsolated { discovered(p, services: matched) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        MainActor.assumeIsolated { connected(p) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        let e = "connect failed: \(error?.localizedDescription ?? "")"
        MainActor.assumeIsolated { disconnected(p, e) }
    }

    nonisolated func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        let e = error?.localizedDescription
        MainActor.assumeIsolated { disconnected(p, e) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let names = (p.services ?? []).map(\.uuid.uuidString).joined(separator: ","), e = error?.localizedDescription ?? ""
        MainActor.assumeIsolated { log("\(p.name ?? "?") services [\(names)] \(e)") }
        for s in p.services ?? [] {
            p.discoverCharacteristics([CBUUID(string: GATT.indoorBikeData), CBUUID(string: GATT.heartRateMeasurement)], for: s)
        }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] { p.setNotifyValue(true, for: ch) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor ch: CBCharacteristic, error: Error?) {
        let u = ch.uuid.uuidString, e = error?.localizedDescription ?? "ok"
        MainActor.assumeIsolated { log("\(p.name ?? "?") notify \(u): \(e)") }
        guard error == nil, ch.isNotifying else { return }
        let uuid = ch.uuid.uuidString
        MainActor.assumeIsolated { ready(p, characteristic: uuid) }
    }

    nonisolated func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let v = ch.value else { return }
        let uuid = ch.uuid.uuidString, bytes = [UInt8](v)
        MainActor.assumeIsolated { value(p, characteristic: uuid, bytes: bytes) }
    }
}

/// Debug log for trainer sessions: ~/zone2/rides/ride.log (connections + every 50th packet).
@MainActor func log(_ text: String) {
    let url = RideModel.ridesFolder.appending(path: "ride.log")
    try? FileManager.default.createDirectory(at: RideModel.ridesFolder, withIntermediateDirectories: true)
    let line = Data("\(Date().formatted(.iso8601)) \(text)\n".utf8)
    if let h = try? FileHandle(forWritingTo: url) {
        _ = try? h.seekToEnd()
        h.write(line)
        try? h.close()
    } else {
        try? line.write(to: url)
    }
}
