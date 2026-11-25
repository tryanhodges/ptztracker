import AVKit
import SwiftUI
import UniformTypeIdentifiers

struct RehearsalControls: View {
    @ObservedObject var session: RehearsalSession
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: TrackingController
    @ObservedObject var camera: CameraCaptureService

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if session.recording {
                Button("Stop Recording") { Task { await session.stopRecording() } }
            } else if session.draft != nil {
                Text("Trim recording").font(.headline)
                TextField("Clip name", text: $session.name)
                rangeControls
                HStack {
                    Button("Save Clip") { Task { await session.save() } }
                    Button("Discard Recording") { Task { await session.discardDraft() } }
                }
                .disabled(session.busy)
            } else {
                Button("Record Camera Input") { session.begin() }
                    .disabled(!camera.receivedVideoFrame || session.busy)
                Text("Documents / PTZ Tracker Clips").font(.caption).foregroundStyle(.secondary)
                if !session.unfinished.isEmpty {
                    Menu("Resume unfinished recording") {
                        ForEach(session.unfinished, id: \.self) { url in
                            let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                            Button(date?.formatted() ?? url.lastPathComponent) { Task { await session.trim(url) } }
                        }
                    }
                }
                Picker("Saved clips", selection: Binding(get: { session.selected }, set: { url in
                    if let url { Task { await session.load(url) } }
                })) {
                    Text("Choose a clip").tag(nil as URL?)
                    ForEach(session.clips, id: \.self) { url in
                        Text(url.deletingPathExtension().lastPathComponent).tag(Optional(url))
                    }
                    if let selected = session.selected, !session.clips.contains(selected) {
                        Text(selected.lastPathComponent).tag(Optional(selected))
                    }
                }
                HStack {
                    Button("Open Clip…") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie]
                        if panel.runModal() == .OK, let url = panel.url { Task { await session.load(url) } }
                    }
                    Button("Refresh List") { Task { await session.refresh() } }
                }
                .disabled(session.busy)
                if session.duration > 0 {
                    rangeControls
                    Toggle("Loop selected range", isOn: $session.loop)
                    Picker("Compare speed", selection: $session.compareMode) {
                        ForEach(TrackingSpeedMode.allCases) { mode in
                            Text(mode.slot.map { settings.trackingSpeedProfiles[$0].name } ?? "Basic").tag(mode)
                        }
                    }
                    Button(session.editingCurves ? "Hide Speed Curves" : "Edit Speed Curves…") {
                        if session.compareMode == .basic { session.compareMode = .preset1 }
                        session.editingCurves.toggle()
                    }
                    if session.analyzing { ProgressView("Analyzing clip…") }
                }
            }
            if session.duration > 0 {
                Slider(value: Binding(get: { session.position }, set: { session.seek($0) }), in: 0...session.duration)
                HStack {
                    Button(session.playing ? "Pause" : "Play") { session.togglePlay() }
                    Text("\(session.position, specifier: "%.2f") / \(session.duration, specifier: "%.2f") s")
                        .monospacedDigit()
                }
            }
            if session.busy { ProgressView() }
            if let message = session.message { Text(message).foregroundStyle(.orange) }
        }
        .task { session.configure(settings); await session.refresh() }
        .onReceive(settings.objectWillChange.debounce(for: .milliseconds(80), scheduler: RunLoop.main)) { _ in
            session.configure(settings)
        }
    }

    @ViewBuilder private var rangeControls: some View {
        if session.duration > 0 {
            let gap = min(1.0 / 30, session.duration)
            Text("Start · \(session.start, specifier: "%.2f") s")
            Slider(value: Binding(get: { session.start }, set: {
                session.start = min($0, session.end - gap)
                session.seek(session.start)
            }), in: 0...session.duration)
            Text("End · \(session.end, specifier: "%.2f") s")
            Slider(value: Binding(get: { session.end }, set: {
                session.end = max($0, session.start + gap)
                session.seek(session.end)
            }), in: 0...session.duration)
        }
    }
}

private struct ClipPlayer: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .none
        view.player = player
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {}
}

struct RehearsalPreview: View {
    @EnvironmentObject private var controller: TrackingController
    @ObservedObject var session: RehearsalSession
    @ObservedObject var settings: AppSettings

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                ClipPlayer(player: session.player)
                if session.draft == nil {
                    TrackingOverlayView(target: session.frame?.target, candidates: [],
                                        deadZoneWidth: settings.deadZoneWidth, deadZoneHeight: settings.deadZoneHeight,
                                        framingPoint: settings.framingPoint, motion: session.frame?.motion ?? .idle,
                                        trackingEnabled: true)
                }
            }
            .aspectRatio(session.aspect, contentMode: .fit)
            if session.editingCurves, let slot = session.compareMode.slot {
                SpeedCurveEditor(controller: controller, settings: settings, initialSlot: slot, embedded: true)
                    .id(slot)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
    }
}
