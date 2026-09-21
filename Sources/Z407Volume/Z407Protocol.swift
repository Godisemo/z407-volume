import CoreBluetooth

/// GATT protocol of the Logitech Z407 dial remote, per
/// https://github.com/freundTech/logi-z407-reverse-engineering/blob/main/doc/Protocol.md
/// The speaker exposes only these two characteristics and never reports volume or bass
/// levels (probed: no other services, the advertisement doesn't change with volume, and
/// steps at the floor are still acknowledged). No public implementation has found a query
/// command either; all use exactly the codes below.
@MainActor
enum Z407 {
    /// Advertised only while no remote is connected.
    static let service = CBUUID(string: "0000FDC2-0000-1000-8000-00805F9B34FB")
    static let commandCharacteristic = CBUUID(string: "C2E758B9-0E78-41E0-B0CB-98A593193FC5")
    static let responseCharacteristic = CBUUID(string: "B84AC9C6-29C5-46D4-BBA1-9D534784330F")

    /// Omits the `85 0x` chime commands, whose documented meanings contradict each other.
    enum Command: UInt16 {
        case bassUp = 0x8000
        case bassDown = 0x8001
        case volumeUp = 0x8002
        case volumeDown = 0x8003
        /// Playback commands act on the Bluetooth audio source only; on AUX and USB,
        /// `playPause` toggles mute instead (the dial's press).
        case playPause = 0x8004
        case nextTrack = 0x8005
        case previousTrack = 0x8006
        case inputBluetooth = 0x8101
        case inputAux = 0x8102
        case inputUSB = 0x8103
        case bluetoothPairing = 0x8200
        case factoryReset = 0x8300
        case handshakeAcknowledge = 0x8400
        case handshakeInitiate = 0x8405

        var payload: Data { Data([UInt8(rawValue >> 8), UInt8(rawValue & 0xFF)]) }

        var isStep: Bool { [.volumeUp, .volumeDown, .bassUp, .bassDown].contains(self) }
    }

    enum Input: String, CaseIterable {
        case bluetooth, aux, usb

        var title: String {
            switch self {
            case .bluetooth: "Bluetooth"
            case .aux: "AUX"
            case .usb: "USB"
            }
        }

        var command: Command {
            switch self {
            case .bluetooth: .inputBluetooth
            case .aux: .inputAux
            case .usb: .inputUSB
            }
        }

        /// `d4 00 01/02/03` (handshake reply to every connect) or `cf 04/05/06` (sent when the
        /// input changes), per freundTech PR #2.
        init?(report: Data) {
            let bytes = [UInt8](report)
            switch bytes {
            case [0xD4, 0x00, 0x01], [0xCF, 0x04]: self = .bluetooth
            case [0xD4, 0x00, 0x02], [0xCF, 0x05]: self = .aux
            case [0xD4, 0x00, 0x03], [0xCF, 0x06]: self = .usb
            default: return nil
            }
        }
    }

    /// The speaker drops the link a few seconds after connect unless the client sends
    /// initiate → (initiateAck, then `cf 0b` "ready") → acknowledge → (acknowledge response).
    /// It also re-sends initiateAck as a keep-alive, which must be answered the same way.
    enum Response {
        static let initiateAck = Data([0xD4, 0x05, 0x01])

        /// `d4 00 xx`, where xx is the current input (see `Input(report:)`).
        static func isAcknowledge(_ value: Data) -> Bool {
            value.count == 3 && value.starts(with: [0xD4, 0x00])
        }
    }
}
