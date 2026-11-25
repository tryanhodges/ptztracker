import Foundation
import CoreGraphics

@MainActor
struct MotionEngine {
    private var recentering = false
    var panPoint: SpeedCurve.Point? { panCurveTracking.displayPoint }
    var tiltPoint: SpeedCurve.Point? { tiltCurveTracking.displayPoint }
    private var lastTargetSample: (center: CGPoint, time: TimeInterval)?
    private var targetVelocity = CGVector.zero
    private var driveSpeed = CGVector.zero
    private var panCurveTracking = CurveAxisTracking()
    private var tiltCurveTracking = CurveAxisTracking()
    private var lastSpeedMode: TrackingSpeedMode?

    mutating func evaluate(_ target: TrackedTarget, at frameTime: Double, settings: AppSettings,
                           mode: TrackingSpeedMode? = nil) -> PTZMotion {
        let speedMode = mode ?? settings.trackingSpeedMode
        if speedMode != lastSpeedMode {
            self = Self()
            lastSpeedMode = speedMode
        }
        let elapsed = lastTargetSample.map { frameTime - $0.time } ?? (1.0 / 15)
        if elapsed > 0.35 {
            driveSpeed = .zero
            panCurveTracking = CurveAxisTracking()
            tiltCurveTracking = CurveAxisTracking()
        }
        updateTargetVelocity(center: target.center, frameTime: frameTime)
        if let slot = speedMode.slot {
            let profile = settings.trackingSpeedProfiles[slot]
            let anchor = settings.framingPoint
            let interval = min(elapsed, 0.1)
            let pan = panCurveTracking.command(
                error: target.center.x - anchor.x, anchor: anchor.x,
                halfBox: settings.deadZoneWidth / 2, drift: targetVelocity.dx,
                elapsed: interval, curve: profile.pan
            )
            let tilt = tiltCurveTracking.command(
                error: target.center.y - (1 - anchor.y), anchor: 1 - anchor.y,
                halfBox: settings.deadZoneHeight / 2, drift: targetVelocity.dy,
                elapsed: interval, curve: profile.tilt
            )
            return Self.motion(pan: (pan * 0x18).rounded(), tilt: (tilt * 0x14).rounded(),
                                 invertPan: settings.invertPan, invertTilt: settings.invertTilt)
        } else {
            return Self.computeMotion(
                for: target,
                framingPoint: settings.framingPoint,
                deadZoneWidth: settings.deadZoneWidth,
                deadZoneHeight: settings.deadZoneHeight,
                reactionSpeed: settings.reactionSpeed,
                invertPan: settings.invertPan,
                invertTilt: settings.invertTilt,
                velocity: targetVelocity,
                elapsed: elapsed,
                driveSpeed: &driveSpeed,
                recentering: &recentering
            )
        }
    }

    private mutating func updateTargetVelocity(center: CGPoint, frameTime: TimeInterval) {
        defer { lastTargetSample = (center, frameTime) }
        guard let previous = lastTargetSample else { return }
        let elapsed = frameTime - previous.time
        let dx = center.x - previous.center.x
        let dy = center.y - previous.center.y
        // Discard stale samples and large detection jumps before estimating drift.
        guard elapsed > 0, elapsed <= 0.35, hypot(dx, dy) <= 0.22 else {
            targetVelocity = .zero
            return
        }
        let weight = 1 - exp(-elapsed / 0.08)
        targetVelocity.dx += (dx / elapsed - targetVelocity.dx) * weight
        targetVelocity.dy += (dy / elapsed - targetVelocity.dy) * weight
    }

