// Usage: just ble-scout [seconds]  (builds tools/ble-scout/build/Scout.app, log → tools/ble-scout/build/scan.log)
// BLE scout for the trainer: lists advertisers, connects to fitness devices, dumps services and
// characteristics, subscribes to FTMS Indoor Bike Data / Cycling Power / CSC / HR and decodes them.
import CoreBluetooth
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)
let FTMS = CBUUID(string: "1826"), CPS = CBUUID(string: "1818"), CSC = CBUUID(string: "1816")
let HRS = CBUUID(string: "180D")
let fitness: Set<CBUUID> = [FTMS, CPS, CSC, HRS]
let names = ["x2", "think", "trainer", "heartcast"]
let started = Date()
func ts() -> String { String(format: "%6.1f", Date().timeIntervalSince(started)) }

func u16(_ d: [UInt8], _ i: Int) -> Int { Int(d[i]) | Int(d[i + 1]) << 8 }
func s16(_ d: [UInt8], _ i: Int) -> Int { Int(Int16(bitPattern: UInt16(u16(d, i)))) }

func indoorBike(_ d: [UInt8]) -> String {
  let f = u16(d, 0); var i = 2; var out: [String] = []
  if f & 1 == 0 { out.append(String(format: "speed %.2f km/h", Double(u16(d, i)) / 100)); i += 2 }
  if f & 2 != 0 { i += 2 }
  if f & 4 != 0 { out.append(String(format: "cad %.1f", Double(u16(d, i)) / 2)); i += 2 }
  if f & 8 != 0 { i += 2 }
  if f & 16 != 0 { out.append("dist \(Int(d[i]) | Int(d[i+1]) << 8 | Int(d[i+2]) << 16) m"); i += 3 }
  if f & 32 != 0 { out.append("res \(s16(d, i))"); i += 2 }
  if f & 64 != 0 { out.append("power \(s16(d, i)) W"); i += 2 }
  if f & 128 != 0 { i += 2 }
  if f & 256 != 0 { out.append("kcal \(u16(d, i))"); i += 5 }
  if f & 512 != 0 { out.append("hr \(d[i])"); i += 1 }
  if f & 1024 != 0 { i += 1 }
  if f & 2048 != 0 { out.append("elapsed \(u16(d, i)) s"); i += 2 }
  return "FTMS bike flags=0x\(String(f, radix: 16)) " + out.joined(separator: ", ")
}

final class Scout: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  var cm: CBCentralManager!
  var seen: [UUID: String] = [:]
  var peripherals: [CBPeripheral] = []
  override init() { super.init(); cm = CBCentralManager(delegate: self, queue: nil) }

  func centralManagerDidUpdateState(_ c: CBCentralManager) {
    print("\(ts()) bluetooth state \(c.state.rawValue) (5 = on)")
    if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]) }
  }

  func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData a: [String: Any], rssi: NSNumber) {
    let name = p.name ?? (a[CBAdvertisementDataLocalNameKey] as? String) ?? "?"
    let svcs = (a[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
    if seen[p.identifier] == nil {
      seen[p.identifier] = name
      if name != "?" || !svcs.isEmpty { print("\(ts()) adv \(name) rssi \(rssi) services \(svcs.map(\.uuidString))") }
    }
    let match = !fitness.isDisjoint(with: svcs) || names.contains { name.lowercased().contains($0) }
    if match && !peripherals.contains(p) {
      print("\(ts()) → connecting to \(name)")
      peripherals.append(p); p.delegate = self; c.connect(p)
    }
  }

  func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
    print("\(ts()) connected \(p.name ?? "?")"); p.discoverServices(nil)
  }
  func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
    print("\(ts()) connect failed \(p.name ?? "?"): \(error?.localizedDescription ?? "")")
  }
  func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
    print("\(ts()) disconnected \(p.name ?? "?") \(error?.localizedDescription ?? "")")
  }

  func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
    for s in p.services ?? [] { print("\(ts()) [\(p.name ?? "?")] service \(s.uuid.uuidString) \(s.uuid)"); p.discoverCharacteristics(nil, for: s) }
  }
  func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
    for ch in s.characteristics ?? [] {
      print("\(ts())   char \(ch.uuid.uuidString) \(ch.uuid) props 0x\(String(ch.properties.rawValue, radix: 16))")
      if ch.properties.contains(.read) { p.readValue(for: ch) }
      if ch.properties.contains(.notify) || ch.properties.contains(.indicate) { p.setNotifyValue(true, for: ch) }
    }
  }
  var counts: [CBUUID: Int] = [:]
  func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
    guard let v = ch.value else { return }
    let d = [UInt8](v)
    counts[ch.uuid, default: 0] += 1
    let n = counts[ch.uuid]!
    if n > 3 && n % 5 != 0 { return } // throttle streams
    let hex = d.map { String(format: "%02x", $0) }.joined(separator: " ")
    var text: String
    switch ch.uuid.uuidString {
    case "2AD2": text = indoorBike(d)
    case "2A63": text = "CPS power \(s16(d, 2)) W flags=0x\(String(u16(d, 0), radix: 16))"
    case "2A37": text = "HR \(d[0] & 1 == 0 ? Int(d[1]) : u16(d, 1))"
    case "2ACC": text = "FTMS features machine=0x\(String(u16(d,0)|u16(d,2)<<16, radix: 16)) target=0x\(String(u16(d,4)|u16(d,6)<<16, radix: 16))"
    case "2AD8": text = "supported power range \(s16(d,0))…\(s16(d,2)) step \(u16(d,4)) W"
    case "2A29", "2A24", "2A26", "2A28", "2A00": text = "\"\(String(decoding: d, as: UTF8.self))\""
    default: text = ""
    }
    print("\(ts()) [\(p.name ?? "?")] \(ch.uuid.uuidString) #\(n) \(text) | \(hex)")
  }
}

let scout = Scout()
let limit = Double(CommandLine.arguments.dropFirst().first ?? "150") ?? 150
RunLoop.main.run(until: Date().addingTimeInterval(limit))
print("\(ts()) done")
