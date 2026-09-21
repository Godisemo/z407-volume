import CoreBluetooth

/// Just-in-time BLE link to the Z407: disconnected by default, connects on the first
/// command, and releases the speaker after `idleRelease` seconds without commands so
/// another client (the speaker accepts only one) can take it.
@MainActor
final class Z407Link: NSObject {
    enum State: Equatable {
        case bluetoothUnavailable
        case idle
        case connecting
        case ready
        /// Last attempt timed out or was refused: speaker asleep, powered off, or held by another client.
        case unreachable
    }

    var onStateChange: ((State) -> Void)?
    /// Called when a command has actually been written to the speaker.
    var onWrite: ((Z407.Command) -> Void)?
    /// Commands to write at the start of each session, ahead of queued presses.
    var sessionPrologue: (() -> [Z407.Command])?
    /// Speaker notifications other than the initiate handshake step.
    var onResponse: ((Data) -> Void)?
    private(set) var state: State = .bluetoothUnavailable {
        didSet {
            guard state != oldValue else { return }
            Diagnostics.record("Link state: \(state)")
            onStateChange?(state)
        }
    }

    /// Commands accepted by `send` but not yet written.
    var pendingCommands: [Z407.Command] { queued + outbox }

    private let idleRelease: TimeInterval = 5
    private let acquireTimeout: TimeInterval = 6
    /// The speaker acknowledges every step however fast they arrive, but doesn't apply steps
    /// written back to back (audible glitches, level drift); 40 ms apart is reliable. Override with
    /// `defaults write io.github.godisemo.z407-volume StepIntervalMs -int N`.
    private var stepInterval: TimeInterval {
        Double(UserDefaults.standard.object(forKey: "StepIntervalMs") as? Int ?? 40) / 1000
    }
    /// Fits a full volume re-sync issued while disconnected.
    private let maxQueued = 128
    private let peripheralIDKey = "Z407PeripheralIdentifier"