    /// Vision coords: origin bottom-left, x/y in 0…1.
    private nonisolated static func computeMotion(
        for target: TrackedTarget,
        framingPoint: CGPoint,
        deadZoneWidth: Double,
        deadZoneHeight: Double,
        reactionSpeed: Double,
        invertPan: Bool,
        invertTilt: Bool,
        velocity: CGVector,
        elapsed: TimeInterval,
        driveSpeed: inout CGVector,
        recentering: inout Bool
    ) -> PTZMotion {
        let anchorY = 1 - framingPoint.y
        let dx = target.center.x - framingPoint.x
        let dy = target.center.y - anchorY
        let halfWidth = deadZoneWidth / 2
        let halfHeight = deadZoneHeight / 2
        // Lead a moving subject near the outer edge and keep correcting while the head slows.
        if !recentering {
            guard approachesEdge(error: dx, drift: velocity.dx, halfSize: halfWidth)
                    || approachesEdge(error: dy, drift: velocity.dy, halfSize: halfHeight)
            else { return .idle }
            recentering = true
        }
        let panTolerance = min(0.02, halfWidth / 2)
        let tiltTolerance = min(0.02, halfHeight / 2)

        let panMag = correctionMagnitude(error: dx, tolerance: panTolerance, drift: velocity.dx, lookahead: 0.45)
        let tiltMag = correctionMagnitude(error: dy, tolerance: tiltTolerance, drift: velocity.dy, lookahead: 0.55)
        let desiredPan = signedSpeed(error: dx, magnitude: panMag, reactionSpeed: reactionSpeed, limit: 0x18)
        let desiredTilt = signedSpeed(error: dy, magnitude: tiltMag, reactionSpeed: reactionSpeed, limit: 0x14)

        driveSpeed.dx = easedSpeed(current: driveSpeed.dx, desired: desiredPan, elapsed: elapsed)
        driveSpeed.dy = easedSpeed(current: driveSpeed.dy, desired: desiredTilt, elapsed: elapsed)
        guard driveSpeed != .zero else {
            recentering = false
            return .idle
        }

        return motion(pan: driveSpeed.dx, tilt: driveSpeed.dy, invertPan: invertPan, invertTilt: invertTilt)
    }

    private nonisolated static func motion(
        pan panCommand: Double, tilt tiltCommand: Double, invertPan: Bool, invertTilt: Bool
    ) -> PTZMotion {
        let pan = invertPan ? -panCommand : panCommand
        let tilt = invertTilt ? -tiltCommand : tiltCommand
        guard pan != 0 || tilt != 0 else { return .idle }
        return .moving(
            pan: pan == 0 ? .stop : (pan > 0 ? .right : .left),
            tilt: tilt == 0 ? .stop : (tilt > 0 ? .up : .down),
            panSpeed: UInt8(max(1, abs(pan).rounded())),
            tiltSpeed: UInt8(max(1, abs(tilt).rounded()))
        )
    }

    private nonisolated static func easedSpeed(current: Double, desired: Double, elapsed: TimeInterval) -> Double {
        // Apply increases immediately. Shed speed over time and brake to zero before reversing.
        let sameDirection = current * desired >= 0
        if sameDirection, abs(desired) >= abs(current) { return desired }

        let goal = sameDirection ? abs(desired) : 0
        let magnitude = max(goal, abs(current) - 26 * max(0, elapsed))
        return magnitude < 0.5 ? 0 : (current > 0 ? magnitude : -magnitude)
    }

    private nonisolated static func approachesEdge(error: Double, drift: Double, halfSize: Double) -> Bool {
        let outwardDrift = error > 0 ? drift : -drift
        let lead = min(0.03, halfSize * 0.25, max(0, outwardDrift) * 0.15)
        return abs(error) + lead > halfSize
    }

    private nonisolated static func correctionMagnitude(
        error: Double, tolerance: Double, drift: Double, lookahead: TimeInterval
    ) -> Double {
        let distance = abs(error) - tolerance
        guard distance > 0 else { return 0 }
        let outwardDrift = error > 0 ? drift : -drift
        // Boost outward corrections, and slow down as the target approaches the crosshair.
        let adjustment = min(0.30, max(-distance * 0.5, outwardDrift * lookahead))
        return (distance + adjustment) / (0.28 - tolerance)
    }

    private nonisolated static func signedSpeed(
        error: Double, magnitude: Double, reactionSpeed: Double, limit: Double
    ) -> Double {
        guard magnitude > 0 else { return 0 }
        let speed = min(limit, 1 + magnitude * reactionSpeed * 23)
        return error > 0 ? speed : -speed
    }

}
