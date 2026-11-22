import CoreGraphics
import Foundation

struct TrackedTarget: Equatable {
    /// Normalized Vision rect (origin bottom-left).
    var boundingBox: CGRect
    var confidence: Float
    var center: CGPoint {
        CGPoint(x: boundingBox.midX, y: boundingBox.midY)
    }
}

enum PTZMotion: Equatable {
    case idle
    case moving(pan: PanDirection, tilt: TiltDirection, panSpeed: UInt8, tiltSpeed: UInt8)

    enum PanDirection: Equatable {
        case left, right, stop
    }

    enum TiltDirection: Equatable {
        case up, down, stop
    }
}

struct ConnectionStatus: Equatable {
    var viscaConnected: Bool = false
    var lastViscaError: String?
    var companionListening: Bool = false
    var companionURL: String = ""
    var lastCommandHex: String = ""
}
