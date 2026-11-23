import AVFoundation
import Combine
import CoreImage

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var receivedVideoFrame = false
    @Published private(set) var captureFormatDescription: String?
    @Published private(set) var videoAspectRatio: CGFloat = 16.0 / 9.0
    @Published private(set) var authorizationDenied = false
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
    let deckLinkPreview = AVSampleBufferDisplayLayer()
    @Published private(set) var usingDeckLink = false
    private var deckLinkCapture: UnsafeMutableRawPointer?
    private var deckLinkFrames: Task<Void, Never>?
    private var deckLinkSampleFormat: CMVideoFormatDescription?
    private var lastDeckLinkFrame: ContinuousClock.Instant?
    var onDeckLinkSignalLost: (() -> Void)?
    private let sessionQueue = DispatchQueue(label: "ptz.camera.session")
    private let videoOutput = AVCaptureVideoDataOutput()
    private var frameHandler: ((CVPixelBuffer, CMTime) -> Void)?

    override init() {
        super.init()
        refreshDevices()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesChanged),
            name: .AVCaptureDeviceWasConnected,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(devicesChanged),
            name: .AVCaptureDeviceWasDisconnected,
            object: nil
        )
    }

    /// Called on a background queue — not the main thread.
    func setFrameHandler(_ handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
        frameHandler = handler
    }

    func refreshDevices() {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .external,
                .builtInWideAngleCamera,
                .continuityCamera,
                .deskViewCamera
            ],
            mediaType: .video,
            position: .unspecified
        )
        devices = discovery.devices
    }

    @objc private func devicesChanged() {
        refreshDevices()
    }

    func requestAccessAndStart(deviceID: String?) async {
        let device = deviceID.flatMap { AVCaptureDevice(uniqueID: $0) } ?? preferredDevice()
        if let device, device.localizedName.contains("UltraStudio HD Mini") {
            startDeckLink()
            return
        }
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            if !granted {
                authorizationDenied = true
                return
            }
        default:
            authorizationDenied = true
            return
        }
        authorizationDenied = false
        start(deviceID: deviceID)
    }

    func start(deviceID: String?) {
        stopDeckLink()
        errorMessage = nil
        receivedVideoFrame = false
        captureFormatDescription = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()

            self.session.inputs.forEach { self.session.removeInput($0) }
            self.session.outputs.forEach { self.session.removeOutput($0) }

            let device: AVCaptureDevice?
            if let deviceID,
               let match = AVCaptureDevice(uniqueID: deviceID) {
                device = match
            } else {
                device = self.preferredDevice()
            }

            guard let device else {
                DispatchQueue.main.async {
                    self.errorMessage = "No video input device found. Connect your Thunderbolt capture source."
                    self.isRunning = false
                }
                self.session.commitConfiguration()
                return
            }

            do {
                let input = try AVCaptureDeviceInput(device: device)
                guard self.session.canAddInput(input) else {
                    throw CaptureError.inputUnavailable(device.localizedName)
                }
                self.session.addInput(input)

                // External capture devices can supply formats other than 720p.
                let preferredPreset: AVCaptureSession.Preset =
                    device.deviceType == .external ? .high : .hd1280x720
                if self.session.canSetSessionPreset(preferredPreset) {
                    self.session.sessionPreset = preferredPreset
                } else if self.session.canSetSessionPreset(.high) {
                    self.session.sessionPreset = .high
                }

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [:]
                self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ptz.camera.frames", qos: .userInitiated))
                guard self.session.canAddOutput(self.videoOutput) else {
                    throw CaptureError.outputUnavailable
                }
                self.session.addOutput(self.videoOutput)

                self.session.commitConfiguration()
                self.session.startRunning()
                let running = self.session.isRunning
                let activeFormat = device.activeFormat.formatDescription
                let dimensions = CMVideoFormatDescriptionGetDimensions(activeFormat)
                let displaySize = CMVideoFormatDescriptionGetPresentationDimensions(
                    activeFormat, usePixelAspectRatio: true, useCleanAperture: true
                )
                let fields = CMFormatDescriptionGetExtension(
                    activeFormat, extensionKey: kCMFormatDescriptionExtension_FieldCount
                ) as? Int
                let scan = fields == 2 ? "interlaced" : "no interlace metadata"
                let formatDescription = "\(dimensions.width) × \(dimensions.height), \(scan)"
                DispatchQueue.main.async {
                    self.isRunning = running
                    self.captureFormatDescription = formatDescription
                    if displaySize.width > 0, displaySize.height > 0 {
                        self.videoAspectRatio = displaySize.width / displaySize.height
                    }
                    self.errorMessage = running ? nil : "Could not start \(device.localizedName)."
                }
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async {
                    self.errorMessage = error.localizedDescription
                    self.isRunning = false
                }
            }
        }
    }

    func stop() {
        stopDeckLink()
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }

    private func startDeckLink() {
        stopDeckLink()
        authorizationDenied = false
        errorMessage = nil
        receivedVideoFrame = false
        captureFormatDescription = nil
        isRunning = false

        let session = self.session
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
            session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }
            session.commitConfiguration()
        }

        var failure: UnsafePointer<CChar>?
        guard let capture = PTZDeckLinkOpen(&failure) else {
            errorMessage = failure.map { String(cString: $0) } ?? "Could not start DeckLink capture."
            return
        }

        deckLinkCapture = capture
        videoAspectRatio = 16.0 / 9.0
        usingDeckLink = true
        isRunning = true
        captureFormatDescription = "DeckLink · 1080i60 SDI"
        deckLinkPreview.videoGravity = .resizeAspect
        deckLinkFrames = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.readDeckLinkFrame()
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func stopDeckLink() {
        guard let capture = deckLinkCapture else { return }
        deckLinkFrames?.cancel()
        deckLinkFrames = nil
        PTZDeckLinkClose(capture)
        deckLinkCapture = nil
        deckLinkSampleFormat = nil
        lastDeckLinkFrame = nil
        usingDeckLink = false
        receivedVideoFrame = false
        deckLinkPreview.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        onDeckLinkSignalLost?()
    }

    private func readDeckLinkFrame() {
        guard let capture = deckLinkCapture else { return }
        let now = ContinuousClock.now
        guard let frame = PTZDeckLinkCopyFrame(capture) else {
            if let lastDeckLinkFrame, now - lastDeckLinkFrame > .milliseconds(500) {
                self.lastDeckLinkFrame = nil
                receivedVideoFrame = false
                deckLinkPreview.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
                onDeckLinkSignalLost?()
            }
            return
        }

        lastDeckLinkFrame = now
        if !receivedVideoFrame { receivedVideoFrame = true }
        let time = CMClockGetTime(CMClockGetHostTimeClock())
        frameHandler?(frame, time)

        if deckLinkSampleFormat == nil {
            CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescriptionOut: &deckLinkSampleFormat
            )
        }
        let renderer = deckLinkPreview.sampleBufferRenderer
        if renderer.requiresFlushToResumeDecoding { renderer.flush() }
        guard let deckLinkSampleFormat, renderer.isReadyForMoreMediaData else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: time, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: frame, formatDescription: deckLinkSampleFormat,
            sampleTiming: &timing, sampleBufferOut: &sample
        )
        guard let sample,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
        else { return }
        let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(attachment, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                             Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        renderer.enqueue(sample)
    }

    private func preferredDevice() -> AVCaptureDevice? {
        // Prefer external (Thunderbolt / USB capture) over built-in.
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        return devices.first ?? AVCaptureDevice.default(for: .video)
    }
}

private enum CaptureError: LocalizedError {
    case inputUnavailable(String)
    case outputUnavailable

    var errorDescription: String? {
        switch self {
        case .inputUnavailable(let name):
            return "Could not add \(name) as a video input."
        case .outputUnavailable:
            return "Could not configure the video output for this input."
        }
    }
}

extension CameraCaptureService: AVCaptureVideoDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        // Handler runs on the video output queue (background).
        Task { @MainActor in
            guard !self.usingDeckLink else { return }
            if !self.receivedVideoFrame { self.receivedVideoFrame = true }
            self.frameHandler?(pixelBuffer, time)
        }
    }
}
