import AVFoundation
import Combine
import CoreImage

@MainActor
final class CameraCaptureService: NSObject, ObservableObject {
    @Published private(set) var devices: [AVCaptureDevice] = []
    @Published private(set) var isRunning = false
    @Published private(set) var authorizationDenied = false
    @Published private(set) var errorMessage: String?

    let session = AVCaptureSession()
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
        errorMessage = nil
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.session.sessionPreset = .hd1280x720

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
                if self.session.canAddInput(input) {
                    self.session.addInput(input)
                }

                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                self.videoOutput.setSampleBufferDelegate(self, queue: DispatchQueue(label: "ptz.camera.frames", qos: .userInitiated))
                if self.session.canAddOutput(self.videoOutput) {
                    self.session.addOutput(self.videoOutput)
                }

                self.session.commitConfiguration()
                self.session.startRunning()
                DispatchQueue.main.async {
                    self.isRunning = true
                    self.errorMessage = nil
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
        sessionQueue.async { [weak self] in
            self?.session.stopRunning()
            DispatchQueue.main.async {
                self?.isRunning = false
            }
        }
    }

    private func preferredDevice() -> AVCaptureDevice? {
        // Prefer external (Thunderbolt / USB capture) over built-in.
        if let external = devices.first(where: { $0.deviceType == .external }) {
            return external
        }
        return devices.first ?? AVCaptureDevice.default(for: .video)
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
            self.frameHandler?(pixelBuffer, time)
        }
    }
}