    private var central: CBCentralManager!
    /// Connection attempt or live link owned by the current session.
    private var peripheral: CBPeripheral?
    /// Previous link we asked CoreBluetooth to drop; redialling waits for its disconnect callback
    /// so a stale callback can't tear down the new session.
    private var releasing: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?
    private var writeType: CBCharacteristicWriteType = .withoutResponse
    /// The speaker answers `84 05` with a challenge; the first one is already answered by the
    /// pipelined `84 00`, later ones are keep-alives that need a fresh `84 00`.
    private var challengeAnswered = false
    /// User commands issued before the handshake reply.
    private var queued: [Z407.Command] = []
    /// Commands waiting for their write slot.
    private var outbox: [Z407.Command] = []
    private var idleTimer: Timer?
    private var acquireTimer: Timer?
    private var stepTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(
            delegate: self, queue: nil,
            options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    func send(_ command: Z407.Command) {
        switch state {
        case .bluetoothUnavailable:
            Diagnostics.record("Dropped \(command): Bluetooth unavailable")
        case .ready:
            enqueueWrite(command)
        case .connecting:
            enqueue(command)
        case .idle, .unreachable:
            enqueue(command)
            acquire()
        }
    }

    /// Starts a session with nothing queued (so `sessionPrologue` runs), unless one is open.
    func open() {
        guard state == .idle || state == .unreachable else { return }
        acquire()
    }

    /// Drops the link now instead of waiting for the idle timer (sleep, quit).
    func release() {
        guard state == .connecting || state == .ready else { return }
        Diagnostics.record("Releasing speaker")
        teardown(to: .idle)
    }

    // MARK: - Session lifecycle

    private func enqueue(_ command: Z407.Command) {
        guard queued.count < maxQueued else { return }
        queued.append(command)
    }

    private func acquire() {
        state = .connecting
        acquireTimer = commonModeTimer(acquireTimeout) { $0.acquireTimedOut() }
        if releasing == nil { dial() }
    }

    /// Connects straight to the remembered speaker (fast path, no advertisement needed to start)
    /// while also scanning, in case the remembered identifier is stale.
    private func dial() {
        if let id = UserDefaults.standard.string(forKey: peripheralIDKey).flatMap(UUID.init(uuidString:)),
           let known = central.retrievePeripherals(withIdentifiers: [id]).first {
            Diagnostics.record("Dialling remembered speaker \(id)")
            connect(known)
        }
        central.scanForPeripherals(withServices: [Z407.service])
    }

    private func connect(_ p: CBPeripheral) {
        peripheral = p
        p.delegate = self
        central.connect(p)
    }

    private func acquireTimedOut() {
        let phase = peripheral?.state == .connected ? "handshake did not complete" : "no speaker answered"
        Diagnostics.record("Timed out after \(acquireTimeout)s: \(phase) (asleep, or held by the dial remote / another computer?)")
        releasing = nil
        teardown(to: .unreachable)
    }

    /// The speaker accepts both handshake writes back to back without waiting for its challenge
    /// (measured with `--speed-probe`), saving a round trip per connect. User commands wait for
    /// the handshake reply so none land before the session is up.
    private func startSession() {
        challengeAnswered = true
        outbox = [.handshakeInitiate, .handshakeAcknowledge]
        pump()
    }

    private func becomeReady() {
        acquireTimer?.invalidate()
        acquireTimer = nil
        state = .ready
        outbox += (sessionPrologue?() ?? []) + queued
        queued.removeAll()
        pump()
    }

    private func armIdleTimer() {
        idleTimer?.invalidate()
        idleTimer = commonModeTimer(idleRelease) { $0.release() }
    }

    /// Timers must also fire while the status menu is open (event-tracking run loop mode).
    private func commonModeTimer(_ interval: TimeInterval, _ action: @escaping @MainActor (Z407Link) -> Void) -> Timer {
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { action(self) } }
        }
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }

    private func teardown(to newState: State) {
        for timer in [idleTimer, acquireTimer, stepTimer] { timer?.invalidate() }
        idleTimer = nil
        acquireTimer = nil
        stepTimer = nil
        if central.state == .poweredOn {
            central.stopScan()
            if let p = peripheral, p.state != .disconnected {
                if p.state == .connected { releasing = p }
                central.cancelPeripheralConnection(p)
            }
        }
        if !queued.isEmpty || !outbox.isEmpty {
            Diagnostics.record("Dropped \(queued.count + outbox.count) unsent command(s)")
        }
        peripheral = nil
        commandCharacteristic = nil
        challengeAnswered = false
        queued.removeAll()
        outbox.removeAll()
        state = newState
    }

    private func fail(_ reason: String) {
        Diagnostics.record(reason)
        teardown(to: .unreachable)
    }

    // MARK: - Writes

    private func enqueueWrite(_ command: Z407.Command) {
        outbox.append(command)
        pump()
    }

    /// Writes queued commands, pausing `stepInterval` after each volume/bass step; flow control
    /// (`peripheralIsReady`) and the step timer both re-invoke it.
    private func pump() {
        guard stepTimer == nil, !outbox.isEmpty, let p = peripheral, let c = commandCharacteristic else { return }
        while !outbox.isEmpty && stepTimer == nil {
            if writeType == .withoutResponse && !p.canSendWriteWithoutResponse { break }
            let command = outbox.removeFirst()
            p.writeValue(command.payload, for: c, type: writeType)
            Diagnostics.record("→ \(command) [\(command.payload.hex)]")
            onWrite?(command)
            if command.isStep {
                stepTimer = commonModeTimer(stepInterval) {
                    $0.stepTimer = nil
                    $0.pump()
                }
            }
        }
        if state == .ready { armIdleTimer() }
    }
}

