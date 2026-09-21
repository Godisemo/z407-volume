import AppKit
import CoreBluetooth

/// `open -n Z407Volume.app --args --probe [--up N]`: dumps the speaker's whole GATT table, reads
/// every readable characteristic and subscribes to every notifying one, steps the volume down 10
/// (to the floor) and up N (default 2), re-reading between steps, then disconnects and logs the
/// speaker's advertisements, to find out whether anything exposes the current level.
/// Only reads, subscribes and volume steps; never writes other commands.
@MainActor
final class Probe: NSObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var readable: [CBCharacteristic] = []
    private var pendingServices = 0
    private var handshakeDone = false
    private var snapshot = "setup"
    private var scanningAdvertisements = false
    private let upSteps: Int = {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--up"), i + 1 < args.count else { return 2 }
        return Int(args[i + 1]) ?? 2
    }()

    func start() {
        record("Probe starting")
        central = CBCentralManager(delegate: self, queue: nil)
        after(30) { $0.finish("Probe timed out") }
    }

    private func record(_ message: String) { Diagnostics.record("PROBE \(message)") }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor (Probe) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
    }

    private func finish(_ message: String) {
        record(message)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        after(0.5) { _ in exit(0) }
    }

    private func readAll(_ label: String) {
        snapshot = label
        record("Snapshot \(label): reading \(readable.count) characteristic(s)")
        readable.forEach { peripheral?.readValue(for: $0) }
    }

    private func steps(_ step: Z407.Command, count: Int, then next: @escaping @MainActor (Probe) -> Void) {
        guard count > 0, let peripheral, let command else { return next(self) }
        peripheral.writeValue(step.payload, for: command, type: .withoutResponse)
        record("→ \(step)")
        after(0.15) { $0.steps(step, count: count - 1, then: next) }
    }

    private func runExperiment() {
        readAll("A (before steps)")
        after(1.5) { probe in
            probe.steps(.volumeDown, count: 10) { probe in
                probe.after(1) { probe in
                    probe.readAll("B (after 10 down)")
                    probe.after(1.5) { probe in
                        probe.steps(.volumeUp, count: probe.upSteps) { probe in
                            probe.after(1) { probe in
                                probe.readAll("C (after \(probe.upSteps) up)")
                                probe.after(1.5) { $0.scanAdvertisements() }
                            }
                        }
                    }
                }
            }
        }
    }

    private func scanAdvertisements() {
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        peripheral = nil
        scanningAdvertisements = true
        after(1) { probe in
            probe.record("Scanning advertisements (volume at floor + \(probe.upSteps))")
            probe.central.scanForPeripherals(withServices: [Z407.service], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            probe.after(5) { $0.finish("Probe done") }
        }
    }

    private static func describe(_ properties: CBCharacteristicProperties) -> String {
        let names: [(CBCharacteristicProperties, String)] = [
            (.read, "read"), (.write, "write"), (.writeWithoutResponse, "writeNoResp"),
            (.notify, "notify"), (.indicate, "indicate"),
        ]
        return names.filter { properties.contains($0.0) }.map(\.1).joined(separator: ",")
    }
}

extension Probe: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return record("Bluetooth state \(central.state.rawValue)") }
        central.scanForPeripherals(withServices: [Z407.service])
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        if scanningAdvertisements {
            let data = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data ?? Data()
            return record("Advertisement manufacturer data [\(data.hex)]")
        }
        guard peripheral == nil else { return }
        central.stopScan()
        record("Found \(p.name ?? "unnamed"), advertisement: \(advertisementData)")
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        record("Connected")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        record("Disconnected: \(error?.localizedDescription ?? "no error")")
    }
}

extension Probe: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let services = p.services ?? []
        pendingServices = services.count
        services.forEach { p.discoverCharacteristics(nil, for: $0) }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        record("Service \(service.uuid)")
        for c in service.characteristics ?? [] {
            record("  Characteristic \(c.uuid) [\(Self.describe(c.properties))]")
            if c.properties.contains(.read) { readable.append(c) }
            if c.properties.contains(.notify) || c.properties.contains(.indicate) { p.setNotifyValue(true, for: c) }
            if c.uuid == Z407.commandCharacteristic { command = c }
        }
        pendingServices -= 1
        guard pendingServices == 0 else { return }
        readAll("initial")
        after(1.5) { probe in
            guard let command = probe.command else { return probe.finish("No command characteristic") }
            p.writeValue(Z407.Command.handshakeInitiate.payload, for: command, type: .withoutResponse)
            probe.record("→ handshakeInitiate")
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let value = c.value ?? Data()
        let text = String(data: value, encoding: .utf8).map { " \"\($0)\"" } ?? ""
        record("[\(snapshot)] \(c.uuid) = [\(value.hex)]\(text)\(error.map { " error: \($0.localizedDescription)" } ?? "")")
        guard c.uuid == Z407.responseCharacteristic else { return }
        if value == Z407.Response.initiateAck, let command {
            p.writeValue(Z407.Command.handshakeAcknowledge.payload, for: command, type: .withoutResponse)
            record("→ handshakeAcknowledge")
        } else if Z407.Response.isAcknowledge(value) && !handshakeDone {
            handshakeDone = true
            after(0.5) { $0.runExperiment() }
        }
    }
}
