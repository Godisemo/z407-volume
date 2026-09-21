import AppKit
import CoreBluetooth

/// `open -n Z407Volume.app --args --speed-probe`: times (1) the handshake and a first command
/// pipelined without waiting for replies, and (2) bursts of steps written as fast as flow
/// control allows. Acknowledgements only prove receipt: the speaker acks unpaced steps it
/// doesn't apply, so judge (2) by ear. Downs go first so dropped steps leave it quieter.
@MainActor
final class SpeedProbe: NSObject {
    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var command: CBCharacteristic?
    private var t0 = Date()
    private var outbox: [Z407.Command] = []
    private var acks: [UInt8: Int] = [:]
    private let burst = 10

    func start() {
        record("starting")
        central = CBCentralManager(delegate: self, queue: nil)
        after(30) { $0.finish("timed out") }
    }

    private func record(_ message: String) {
        Diagnostics.record("SPEED +\(Int(Date().timeIntervalSince(t0) * 1000))ms \(message)")
    }

    private func after(_ seconds: TimeInterval, _ action: @escaping @MainActor (SpeedProbe) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
    }

    private func finish(_ message: String) {
        record(message)
        if let peripheral { central.cancelPeripheralConnection(peripheral) }
        after(0.5) { _ in exit(0) }
    }

    private func write(_ commands: [Z407.Command]) {
        outbox += commands
        pump()
    }

    private func pump() {
        guard let peripheral, let command else { return }
        while !outbox.isEmpty && peripheral.canSendWriteWithoutResponse {
            let next = outbox.removeFirst()
            peripheral.writeValue(next.payload, for: command, type: .withoutResponse)
            record("→ \(next)")
        }
    }

    private func runBursts() {
        acks = [:]
        t0 = Date()
        record("burst: \(burst) down, flow control only")
        write(Array(repeating: .volumeDown, count: burst))
        after(1.5) { probe in
            probe.record("down acks \(probe.acks[0x03, default: 0])/\(probe.burst)")
            probe.t0 = Date()
            probe.record("burst: \(probe.burst) up, flow control only")
            probe.write(Array(repeating: .volumeUp, count: probe.burst))
            probe.after(1.5) { probe in
                probe.record("up acks \(probe.acks[0x02, default: 0])/\(probe.burst)")
                probe.finish("done")
            }
        }
    }
}

extension SpeedProbe: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        t0 = Date()
        central.scanForPeripherals(withServices: [Z407.service])
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard peripheral == nil else { return }
        central.stopScan()
        record("discovered")
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        record("connected")
        p.discoverServices([Z407.service])
    }
}

extension SpeedProbe: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = p.services?.first else { return finish("no service") }
        p.discoverCharacteristics([Z407.commandCharacteristic, Z407.responseCharacteristic], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        let chars = service.characteristics ?? []
        command = chars.first { $0.uuid == Z407.commandCharacteristic }
        guard let response = chars.first(where: { $0.uuid == Z407.responseCharacteristic }) else { return finish("no response char") }
        record("characteristics found; subscribing and pipelining initiate, acknowledge, down, up without waiting")
        p.setNotifyValue(true, for: response)
        write([.handshakeInitiate, .handshakeAcknowledge, .volumeDown, .volumeUp])
        after(2) { $0.runBursts() }
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor c: CBCharacteristic, error: Error?) {
        record("subscribed")
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor c: CBCharacteristic, error: Error?) {
        let value = c.value ?? Data()
        record("← [\(value.hex)]")
        if value.count == 2 && value.first == 0xC0 { acks[value.last!, default: 0] += 1 }
        if value == Z407.Response.initiateAck && outbox.isEmpty {
            record("(speaker asked for acknowledge again)")
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        pump()
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        record("disconnected: \(error?.localizedDescription ?? "no error")")
    }
}
