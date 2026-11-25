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
            if trackingEnabled && controlPanelTab == .rehearsal { trackingEnabled = false; return }
            guard trackingEnabled != oldValue else { return }
            targetRevision += 1
            if !trackingEnabled {
                resetTargetLoss()
                resetTargetMotion()
                Task { await stopHead() }
            }
        }
    }

    @Published var showingSpeedCurveEditor = false
    @Published var controlPanelTab: ControlPanelTab = .tracking {
        didSet {
            if controlPanelTab == .rehearsal { trackingEnabled = false }
            if oldValue == .rehearsal { rehearsal.leaveTab() }
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
    func clearAllPresets() async {
        guard !trackingEnabled, currentMotion == .idle, !sendingPreset else { return }
        let head = settings.presetHead
        guard configuredPresetHead == head else {
            presetMessage = "Reconnect the head before clearing presets."
            return
        }
        sendingPreset = true
        defer { sendingPreset = false }

        var cleared = 0
        for slot in UInt8(1)...UInt8(5) {
            guard configuredPresetHead == head, !trackingEnabled else { break }
            do {
                connection.lastCommandHex = try await visca.resetPreset(slot)
                settings.unmarkPresetSaved(slot, for: head)
                cleared += 1
            } catch {
                break
            }
        }
        presetMessage = "Reset commands sent for \(cleared) of 5 positions."
    }

    private let visionQueue = DispatchQueue(label: "ptz.vision", qos: .userInitiated)
    private let vision = VisionTrackingService()
    private var companionServer: CompanionHTTPServer?
    @Published private(set) var sendingPreset = false
    @Published var confirmingPresetClear = false
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
    private var engine = MotionEngine()
    @Published private(set) var panPoint: SpeedCurve.Point?
    @Published private(set) var tiltPoint: SpeedCurve.Point?
    let rehearsal = RehearsalSession()

    private var hasTrackedSubject = false
    private var subjectLostAt: TimeInterval?
    @Published private(set) var centerReturnMessage: String?
    init(settings: AppSettings, camera: CameraCaptureService) {
        self.settings = settings
        self.camera = camera
        camera.setFrameHandler { [weak self] buffer, time in
            self?.rehearsal.append(buffer, time: time)
            self?.enqueueFrame(buffer)
        }
        camera.onSignalLost = { [weak self] in
            guard let self else { return }
            self.rehearsal.signalLost()
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

    private func resetTargetMotion() {
        engine = MotionEngine()
        panPoint = nil
        tiltPoint = nil
    }

    private func resetTargetLoss() {
        hasTrackedSubject = false
        subjectLostAt = nil
        centerReturnMessage = nil
    }

    func clearPrimaryTarget() {
        resetTargetLoss()
        resetTargetMotion()
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

    func addIgnoreZone(_ rect: CGRect) {
        settings.addIgnoreZone(rect)
        targetCandidates.removeAll { rect.contains($0.center) }
        if let currentTarget, rect.contains(currentTarget.center) {
            clearPrimaryTarget()
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
        let frameTime = ProcessInfo.processInfo.systemUptime

        if lastTrackingMode != mode {
            lastTrackingMode = mode
            clearPrimaryTarget()
        }

        let revision = targetRevision
        let ignoreZones = settings.ignoreZones
        let manual = manualTargetSelection
        let hasSelection = primaryTargetSelected
        visionQueue.async { [weak self, vision] in
            let target: TrackedTarget?
            let candidates: [TrackedTarget]
            if !manual {
                target = vision.detect(pixelBuffer: pixelBuffer, mode: mode, minConfidence: confidence, ignoreZones: ignoreZones)
                candidates = []
            } else if hasSelection {
                target = vision.followSelectedTarget(pixelBuffer: pixelBuffer, minConfidence: confidence, ignoreZones: ignoreZones)
                candidates = []
            } else {
                target = nil
                candidates = vision.candidates(pixelBuffer: pixelBuffer, mode: mode, minConfidence: confidence, ignoreZones: ignoreZones)
            }

            let selectionLost = hasSelection && !vision.hasActiveTracker
            Task { @MainActor in
                guard let self else { return }
                self.processingFrame = false
                guard self.targetRevision == revision, self.settings.trackingMode == mode,
                      self.settings.ignoreZones == ignoreZones else { return }
                if selectionLost { self.primaryTargetSelected = false }
                self.targetCandidates = candidates
                self.applyFrameResult(target: target, trackingOn: trackingOn, frameTime: frameTime)
            }
        }
    }

    private func applyFrameResult(target: TrackedTarget?, trackingOn: Bool, frameTime: TimeInterval) {
        framesProcessed += 1
        currentTarget = target

        guard trackingOn, trackingEnabled else {
            resetTargetMotion()
            if currentMotion != .idle {
                currentMotion = .idle
                Task { await stopHead() }
            }
            return
        }

        guard !sendingPreset else { return }

        let motion: PTZMotion
        if let target {
            hasTrackedSubject = true
            subjectLostAt = nil
            centerReturnMessage = nil
            motion = engine.evaluate(target, at: frameTime, settings: settings)
            panPoint = engine.panPoint
            tiltPoint = engine.tiltPoint
        } else {
            resetTargetMotion()
            motion = .idle
            if hasTrackedSubject, subjectLostAt == nil {
                subjectLostAt = frameTime
            }
        }

        if currentMotion != motion {
            currentMotion = motion
            Task { await dispatchMotion(motion) }
        } else if case .moving = motion {
            // Keep refreshing VISCA while moving so identical keys can be skipped inside the client,
            // but still allow reconnect recovery.
            Task { await dispatchMotion(motion) }
        }

        if target == nil, let subjectLostAt, settings.centerReturnDelay > 0,
           frameTime - subjectLostAt >= Double(settings.centerReturnDelay) {
            hasTrackedSubject = false
            self.subjectLostAt = nil
            let revision = targetRevision
            Task { await returnToCenter(revision: revision) }
        }
    }

    private func returnToCenter(revision: Int) async {
        guard trackingEnabled, revision == targetRevision, currentTarget == nil,
              !sendingPreset, settings.centerReturnDelay > 0 else { return }
        guard configuredPresetHead == settings.presetHead else {
            centerReturnMessage = "Reconnect the head to use Return to Center."
            return
        }
        sendingPreset = true
        defer { sendingPreset = false }
        do {
            connection.lastCommandHex = try await visca.sendPreset(5, recall: true)
            if trackingEnabled, revision == targetRevision, currentTarget == nil {
                centerReturnMessage = "Center recall sent."
            }
        } catch {
            if trackingEnabled, revision == targetRevision, currentTarget == nil {
                centerReturnMessage = "Could not recall Center. Check the head connection."
            }
        }
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
        case let .speedMode(mode):
            settings.trackingSpeedMode = mode
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
        {"tracking":\(tracking),"viscaConnected":\(viscaOK),"hasTarget":\(hasTarget),"speedMode":"\(settings.trackingSpeedMode.rawValue)","camera":"\(settings.cameraIP):\(settings.cameraPort)"}
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
