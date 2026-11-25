import AppKit
import AVFoundation
import Combine

struct RehearsalFrame {
    let time: Double
    let target: TrackedTarget?
    let motion: PTZMotion
    let pan: SpeedCurve.Point?
    let tilt: SpeedCurve.Point?
}

private struct Detection {
    let time: Double
    let target: TrackedTarget?
}

private struct DetectionOptions: Equatable {
    let mode: TrackingMode
    let confidence: Float
    let zones: [IgnoreZone]
}

private struct ClipError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

@MainActor
final class RehearsalSession: ObservableObject {
    let player = AVPlayer()
    let folder = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PTZ Tracker Clips", isDirectory: true)
    @Published private(set) var unfinished: [URL] = []
    @Published private(set) var clips: [URL] = []
    @Published private(set) var selected: URL?
    @Published private(set) var draft: URL?
    @Published private(set) var recording = false
    @Published private(set) var busy = false
    @Published private(set) var analyzing = false
    @Published private(set) var duration = 0.0
    @Published private(set) var position = 0.0
    @Published private(set) var playing = false
    @Published private(set) var aspect = 16.0 / 9
    @Published private(set) var frame: RehearsalFrame?
    @Published var name = ""
    @Published var start = 0.0
    @Published var end = 0.0
    @Published var compareMode: TrackingSpeedMode = .basic { didSet { rebuild() } }
    @Published var editingCurves = false
    @Published var loop = false
    @Published var message: String?

    private var captureURL: URL?
    private var writer: AVAssetWriter?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var firstTime: CMTime?
    private var observer: Any?
    private var analysis: Task<Void, Never>?
    private var revision = 0
    private var options: DetectionOptions?
    private var detections: [Detection] = []
    private var frames: [RehearsalFrame] = []
    private weak var settings: AppSettings?

