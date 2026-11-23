import Foundation
import Network

/// Datavideo DVIP (VISCA over IP with 2-byte length prefix) over TCP.
actor ViscaClient {
    private var connection: NWConnection?
    private var host: String = ""
    private var port: UInt16 = 5002
    private var deviceAddress: UInt8 = 0x81
    private var isConnected = false
    private var lastMotionKey: String?

    var connected: Bool { isConnected }

    func configure(host: String, port: Int, deviceAddress: Int) {
        let clampedPort = UInt16(clamping: max(1, min(port, 65535)))
        let addr = UInt8(clamping: max(1, min(deviceAddress, 7))) &+ 0x80
        let needsReconnect =
            host != self.host
            || clampedPort != self.port
            || addr != self.deviceAddress
            || !isConnected

        self.host = host
        self.port = clampedPort
        self.deviceAddress = addr

        if needsReconnect {
            reconnect()
        }
    }

    func reconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        lastMotionKey = nil

        guard !host.isEmpty else { return }

        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let params = NWParameters.tcp
        params.serviceClass = .responsiveData
        let conn = NWConnection(to: endpoint, using: params)
        connection = conn

        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        conn.start(queue: .global(qos: .userInitiated))
        receiveLoop(conn)
    }

    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
        lastMotionKey = nil
    }

    func stop() async {
        await sendMotion(.idle, force: true)
    }

    /// Sends pan/tilt drive when the motion key changes (avoids flooding identical packets).
    @discardableResult
    func sendMotion(_ motion: PTZMotion, force: Bool = false) async -> String? {
        let packet: Data
        let key: String

        switch motion {
        case .idle:
            key = "stop"
            packet = buildPanTilt(
                panSpeed: 0x0C,
                tiltSpeed: 0x0C,
                pan: 0x03,
                tilt: 0x03
            )
        case let .moving(pan, tilt, panSpeed, tiltSpeed):
            let panByte: UInt8
            switch pan {
            case .left: panByte = 0x01
            case .right: panByte = 0x02
            case .stop: panByte = 0x03
            }
            let tiltByte: UInt8
            switch tilt {
            case .up: tiltByte = 0x01
            case .down: tiltByte = 0x02
            case .stop: tiltByte = 0x03
            }
            key = "\(panByte)-\(tiltByte)-\(panSpeed)-\(tiltSpeed)"
            packet = buildPanTilt(
                panSpeed: panSpeed,
                tiltSpeed: tiltSpeed,
                pan: panByte,
                tilt: tiltByte
            )
        }

        if !force, key == lastMotionKey {
            return nil
        }
        lastMotionKey = key

        do {
            try await send(packet)
            return packet.map { String(format: "%02X", $0) }.joined(separator: " ")
        } catch {
            isConnected = false
            reconnect()
            return nil
        }
    }

    func sendPreset(_ slot: UInt8, recall: Bool) async throws -> String {
        return try await sendPresetCommand(slot, command: recall ? 0x02 : 0x01)
    }

    func resetPreset(_ slot: UInt8) async throws -> String {
        try await sendPresetCommand(slot, command: 0x00)
    }

    private func sendPresetCommand(_ slot: UInt8, command: UInt8) async throws -> String {
        guard isConnected else { throw ViscaError.notConnected }
        let packet = wrapDVIP(Data([deviceAddress, 0x01, 0x04, 0x3F, command, slot, 0xFF]))
        try await send(packet)
        lastMotionKey = nil
        return packet.map { String(format: "%02X", $0) }.joined(separator: " ")
    }

    // MARK: - Packet building (matches companion-module-datavideo-visca)

    private func buildPanTilt(panSpeed: UInt8, tiltSpeed: UInt8, pan: UInt8, tilt: UInt8) -> Data {
        // VISCA body without address: 01 06 01 VV WW RR SS FF
        var body = Data([0x01, 0x06, 0x01, panSpeed, tiltSpeed, pan, tilt, 0xFF])
        body.insert(deviceAddress, at: 0)
        return wrapDVIP(body)
    }

    /// DVIP: big-endian length (including the 2 length bytes) + VISCA frame.
    private func wrapDVIP(_ visca: Data) -> Data {
        let total = UInt16(visca.count + 2)
        var packet = Data()
        packet.append(UInt8((total >> 8) & 0xFF))
        packet.append(UInt8(total & 0xFF))
        packet.append(visca)
        return packet
    }

    // MARK: - Transport

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            isConnected = true
        case .failed, .cancelled:
            isConnected = false
        default:
            break
        }
    }

    private func receiveLoop(_ conn: NWConnection) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            if error != nil || isComplete {
                Task { await self?.markDisconnected() }
                return
            }
            Task { await self?.receiveLoop(conn) }
        }
    }

    private func markDisconnected() {
        isConnected = false
    }

    private func send(_ data: Data) async throws {
        guard let connection else {
            throw ViscaError.notConnected
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            })
        }
    }
}

enum ViscaError: LocalizedError {
    case notConnected

    var errorDescription: String? {
        switch self {
        case .notConnected: return "VISCA socket not connected"
        }
    }
}
