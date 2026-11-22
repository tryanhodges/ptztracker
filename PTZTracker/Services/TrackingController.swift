import Combine
import CoreGraphics
import Darwin
import Foundation
import Network

@MainActor
final class TrackingController: ObservableObject {
    @Published var trackingEnabled = false {
        didSet {
            if !trackingEnabled {
                Task { await stopHead() }
            }
        }
    }

    @Published private(set) var currentTarget: TrackedTarget?
    @Published private(set) var currentMotion: PTZMotion = .idle
    @Published private(set) var connection = ConnectionStatus()
    @Published private(set) var framesProcessed: Int = 0

    let settings: AppSettings
    let camera: CameraCaptureService
    let visca = ViscaClient()
    private let visionQueue = DispatchQueue(label: "ptz.vision", qos: .userInitiated)
    private let vision = VisionTrackingService()
    private var companionServer: CompanionHTTPServer?
    private var lastProcessTime = Date.distantPast
    private let minInterval: TimeInterval = 1.0 / 15.0
    private var lastTrackingMode: TrackingMode?

    init(settings: AppSettings, camera: CameraCaptureService) {
        self.settings = settings
        self.camera = camera
        camera.setFrameHandler { [weak self] buffer, _ in
            self?.enqueueFrame(buffer)
        }
    }

    func start() async {
        await camera.requestAccessAndStart(deviceID: settings.selectedDeviceID)
        await reconnectVisca()
        startCompanionServer()
    }

    func reconnectVisca() async {
        await visca.configure(
            host: settings.cameraIP,
            port: settings.cameraPort,
            deviceAddress: settings.deviceAddress
        )
        try? await Task.sleep(nanoseconds: 200_000_000)
        let connected = await visca.connected
        connection.viscaConnected = connected
        connection.lastViscaError = connected ? nil : "Connecting to \(settings.cameraIP):\(settings.cameraPort)…"
    }

    func restartCompanionServer() {
        companionServer?.stop()
        companionServer = nil
        startCompanionServer()
    }

    func setTrackingEnabled(_ enabled: Bool) {
        trackingEnabled = enabled
    }

    func toggleTracking() {
        trackingEnabled.toggle()
    }

    // MARK: - Frame pipeline

    private func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard now.timeIntervalSince(lastProcessTime) >= minInterval else { return }
        lastProcessTime = now

        let mode = settings.trackingMode
        let confidence = Float(settings.sensitivity)
        let trackingOn = trackingEnabled
        let bufferZone = settings.bufferZone
        let reaction = settings.reactionSpeed
        let invertPan = settings.invertPan
        let invertTilt = settings.invertTilt

        if lastTrackingMode != mode {
            lastTrackingMode = mode
            visionQueue.async { [vision] in vision.reset() }
        }

