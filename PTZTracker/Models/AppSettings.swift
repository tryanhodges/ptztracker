import Foundation
import Combine

@MainActor
final class AppSettings: ObservableObject {
    @Published var cameraIP: String {
        didSet { defaults.set(cameraIP, forKey: Keys.cameraIP) }
    }

    @Published var cameraPort: Int {
        didSet { defaults.set(cameraPort, forKey: Keys.cameraPort) }
    }

    @Published var deviceAddress: Int {
        didSet { defaults.set(deviceAddress, forKey: Keys.deviceAddress) }
    }

    /// How aggressively pan/tilt speed scales with target offset (0.1 … 1.0).
    @Published var reactionSpeed: Double {
        didSet { defaults.set(reactionSpeed, forKey: Keys.reactionSpeed) }
    }

    /// Dead-zone around frame center as a fraction of half-width/height (0.02 … 0.4).
    @Published var bufferZone: Double {
        didSet { defaults.set(bufferZone, forKey: Keys.bufferZone) }
    }

    /// Minimum detection confidence (0.1 … 0.95).
    @Published var sensitivity: Double {
        didSet { defaults.set(sensitivity, forKey: Keys.sensitivity) }
    }

    @Published var invertPan: Bool {
        didSet { defaults.set(invertPan, forKey: Keys.invertPan) }
    }

    @Published var invertTilt: Bool {
        didSet { defaults.set(invertTilt, forKey: Keys.invertTilt) }
    }

    @Published var companionPort: Int {
        didSet { defaults.set(companionPort, forKey: Keys.companionPort) }
    }

    @Published var selectedDeviceID: String? {
        didSet { defaults.set(selectedDeviceID, forKey: Keys.selectedDeviceID) }
    }

    @Published var trackingMode: TrackingMode {
        didSet { defaults.set(trackingMode.rawValue, forKey: Keys.trackingMode) }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cameraIP = "cameraIP"
        static let cameraPort = "cameraPort"
        static let deviceAddress = "deviceAddress"
        static let reactionSpeed = "reactionSpeed"
        static let bufferZone = "bufferZone"
        static let sensitivity = "sensitivity"
        static let invertPan = "invertPan"
        static let invertTilt = "invertTilt"
        static let companionPort = "companionPort"
        static let selectedDeviceID = "selectedDeviceID"
        static let trackingMode = "trackingMode"
    }

    init() {
        let d = UserDefaults.standard
        cameraIP = d.string(forKey: Keys.cameraIP) ?? "192.168.1.188"
        let port = d.object(forKey: Keys.cameraPort) as? Int
        cameraPort = port ?? 5002
        let addr = d.object(forKey: Keys.deviceAddress) as? Int
        deviceAddress = addr ?? 1
        let speed = d.object(forKey: Keys.reactionSpeed) as? Double
        reactionSpeed = speed ?? 0.55
        let buffer = d.object(forKey: Keys.bufferZone) as? Double
        bufferZone = buffer ?? 0.12
        let sens = d.object(forKey: Keys.sensitivity) as? Double
        sensitivity = sens ?? 0.45
        invertPan = d.object(forKey: Keys.invertPan) as? Bool ?? false
        invertTilt = d.object(forKey: Keys.invertTilt) as? Bool ?? false
        let cPort = d.object(forKey: Keys.companionPort) as? Int
        companionPort = cPort ?? 18787
        selectedDeviceID = d.string(forKey: Keys.selectedDeviceID)
        if let raw = d.string(forKey: Keys.trackingMode),
           let mode = TrackingMode(rawValue: raw) {
            trackingMode = mode
        } else {
            trackingMode = .human
        }
    }
}

enum TrackingMode: String, CaseIterable, Identifiable {
    case human
    case face

    var id: String { rawValue }

    var title: String {
        switch self {
        case .human: return "Person"
        case .face: return "Face"
        }
    }
}
