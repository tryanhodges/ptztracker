import CoreGraphics
import Vision

/// Apple Vision person/face detection with optional object tracking lock.
final class VisionTrackingService {
    private let sequenceHandler = VNSequenceRequestHandler()
    private var activeTracker: VNTrackObjectRequest?
    private var lostFrames = 0
    private let maxLostFrames = 12

    func reset() {
        activeTracker = nil
        lostFrames = 0
    }

    func detect(
        pixelBuffer: CVPixelBuffer,
        mode: TrackingMode,
        minConfidence: Float,
        ignoreZones: [IgnoreZone]
    ) -> TrackedTarget? {
        if let tracked = continueTracking(pixelBuffer: pixelBuffer, minConfidence: minConfidence) {
            if !ignoreZones.contains(where: { $0.rect.contains(tracked.center) }) { return tracked }
            reset()
        }

        let eligible = candidates(pixelBuffer: pixelBuffer, mode: mode, minConfidence: minConfidence,
                                  ignoreZones: ignoreZones)
        guard let seeded = eligible.max(by: { $0.boundingBox.area < $1.boundingBox.area }) else {
            return nil
        }

        lock(on: seeded)
        return seeded
    }

    func lock(on target: TrackedTarget) {
        let observation = VNDetectedObjectObservation(boundingBox: target.boundingBox)
        let tracker = VNTrackObjectRequest(detectedObjectObservation: observation)
        tracker.trackingLevel = .accurate
        activeTracker = tracker
        lostFrames = 0
    }

    func followSelectedTarget(
        pixelBuffer: CVPixelBuffer, minConfidence: Float, ignoreZones: [IgnoreZone]
    ) -> TrackedTarget? {
        guard let target = continueTracking(pixelBuffer: pixelBuffer, minConfidence: minConfidence),
              !ignoreZones.contains(where: { $0.rect.contains(target.center) }) else {
            reset()
            return nil
        }
        return target
    }

    private func continueTracking(pixelBuffer: CVPixelBuffer, minConfidence: Float) -> TrackedTarget? {
        guard let tracker = activeTracker else { return nil }
        do {
            try sequenceHandler.perform([tracker], on: pixelBuffer)
            guard let result = tracker.results?.first as? VNDetectedObjectObservation else {
                loseTrack()
                return nil
            }
            if result.confidence < minConfidence * 0.7 {
                loseTrack()
                return nil
            }
            // Feed next frame
            activeTracker = VNTrackObjectRequest(detectedObjectObservation: result)
            activeTracker?.trackingLevel = .accurate
            lostFrames = 0
            return TrackedTarget(boundingBox: result.boundingBox, confidence: result.confidence)
        } catch {
            loseTrack()
            return nil
        }
    }

    private func loseTrack() {
        lostFrames += 1
        if lostFrames >= maxLostFrames {
            activeTracker = nil
            lostFrames = 0
        }
    }

    func candidates(
        pixelBuffer: CVPixelBuffer, mode: TrackingMode, minConfidence: Float, ignoreZones: [IgnoreZone]
    ) -> [TrackedTarget] {
        do {
            let observations: [VNDetectedObjectObservation]
            switch mode {
            case .human:
                let request = VNDetectHumanRectanglesRequest()
                request.upperBodyOnly = false
                try sequenceHandler.perform([request], on: pixelBuffer)
                observations = request.results ?? []
            case .face:
                let request = VNDetectFaceRectanglesRequest()
                try sequenceHandler.perform([request], on: pixelBuffer)
                observations = request.results ?? []
            }
            return observations
                .filter { $0.confidence >= minConfidence }
                .map { TrackedTarget(boundingBox: $0.boundingBox, confidence: $0.confidence) }
                .filter { target in !ignoreZones.contains { $0.rect.contains(target.center) } }
        } catch {
            return []
        }
    }

}

private extension CGRect {
    var area: CGFloat { width * height }
}