// Delegates are called on the main queue (`queue: nil` above).
extension Z407Link: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Diagnostics.record("Bluetooth power: \(central.state.name), permission: \(CBManager.authorization.name)")
        if central.state == .poweredOn {
            if state == .bluetoothUnavailable { state = .idle }
        } else {
            releasing = nil
            teardown(to: .bluetoothUnavailable)
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi: NSNumber) {
        guard state == .connecting else { return }
        central.stopScan()
        Diagnostics.record("Discovered \(p.name ?? "unnamed") \(p.identifier) RSSI \(rssi)")
        guard peripheral?.identifier != p.identifier else { return }
        if let stale = peripheral { central.cancelPeripheralConnection(stale) }
        connect(p)
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        guard p === peripheral, state == .connecting else {
            central.cancelPeripheralConnection(p)
            return
        }
        Diagnostics.record("Connected; discovering services")
        central.stopScan()
        UserDefaults.standard.set(p.identifier.uuidString, forKey: peripheralIDKey)
        p.discoverServices([Z407.service])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        guard p === peripheral else { return }
        fail("Connect failed: \(error?.localizedDescription ?? "unknown")")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if p === releasing {
            releasing = nil
            if state == .connecting && peripheral == nil { dial() }
            return
        }
        guard p === peripheral else { return }
        Diagnostics.record("Speaker disconnected: \(error?.localizedDescription ?? "no error")")
        teardown(to: state == .connecting ? .unreachable : .idle)
    }
}

extension Z407Link: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard p === peripheral else { return }
        guard error == nil, let service = p.services?.first(where: { $0.uuid == Z407.service }) else {
            return fail("Z407 service not found: \(error?.localizedDescription ?? "missing")")
        }
        p.discoverCharacteristics([Z407.commandCharacteristic, Z407.responseCharacteristic], for: service)
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard p === peripheral else { return }
        let chars = service.characteristics ?? []
        guard error == nil,
              let command = chars.first(where: { $0.uuid == Z407.commandCharacteristic }),
              let response = chars.first(where: { $0.uuid == Z407.responseCharacteristic }) else {
            return fail("Z407 characteristics not found: \(error?.localizedDescription ?? "missing")")
        }
        commandCharacteristic = command
        writeType = command.properties.contains(.writeWithoutResponse) ? .withoutResponse : .withResponse
        p.setNotifyValue(true, for: response)
    }

    func peripheral(_ p: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristic.uuid == Z407.responseCharacteristic else { return }
        guard error == nil, characteristic.isNotifying else {
            return fail("Subscribe failed: \(error?.localizedDescription ?? "not notifying")")
        }
        Diagnostics.record("Subscribed; sending handshake and queued commands")
        startSession()
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard p === peripheral, characteristic.uuid == Z407.responseCharacteristic,
              let value = characteristic.value else { return }
        Diagnostics.record("← [\(value.hex)]")
        switch value {
        case Z407.Response.initiateAck:
            if challengeAnswered {
                challengeAnswered = false
            } else {
                enqueueWrite(.handshakeAcknowledge)
            }
        case _ where Z407.Response.isAcknowledge(value):
            if state == .connecting { becomeReady() }
            onResponse?(value)
        default:
            onResponse?(value)
        }
    }

    func peripheralIsReady(toSendWriteWithoutResponse p: CBPeripheral) {
        guard p === peripheral else { return }
        pump()
    }

    func peripheral(_ p: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error { Diagnostics.record("Write failed: \(error.localizedDescription)") }
    }
}

private extension CBManagerState {
    var name: String {
        switch self {
        case .poweredOn: "on"
        case .poweredOff: "off"
        case .unauthorized: "unauthorized"
        case .unsupported: "unsupported"
        case .resetting: "resetting"
        case .unknown: "unknown"
        @unknown default: "state \(rawValue)"
        }
    }
}

private extension CBManagerAuthorization {
    var name: String {
        switch self {
        case .allowedAlways: "allowed"
        case .denied: "denied"
        case .restricted: "restricted"
        case .notDetermined: "not yet asked"
        @unknown default: "authorization \(rawValue)"
        }
    }
}
