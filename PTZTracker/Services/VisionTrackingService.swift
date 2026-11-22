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
        minConfidence: Float
    ) -> TrackedTarget? {
        if let tracked = continueTracking(pixelBuffer: pixelBuffer, minConfidence: minConfidence) {
            return tracked
        }

        guard let seeded = seedDetection(
            pixelBuffer: pixelBuffer,
            mode: mode,
            minConfidence: minConfidence
        ) else {
            return nil
        }

        let observation = VNDetectedObjectObservation(boundingBox: seeded.boundingBox)
        let tracker = VNTrackObjectRequest(detectedObjectObservation: observation)
        tracker.trackingLevel = .accurate
        activeTracker = tracker
        lostFrames = 0
        return seeded
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

    private func seedDetection(
        pixelBuffer: CVPixelBuffer,
        mode: TrackingMode,
        minConfidence: Float
    ) -> TrackedTarget? {
        switch mode {
        case .human:
            return detectHuman(pixelBuffer: pixelBuffer, minConfidence: minConfidence)
        case .face:
            return detectFace(pixelBuffer: pixelBuffer, minConfidence: minConfidence)
        }
    }

    private func detectHuman(pixelBuffer: CVPixelBuffer, minConfidence: Float) -> TrackedTarget? {
        let request = VNDetectHumanRectanglesRequest()
        request.upperBodyOnly = false
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
            let observations = (request.results ?? [])
                .filter { $0.confidence >= minConfidence }
                .sorted { $0.boundingBox.area > $1.boundingBox.area }
            guard let best = observations.first else { return nil }
            return TrackedTarget(boundingBox: best.boundingBox, confidence: best.confidence)
        } catch {
            return nil
        }
    }

    private func detectFace(pixelBuffer: CVPixelBuffer, minConfidence: Float) -> TrackedTarget? {
        let request = VNDetectFaceRectanglesRequest()
        do {
            try sequenceHandler.perform([request], on: pixelBuffer)
            let observations = (request.results ?? [])
                .filter { $0.confidence >= minConfidence }
                .sorted { $0.boundingBox.area > $1.boundingBox.area }
            guard let best = observations.first else { return nil }
            return TrackedTarget(boundingBox: best.boundingBox, confidence: best.confidence)
        } catch {
            return nil
        }
    }
}

private extension CGRect {
    var area: CGFloat { width * height }
}
