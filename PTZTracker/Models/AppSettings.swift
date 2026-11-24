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

    static let centerReturnDelayRange = 0...120

    @Published var centerReturnDelay: Int {
        didSet { defaults.set(centerReturnDelay, forKey: Keys.centerReturnDelay) }
    }

    /// Preferred target center in normalized image coordinates, measured from the top left.
    @Published private(set) var framingPoint: CGPoint {
        didSet { defaults.set([Double(framingPoint.x), Double(framingPoint.y)], forKey: Keys.framingPoint) }
    }

    func setFramingPoint(_ point: CGPoint) {
        let point = Self.clampedFramingPoint(point)
        if framingPoint != point { framingPoint = point }
    }

    private static func clampedFramingPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: point.x.isFinite ? min(1, max(0, point.x)) : 0.5,
            y: point.y.isFinite ? min(1, max(0, point.y)) : 0.5
        )
    }

    /// Full dead-zone dimensions as fractions of the video frame.
    @Published var deadZoneWidth: Double {
        didSet { defaults.set(deadZoneWidth, forKey: Keys.deadZoneWidth) }
    }

    @Published var deadZoneHeight: Double {
        didSet { defaults.set(deadZoneHeight, forKey: Keys.deadZoneHeight) }
    }

    static let deadZoneSizeRange = 0.04...0.8

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

    @Published private(set) var savedPresetSlotsByHead: [String: [Int]] {
        didSet { defaults.set(savedPresetSlotsByHead, forKey: Keys.savedPresetSlotsByHead) }
    }

    var presetHead: String {
        "\(cameraIP):\(cameraPort)/\(deviceAddress)"
    }

    func isPresetMarkedSaved(_ slot: UInt8) -> Bool {
        savedPresetSlotsByHead[presetHead]?.contains(Int(slot)) == true
    }

    func markPresetSaved(_ slot: UInt8, for head: String) {
        var slots = Set(savedPresetSlotsByHead[head] ?? [])
        if slots.insert(Int(slot)).inserted {
            savedPresetSlotsByHead[head] = slots.sorted()
        }
    }

    func unmarkPresetSaved(_ slot: UInt8, for head: String) {
        guard var slots = savedPresetSlotsByHead[head] else { return }
        slots.removeAll { $0 == Int(slot) }
        savedPresetSlotsByHead[head] = slots.isEmpty ? nil : slots
    }

    @Published private(set) var ignoreZones: [IgnoreZone] {
        didSet {
            if let data = try? JSONEncoder().encode(ignoreZones) {
                defaults.set(data, forKey: Keys.ignoreZones)
            }
        }
    }

    func addIgnoreZone(_ rect: CGRect) {
        ignoreZones.append(IgnoreZone(rect: rect))
    }

    func removeIgnoreZone(_ id: UUID) {
        ignoreZones.removeAll { $0.id == id }
    }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let cameraIP = "cameraIP"
        static let ignoreZones = "ignoreZones"
        static let savedPresetSlotsByHead = "savedPresetSlotsByHead"
        static let cameraPort = "cameraPort"
        static let deviceAddress = "deviceAddress"
        static let reactionSpeed = "reactionSpeed"
        static let centerReturnDelay = "centerReturnDelay"
        static let legacyBufferZone = "bufferZone"
        static let deadZoneWidth = "deadZoneWidth"
        static let deadZoneHeight = "deadZoneHeight"
        static let framingPoint = "framingPoint"
        static let sensitivity = "sensitivity"
        static let invertPan = "invertPan"
        static let invertTilt = "invertTilt"
        static let companionPort = "companionPort"
        static let selectedDeviceID = "selectedDeviceID"
        static let trackingMode = "trackingMode"
    }

    private static func clampedDeadZoneSize(_ size: Double) -> Double {
        guard size.isFinite else { return 0.24 }
        return min(deadZoneSizeRange.upperBound, max(deadZoneSizeRange.lowerBound, size))
    }

    init() {
        let d = UserDefaults.standard
        ignoreZones = d.data(forKey: Keys.ignoreZones)
            .flatMap { try? JSONDecoder().decode([IgnoreZone].self, from: $0) } ?? []
        savedPresetSlotsByHead = d.dictionary(forKey: Keys.savedPresetSlotsByHead) as? [String: [Int]] ?? [:]
        cameraIP = d.string(forKey: Keys.cameraIP) ?? "192.168.1.188"
        let port = d.object(forKey: Keys.cameraPort) as? Int
        cameraPort = port ?? 5002
        let addr = d.object(forKey: Keys.deviceAddress) as? Int
        deviceAddress = addr ?? 1
        let speed = d.object(forKey: Keys.reactionSpeed) as? Double
        reactionSpeed = speed ?? 0.55
        let delay = d.integer(forKey: Keys.centerReturnDelay)
        centerReturnDelay = min(Self.centerReturnDelayRange.upperBound,
                                max(Self.centerReturnDelayRange.lowerBound, delay))
        let legacyHalfSize = d.object(forKey: Keys.legacyBufferZone) as? Double ?? 0.12
        deadZoneWidth = Self.clampedDeadZoneSize(d.object(forKey: Keys.deadZoneWidth) as? Double ?? legacyHalfSize * 2)
        deadZoneHeight = Self.clampedDeadZoneSize(d.object(forKey: Keys.deadZoneHeight) as? Double ?? legacyHalfSize * 2)
        let framing = d.array(forKey: Keys.framingPoint) as? [Double]
        if let framing, framing.count == 2 {
            framingPoint = Self.clampedFramingPoint(CGPoint(x: framing[0], y: framing[1]))
        } else {
            framingPoint = CGPoint(x: 0.5, y: 0.5)
        }
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

struct IgnoreZone: Codable, Identifiable, Equatable {
    var id = UUID()
    /// Normalized image rectangle, with Vision’s bottom-left origin.
    let rect: CGRect
}
