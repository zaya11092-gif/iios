import Foundation
import Network
import simd

// PCBridge — Phase 2 streaming transport (SteamVR from your gaming PC).
//
// Protocol (see docs/STREAMING.md): UDP, little-endian.
//   client -> server: [u8 'I'][u8 'I'][u8 'O'][u8 'S'][u8 type][payload]
//     type 0x01 hello   : u16 protoVersion + null-terminated device name
//     type 0x02 pose    : head(7f) L(8f) R(8f) buttons(2u8) — 25 floats total
//     type 0x03 bye
//   server -> client:
//     type 0x10 video   : u32 frameIndex + u32 bytes + HEVC/H.265 chunk
//     type 0x11 config  : u32 w, u32 h, u8 fps
//
// This iteration: transport + pose streaming + HEVC decode into a pixel
// buffer (pipeline proven end-to-end). Rendering decoded frames onto the
// in-VR stream panel and the ALVR-server compatible driver land next.
final class PCBridge {

    static let shared = PCBridge()

    enum Status: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)

        var label: String {
            switch self {
            case .idle: return "OFF"
            case .connecting: return "CONNECTING..."
            case .connected: return "ONLINE"
            case .failed(let m): return "ERR: \(m)"
            }
        }
    }

    private let lock = NSLock()
    private var _status: Status = .idle
    var status: Status {
        lock.withLock { _status }
    }
    var statusText: String { "status: \(status.label)" }

    private var connection: NWConnection?
    private var poseTimer: DispatchSourceTimer?
    private let decoder = HEVCDecoder()
    private(set) var decodedFrameCount = 0

    private var settings: XRSettings { XRSettings.shared }

    func toggle() {
        if status == .idle || isFailed { connect() } else { disconnect() }
    }

    private var isFailed: Bool {
        if case .failed = status { return true }
        return false
    }

    func connect() {
        disconnect()
        setStatus(.connecting)
        let host = NWEndpoint.Host(settings.pcIP.isEmpty ? "192.168.1.100" : settings.pcIP)
        let port = NWEndpoint.Port(rawValue: UInt16(settings.pcPort)) ?? 9100
        let conn = NWConnection(host: host, port: port, using: .udp)
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.setStatus(.connected)
                self?.sendHello()
                self?.startPoseLoop()
            case .failed(let err):
                self?.setStatus(.failed(err.localizedDescription))
            default:
                break
            }
        }
        receiveLoop(on: conn)
        conn.start(queue: DispatchQueue(label: "dev.iios.stream"))
        connection = conn
    }

    func disconnect() {
        poseTimer?.cancel()
        poseTimer = nil
        connection?.cancel()
        connection = nil
        setStatus(.idle)
    }

    // MARK: - outgoing

    private func send(_ payload: Data) {
        connection?.send(content: payload, completion: .contentProcessed { _ in })
    }

    private func sendHello() {
        var bytes: [UInt8] = [0x49, 0x49, 0x4F, 0x53, 0x01] // IIOS + hello
        let v = UInt16(1).littleEndian
        bytes.append(contentsOf: [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)])
        bytes.append(contentsOf: Array("iios iphone".utf8))
        bytes.append(0)
        send(Data(bytes))
    }

    private func startPoseLoop() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.iios.pose"))
        timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
        timer.setEventHandler { [weak self] in self?.sendPose() }
        timer.resume()
        poseTimer = timer
    }

    private func sendPose() {
        var headPose = xrc_pose()
        guard xrc_get_head_pose(0, &headPose) == XRC_OK else { return }

        var floats: [Float] = []
        floats.append(contentsOf: [headPose.orientation.x, headPose.orientation.y,
                                   headPose.orientation.z, headPose.orientation.w,
                                   headPose.position.x, headPose.position.y, headPose.position.z])
        for h in 0..<Int(XRC_HAND_COUNT) {
            var ctrl = xrc_controller_state()
            _ = xrc_get_controller(Int32(h), &ctrl)
            floats.append(contentsOf: [ctrl.pose.orientation.x, ctrl.pose.orientation.y,
                                       ctrl.pose.orientation.z, ctrl.pose.orientation.w,
                                       ctrl.pose.position.x, ctrl.pose.position.y, ctrl.pose.position.z,
                                       ctrl.trigger, ctrl.grip])
        }
        let triggerBits: [UInt8] = [ctrlButtonBits(hand: 0), ctrlButtonBits(hand: 1)]

        var bytes: [UInt8] = [0x49, 0x49, 0x4F, 0x53, 0x02]
        for f in floats {
            var v = f.bitPattern.littleEndian
            withUnsafeBytes(of: &v) { bytes.append(contentsOf: $0) }
        }
        bytes.append(contentsOf: triggerBits)
        send(Data(bytes))
    }

    private func ctrlButtonBits(hand: Int) -> UInt8 {
        var ctrl = xrc_controller_state()
        _ = xrc_get_controller(Int32(hand), &ctrl)
        return UInt8(ctrl.buttons & 0xFF)
    }

    // MARK: - incoming

    private var rxBuffer = Data()

    private func receiveLoop(on conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, complete, error in
            guard let self = self else { return }
            if let data = data {
                self.rxBuffer.append(data)
                self.drainRx()
            }
            if complete || error != nil {
                if let e = error { self.setStatus(.failed(e.localizedDescription)) }
                return
            }
            self.receiveLoop(on: conn)
        }
    }

    private func drainRx() {
        let headerLen = 4 + 1 + 4 + 4 // magic + type + frameIndex + length
        while rxBuffer.count >= headerLen {
            guard rxBuffer.starts(with: [0x49, 0x49, 0x4F, 0x53]) else {
                rxBuffer.removeAll(keepingCapacity: false)
                return
            }
            let type = rxBuffer[4]
            let frameIndex = rxBuffer.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            let length = rxBuffer.subdata(in: 9..<13).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
            guard rxBuffer.count >= headerLen + Int(length) else { return }
            let payload = rxBuffer.subdata(in: headerLen..<(headerLen + Int(length)))
            rxBuffer.removeSubrange(0..<(headerLen + Int(length)))

            if type == 0x10 {
                decoder.decode(payload, frameIndex: frameIndex)
                decodedFrameCount += 1
            }
        }
    }

    private func setStatus(_ s: Status) {
        lock.withLock { _status = s }
    }
}
