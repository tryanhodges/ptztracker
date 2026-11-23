import CoreVideo
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
    @Published private(set) var manualTargetSelection = false
    @Published private(set) var targetCandidates: [TrackedTarget] = []
    @Published private(set) var primaryTargetSelected = false
    @Published private(set) var currentMotion: PTZMotion = .idle
    @Published private(set) var connection = ConnectionStatus()
    @Published private(set) var framesProcessed: Int = 0

    let settings: AppSettings
    let camera: CameraCaptureService
    let visca = ViscaClient()
    private let visionQueue = DispatchQueue(label: "ptz.vision", qos: .userInitiated)
    private let vision = VisionTrackingService()
    private var companionServer: CompanionHTTPServer?
    @Published private(set) var sendingPreset = false
    @Published private(set) var presetMessage: String?
    private var configuredPresetHead: String?

    func recallPreset(_ slot: UInt8) async {
        _ = await sendPreset(slot, operation: .recall)
    }
    private var lastProcessTime = Date.distantPast
    private let minInterval: TimeInterval = 1.0 / 15.0
    private var lastTrackingMode: TrackingMode?
    private var targetRevision = 0
    private var processingFrame = false

    init(settings: AppSettings, camera: CameraCaptureService) {
        self.settings = settings
        self.camera = camera
        camera.setFrameHandler { [weak self] buffer, _ in
            self?.enqueueFrame(buffer)
        }
        camera.onDeckLinkSignalLost = { [weak self] in
            guard let self else { return }
            self.clearPrimaryTarget()
            if self.trackingEnabled { self.setTrackingEnabled(false) }
        }
    }

    func start() async {
        await camera.requestAccessAndStart(deviceID: settings.selectedDeviceID)
        await reconnectVisca()
        startCompanionServer()
    }

    func reconnectVisca() async {
        configuredPresetHead = settings.presetHead
        presetMessage = nil
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

    func setManualTargetSelection(_ enabled: Bool) {
        guard manualTargetSelection != enabled else { return }
        manualTargetSelection = enabled
        clearPrimaryTarget()
    }

    func clearPrimaryTarget() {
        targetRevision += 1
        primaryTargetSelected = false
        targetCandidates = []
        currentTarget = nil
        visionQueue.async { [vision] in vision.reset() }
        if currentMotion != .idle {
            currentMotion = .idle
            Task { await stopHead() }
        }
    }

    func selectPrimaryTarget(at previewPoint: CGPoint) {
        guard manualTargetSelection, !primaryTargetSelected else { return }
        let point = CGPoint(x: previewPoint.x, y: 1 - previewPoint.y)
        let hits = targetCandidates.filter { $0.boundingBox.contains(point) }
        guard let target = hits.min(by: {
            let a = $0.center
            let b = $1.center
            return hypot(a.x - point.x, a.y - point.y) < hypot(b.x - point.x, b.y - point.y)
        }) else { return }
        targetRevision += 1
        primaryTargetSelected = true
        currentTarget = target
        targetCandidates = []
        visionQueue.async { [vision] in vision.lock(on: target) }
    }

    // MARK: - Frame pipeline

    private func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
        let now = Date()
        guard !processingFrame, now.timeIntervalSince(lastProcessTime) >= minInterval else { return }
        processingFrame = true
        lastProcessTime = now

        let mode = settings.trackingMode
        let confidence = Float(settings.sensitivity)
        let trackingOn = trackingEnabled

        if lastTrackingMode != mode {
            lastTrackingMode = mode
            clearPrimaryTarget()
        }

        let revision = targetRevision
        let manual = manualTargetSelection
        let hasSelection = primaryTargetSelected
        visionQueue.async { [weak self, vision] in
            let target: TrackedTarget?
            let candidates: [TrackedTarget]
            if !manual {
                target = vision.detect(pixelBuffer: pixelBuffer, mode: mode, minConfidence: confidence)
                candidates = []
            } else if hasSelection {
                target = vision.followSelectedTarget(pixelBuffer: pixelBuffer, minConfidence: confidence)
                candidates = []
            } else {
                target = nil
                candidates = vision.candidates(pixelBuffer: pixelBuffer, mode: mode, minConfidence: confidence)
            }

            Task { @MainActor in
                guard let self else { return }
                self.processingFrame = false
                guard self.targetRevision == revision, self.settings.trackingMode == mode else { return }
                if hasSelection, target == nil { self.primaryTargetSelected = false }
                self.targetCandidates = candidates
                self.applyFrameResult(target: target, trackingOn: trackingOn)
            }
        }
    }

    private func applyFrameResult(target: TrackedTarget?, trackingOn: Bool) {
        framesProcessed += 1
        currentTarget = target

        guard trackingOn, trackingEnabled else {
            if currentMotion != .idle {
                currentMotion = .idle
                Task { await stopHead() }
            }
            return
        }

        let motion = target.map {
            Self.computeMotion(
                for: $0,
                framingPoint: settings.framingPoint,
                deadZoneWidth: settings.deadZoneWidth,
                deadZoneHeight: settings.deadZoneHeight,
                reactionSpeed: settings.reactionSpeed,
                invertPan: settings.invertPan,
                invertTilt: settings.invertTilt
            )
        } ?? .idle

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
        framingPoint: CGPoint,
        deadZoneWidth: Double,
        deadZoneHeight: Double,
        reactionSpeed: Double,
        invertPan: Bool,
        invertTilt: Bool
    ) -> PTZMotion {
        let anchorY = 1 - framingPoint.y
        let dx = target.center.x - framingPoint.x
        let dy = target.center.y - anchorY
        let halfWidth = deadZoneWidth / 2
        let halfHeight = deadZoneHeight / 2

        var panDir: PTZMotion.PanDirection = .stop
        var tiltDir: PTZMotion.TiltDirection = .stop

        if abs(dx) > halfWidth {
            let goingRight = dx > 0
            let panRight = invertPan ? !goingRight : goingRight
            panDir = panRight ? .right : .left
        }

        if abs(dy) > halfHeight {
            let goingUp = dy > 0
            let tiltUp = invertTilt ? !goingUp : goingUp
            tiltDir = tiltUp ? .up : .down
        }

        if panDir == .stop && tiltDir == .stop {
            return .idle
        }

        let panMag = max(0, abs(dx) - halfWidth) / (0.5 - halfWidth)
        let tiltMag = max(0, abs(dy) - halfHeight) / (0.5 - halfHeight)
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
        guard currentMotion == motion, trackingEnabled else { return }
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
            return await self.handleCompanion(action)
        }
        companionServer = server
        do {
            try server.start()
            connection.companionListening = true
            connection.companionURL = Self.lanAddresses()
                .map { "http://\($0):\(settings.companionPort)" }
                .joined(separator: "\n")
        } catch {
            connection.companionListening = false
            connection.companionURL = ""
            connection.lastViscaError = "Companion HTTP failed: \(error.localizedDescription)"
        }
    }

    private func handleCompanion(_ action: CompanionHTTPServer.Action) async -> CompanionHTTPServer.Response {
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
        case let .preset(slot, operation):
            return await sendPreset(slot, operation: operation)
        }
    }

    private func sendPreset(
        _ slot: UInt8, operation: CompanionHTTPServer.PresetOperation
    ) async -> CompanionHTTPServer.Response {
        let response: CompanionHTTPServer.Response
        if trackingEnabled || currentMotion != .idle {
            response = .init(status: 409, body: "Turn tracking off before saving or recalling a preset.")
        } else if sendingPreset {
            response = .init(status: 409, body: "Another preset command is being sent.")
        } else if configuredPresetHead != settings.presetHead {
            response = .init(status: 409, body: "Reconnect the head to apply its new address or camera ID.")
        } else {
            let head = settings.presetHead
            sendingPreset = true
            defer { sendingPreset = false }

            do {
                connection.lastCommandHex = try await visca.sendPreset(slot, recall: operation == .recall)
                if operation == .save { settings.markPresetSaved(slot, for: head) }
                let name = slot == 5 ? "Center" : "Memory \(slot)"
                let action = operation == .save ? "Save" : "Recall"
                response = .init(status: 202, body: "\(action) command sent for \(name).")
            } catch {
                response = .init(status: 503, body: "Could not send preset command. Check the head connection.")
            }
        }
        presetMessage = response.body
        return response
    }

    private func statusJSON() -> String {
        let tracking = trackingEnabled
        let viscaOK = connection.viscaConnected
        let hasTarget = currentTarget != nil
        return """
        {"tracking":\(tracking),"viscaConnected":\(viscaOK),"hasTarget":\(hasTarget),"camera":"\(settings.cameraIP):\(settings.cameraPort)"}
        """
    }

    private static func lanAddresses() -> [String] {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return ["127.0.0.1"] }
        defer { freeifaddrs(interfaces) }

        var addresses = Set<String>()
        var cursor: UnsafeMutablePointer<ifaddrs>? = first
        while let current = cursor {
            let interface = current.pointee
            cursor = interface.ifa_next
            guard interface.ifa_flags & UInt32(IFF_UP | IFF_RUNNING) == UInt32(IFF_UP | IFF_RUNNING),
                  interface.ifa_flags & UInt32(IFF_LOOPBACK) == 0,
                  let address = interface.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &hostname,
                           socklen_t(hostname.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.insert(String(cString: hostname))
            }
        }
        return addresses.isEmpty ? ["127.0.0.1"] : addresses.sorted()
    }
}