    init() {
        player.isMuted = true
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            Task { @MainActor in self?.tick(time.seconds) }
        }
    }

    private var libraryRequest = 0

    func refresh() async {
        libraryRequest += 1
        let request = libraryRequest
        let directory = folder
        do {
            let files = try await Task.detached(priority: .utility) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            }.value
            guard libraryRequest == request else { return }
            unfinished = files.filter { $0.lastPathComponent.hasPrefix(".recording-") && $0.pathExtension == "mov" }
            clips = files.filter { !$0.lastPathComponent.hasPrefix(".") }
                .filter { ["mov","mp4","m4v"].contains($0.pathExtension.lowercased()) }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } catch { message = error.localizedDescription }
    }

    func begin() {
        guard !busy, !recording, draft == nil else { return }
        clearPlayer()
        captureURL = folder.appendingPathComponent(".recording-\(UUID()).mov")
        firstTime = nil
        message = nil
        recording = true
    }

    func append(_ buffer: CVPixelBuffer, time: CMTime) {
        guard recording, let captureURL else { return }
        do {
            if writer == nil {
                let file = try AVAssetWriter(outputURL: captureURL, fileType: .mov)
                let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: CVPixelBufferGetWidth(buffer), AVVideoHeightKey: CVPixelBufferGetHeight(buffer)
                ])
                input.expectsMediaDataInRealTime = true
                let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
                guard file.canAdd(input) else { throw ClipError("Cannot encode this capture format.") }
                file.add(input)
                guard file.startWriting() else { throw file.error ?? ClipError("Could not start recording.") }
                file.startSession(atSourceTime: .zero)
                writer = file
                adaptor = adapter
                firstTime = time
            }
            guard let adaptor, let firstTime else { return }
            if writer?.status == .failed { throw writer?.error ?? ClipError("Recording failed.") }
            if adaptor.assetWriterInput.isReadyForMoreMediaData,
               !adaptor.append(buffer, withPresentationTime: time - firstTime) {
                throw writer?.error ?? ClipError("Could not write this video frame.")
            }
        } catch {
            writer?.cancelWriting()
            writer = nil
            adaptor = nil
            recording = false
            try? FileManager.default.removeItem(at: captureURL)
            message = error.localizedDescription
        }
    }

    func stopRecording() async {
        guard recording else { return }
        recording = false
        guard let writer, let url = captureURL else {
            message = "No video frames arrived."
            return
        }
        busy = true
        adaptor?.assetWriterInput.markAsFinished()
        await writer.finishWriting()
        self.writer = nil
        adaptor = nil
        captureURL = nil
        busy = false
        guard writer.status == .completed else {
            message = writer.error?.localizedDescription ?? "Recording could not be finished."
            return
        }
        await trim(url)
    }

    func trim(_ url: URL) async {
        guard !recording, !busy else { return }
        draft = url
        name = "Rehearsal " + Date().formatted(.iso8601.year().month().day())
        await load(url)
    }

    func save() async {
        guard let draft, !busy else { return }
        let base = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty, !base.hasPrefix("."), !base.contains("/"), !base.contains(":"),
              end > start else { message = "Enter a clip name and a valid trim range."; return }
        let destination = folder.appendingPathComponent(base).appendingPathExtension("mov")
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            message = "That clip name is already in use."; return
        }
        pause()
        busy = true
        defer { busy = false }
        let temporary = folder.appendingPathComponent(".export-\(UUID()).mov")
        defer { try? FileManager.default.removeItem(at: temporary) }
        do {
            guard let export = AVAssetExportSession(asset: AVURLAsset(url: draft), presetName: AVAssetExportPresetPassthrough)
            else { throw ClipError("Could not prepare the trimmed clip.") }
            export.outputURL = temporary
            export.outputFileType = .mov
            export.timeRange = CMTimeRange(start: Self.time(start), end: Self.time(end))
            await export.export()
            guard export.status == .completed else { throw export.error ?? ClipError("Export failed.") }
            try FileManager.default.moveItem(at: temporary, to: destination)
            self.draft = nil
            try? FileManager.default.removeItem(at: draft)
            await refresh()
            await load(destination)
        } catch { message = error.localizedDescription }
    }

    func discardDraft() async {
        guard let draft, !busy else { return }
        do {
            try FileManager.default.removeItem(at: draft)
            self.draft = nil
            clearPlayer()
            await refresh()
        } catch { message = error.localizedDescription }
    }

    func signalLost() {
        if recording { Task { await stopRecording() } }
    }

    func leaveTab() {
        pause()
        signalLost()
    }

    func configure(_ settings: AppSettings) {
        if self.settings == nil { compareMode = settings.trackingSpeedMode }
        self.settings = settings
        guard let selected, draft == nil else { return }
        let next = DetectionOptions(mode: settings.trackingMode, confidence: Float(settings.sensitivity), zones: settings.ignoreZones)
        if options == next {
            rebuild()
            return
        }
        options = next
        analysis?.cancel()
        let generation = revision
        analyzing = true
        frame = nil
        frames = []
        detections = []
        analysis = Task {
            let worker = Task.detached(priority: .utility) { try await Self.analyze(selected, options: next) }
            do {
                let samples = try await withTaskCancellationHandler(operation: { try await worker.value },
                                                                   onCancel: { worker.cancel() })
                guard !Task.isCancelled, revision == generation else { return }
                detections = samples
                rebuild()
            } catch {
                guard !Task.isCancelled, revision == generation else { return }
                message = error.localizedDescription
            }
            analyzing = false
        }
    }

    private nonisolated static func analyze(_ url: URL, options: DetectionOptions) async throws -> [Detection] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ClipError("No video track in clip.") }
        let reader = try AVAssetReader(asset: asset)
        let format = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let output: AVAssetReaderOutput
        if try await track.load(.preferredTransform).isIdentity {
            output = AVAssetReaderTrackOutput(track: track, outputSettings: format)
        } else {
            let oriented = AVAssetReaderVideoCompositionOutput(videoTracks: [track], videoSettings: format)
            oriented.videoComposition = AVMutableVideoComposition(propertiesOf: asset)
            output = oriented
        }
        guard reader.canAdd(output) else { throw ClipError("Cannot read clip frames.") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ClipError("Cannot read the video.") }
        defer { reader.cancelReading() }
        let vision = VisionTrackingService()
        var samples: [Detection] = []
        var last = -Double.infinity
        while !Task.isCancelled {
            let more = autoreleasepool {
                guard let sample = output.copyNextSampleBuffer() else { return false }
                let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                if t - last >= 1.0 / 15 - 0.00001, let pixels = CMSampleBufferGetImageBuffer(sample) {
                    let target = vision.detect(pixelBuffer: pixels, mode: options.mode,
                                               minConfidence: options.confidence, ignoreZones: options.zones)
                    samples.append(Detection(time: t, target: target))
                    last = t
                }
                return true
            }
            if !more { break }
        }
        try Task.checkCancellation()
        if reader.status == .failed { throw reader.error ?? ClipError("Clip analysis failed.") }
        return samples
    }

    private func rebuild() {
        guard let settings else { return }
        var engine = MotionEngine()
        frames = detections.map { sample in
            let motion: PTZMotion
            if let target = sample.target { motion = engine.evaluate(target, at: sample.time, settings: settings, mode: compareMode) }
            else { engine = MotionEngine(); motion = .idle }
            return RehearsalFrame(time: sample.time, target: sample.target, motion: motion,
                                  pan: engine.panPoint, tilt: engine.tiltPoint)
        }
        updateFrame()
    }

    func load(_ url: URL) async {
        clearPlayer()
        let generation = revision
        selected = url
        let asset = AVURLAsset(url: url)
        do {
            let length = try await asset.load(.duration).seconds
            guard let track = try await asset.loadTracks(withMediaType: .video).first,
                  length.isFinite, length > 0 else { throw ClipError("Clip contains no playable video.") }
            let size = try await track.load(.naturalSize)
            let transform = try await track.load(.preferredTransform)
            guard revision == generation else { return }
            let display = size.applying(transform)
            aspect = abs(display.width) / max(1, abs(display.height))
            duration = length
            end = length
            player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
            if let settings { configure(settings) }
        } catch { if revision == generation { message = error.localizedDescription } }
    }

    private func clearPlayer() {
        editingCurves = false
        revision += 1
        analysis?.cancel()
        options = nil
        analyzing = false
        pause()
        player.replaceCurrentItem(with: nil)
        selected = nil
        detections = []
        frames = []
        frame = nil
        message = nil
        duration = 0
        start = 0
        end = 0
        position = 0
        loop = false
    }

    private static func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 60000) }

    func seek(_ value: Double) {
        position = min(duration, max(0, value))
        player.seek(to: Self.time(position), toleranceBefore: .zero, toleranceAfter: .zero)
        updateFrame()
    }

    func togglePlay() {
        if playing { pause(); return }
        guard end > start else { return }
        if position < start || position >= end - 0.02 { seek(start) }
        playing = true
        player.play()
    }

    func pause() { player.pause(); playing = false }

    private func tick(_ time: Double) {
        guard time.isFinite, duration > 0 else { return }
        if playing, time >= end - 0.02 {
            if loop { seek(start); player.play() }
            else { pause(); seek(end) }
        } else {
            position = time
            updateFrame()
        }
    }

    private func updateFrame() {
        var low = 0, high = frames.count
        while low < high {
            let mid = (low + high) / 2
            if frames[mid].time <= position { low = mid + 1 } else { high = mid }
        }
        frame = low > 0 ? frames[low - 1] : nil
    }
}