        visionQueue.async { [weak self, vision] in
            let target = vision.detect(
                pixelBuffer: pixelBuffer,
                mode: mode,
                minConfidence: confidence
            )

            let motion: PTZMotion
            if trackingOn, let target {
                motion = Self.computeMotion(
                    for: target,
                    bufferZone: bufferZone,
                    reactionSpeed: reaction,
                    invertPan: invertPan,
                    invertTilt: invertTilt
                )
            } else {
                motion = .idle
            }

            Task { @MainActor in
                self?.applyFrameResult(target: target, motion: motion, trackingOn: trackingOn)
            }
        }
    }

    private func applyFrameResult(target: TrackedTarget?, motion: PTZMotion, trackingOn: Bool) {
        framesProcessed += 1
        currentTarget = target

        guard trackingOn else {
            if currentMotion != .idle {
                currentMotion = .idle
                Task { await stopHead() }
            }
            return
        }

        if currentMotion != motion {
            currentMotion = motion
            Task { await dispatchMotion(motion) }
        } else if case .moving = motion {
            // Keep refreshing VISCA while moving so identical keys can be skipped inside the client,
            // but still allow reconnect recovery.
            Task { await dispatchMotion(motion) }
        }
    }

    /// Vision coords: origin bottom-left, x/y in 0…1.
    private nonisolated static func computeMotion(
        for target: TrackedTarget,
        bufferZone: Double,
        reactionSpeed: Double,
        invertPan: Bool,
        invertTilt: Bool
    ) -> PTZMotion {
        let cx = target.center.x
        let cy = target.center.y
        let dx = cx - 0.5
        let dy = cy - 0.5
        let dead = bufferZone

        var panDir: PTZMotion.PanDirection = .stop
        var tiltDir: PTZMotion.TiltDirection = .stop

        if abs(dx) > dead {
            let goingRight = dx > 0
            let panRight = invertPan ? !goingRight : goingRight
            panDir = panRight ? .right : .left
        }

        if abs(dy) > dead {
            let goingUp = dy > 0
            let tiltUp = invertTilt ? !goingUp : goingUp
            tiltDir = tiltUp ? .up : .down
        }

        if panDir == .stop && tiltDir == .stop {
            return .idle
        }

        let panMag = max(0, abs(dx) - dead) / max(0.001, 0.5 - dead)
        let tiltMag = max(0, abs(dy) - dead) / max(0.001, 0.5 - dead)
        let panSpeed = speedByte(magnitude: panMag, reactionSpeed: reactionSpeed)
        let tiltSpeed = min(speedByte(magnitude: tiltMag, reactionSpeed: reactionSpeed), 0x14)

        return .moving(pan: panDir, tilt: tiltDir, panSpeed: panSpeed, tiltSpeed: tiltSpeed)
    }

    private nonisolated static func speedByte(magnitude: Double, reactionSpeed: Double) -> UInt8 {
        let scaled = magnitude * reactionSpeed
        let value = Int((scaled * 23.0).rounded()) + 1
        return UInt8(clamping: max(1, min(0x18, value)))
    }

    private func dispatchMotion(_ motion: PTZMotion) async {
        if let hex = await visca.sendMotion(motion) {
            connection.lastCommandHex = hex
            connection.viscaConnected = await visca.connected
        } else {
            connection.viscaConnected = await visca.connected
        }
    }

    private func stopHead() async {
        if let hex = await visca.sendMotion(.idle, force: true) {
            connection.lastCommandHex = hex
        }
        currentMotion = .idle
    }

    // MARK: - Companion

    private func startCompanionServer() {
        let server = CompanionHTTPServer(port: UInt16(clamping: settings.companionPort)) { [weak self] action in
            guard let self else { return CompanionHTTPServer.Response(status: 503, body: #"{"error":"unavailable"}"#) }
            return self.handleCompanion(action)
        }
        companionServer = server
        do {
            try server.start()
            connection.companionListening = true
            connection.companionURL = "http://\(Self.lanAddress()):\(settings.companionPort)"
        } catch {
            connection.companionListening = false
            connection.companionURL = ""
            connection.lastViscaError = "Companion HTTP failed: \(error.localizedDescription)"
        }
    }

    private func handleCompanion(_ action: CompanionHTTPServer.Action) -> CompanionHTTPServer.Response {
        switch action {
        case .status:
            return .init(status: 200, body: statusJSON(), contentType: "application/json")
        case .on:
            trackingEnabled = true
            return .init(status: 200, body: statusJSON(), contentType: "application/json")
        case .off:
            trackingEnabled = false
            return .init(status: 200, body: statusJSON(), contentType: "application/json")
        case .toggle:
            trackingEnabled.toggle()
            return .init(status: 200, body: statusJSON(), contentType: "application/json")
        }
    }

    private func statusJSON() -> String {
        let tracking = trackingEnabled
        let viscaOK = connection.viscaConnected
        let hasTarget = currentTarget != nil
        return """
        {"tracking":\(tracking),"viscaConnected":\(viscaOK),"hasTarget":\(hasTarget),"camera":"\(settings.cameraIP):\(settings.cameraPort)"}
        """
    }

    private static func lanAddress() -> String {
        var address = "127.0.0.1"
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let iface = current.pointee
            if iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) {
                let name = String(cString: iface.ifa_name)
                if name.hasPrefix("en") {
                    var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    getnameinfo(
                        iface.ifa_addr,
                        socklen_t(iface.ifa_addr.pointee.sa_len),
                        &hostname,
                        socklen_t(hostname.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                    let ip = String(cString: hostname)
                    if !ip.hasPrefix("127.") {
                        address = ip
                        break
                    }
                }
            }
            ptr = iface.ifa_next
        }
        return address
    }
}
