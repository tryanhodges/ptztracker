import AVFoundation
import SwiftUI

enum ControlPanelTab: String, CaseIterable, Identifiable {
    case tracking = "Tracking"
    case ignoreZones = "Ignore Zones"
    case memory = "Memory"
    case connection = "Connection"

    var id: Self { self }
}

struct ControlPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: TrackingController
    @ObservedObject var camera: CameraCaptureService

    var body: some View {
        VStack(spacing: 0) {
            Picker("Controls", selection: $controller.controlPanelTab) {
                ForEach(ControlPanelTab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .padding(12)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    switch controller.controlPanelTab {
                    case .tracking:
                        trackingSection
                        Divider().opacity(0.35)
                        tuningSection
                    case .ignoreZones:
                        ignoreZonesSection
                    case .memory:
                        presetSection
                    case .connection:
                        cameraSection
                        Divider().opacity(0.35)
                        viscaSection
                        Divider().opacity(0.35)
                        companionSection
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
            }
            .id(controller.controlPanelTab)
        }
        .frame(minWidth: 300, idealWidth: 340, maxWidth: 380)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var ignoreZonesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Drag on the video to draw an ignore zone. Tracking skips targets whose centers are inside a zone.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(Array(settings.ignoreZones.enumerated()), id: \.element.id) { index, zone in
                HStack {
                    Text("Zone \(index + 1)")
                    Spacer()
                    Button("Remove") { settings.removeIgnoreZone(zone.id) }
                        .accessibilityLabel("Remove Zone \(index + 1)")
                }
            }
        }
    }

    private var trackingSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Auto Track")
                .font(.headline)

            Toggle(isOn: $controller.trackingEnabled) {
                Text(controller.trackingEnabled ? "Tracking On" : "Tracking Off")
                    .fontWeight(.semibold)
            }
            .toggleStyle(.switch)
            .tint(Color(red: 1.0, green: 0.72, blue: 0.2))

            Picker("Detect", selection: $settings.trackingMode) {
                ForEach(TrackingMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)

            Toggle("Select Target", isOn: Binding(
                get: { controller.manualTargetSelection },
                set: { controller.setManualTargetSelection($0) }
            ))

            if controller.manualTargetSelection {
                if controller.primaryTargetSelected {
                    Button("Choose Another Target") { controller.clearPrimaryTarget() }
                } else {
                    Text("Click an outlined target in the preview.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(targetSummary)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text("Framing").fontWeight(.medium)
                Spacer()
                Button("Reset to Center") {
                    settings.setFramingPoint(CGPoint(x: 0.5, y: 0.5))
                }
            }

            Text("Click or drag in the preview to place the crosshair.")
                .opacity(controller.manualTargetSelection && !controller.primaryTargetSelected ? 0 : 1)
                .font(.caption)
                .foregroundStyle(.secondary)

            LabeledContent("Horizontal") {
                Slider(value: Binding(
                    get: { Double(settings.framingPoint.x) },
                    set: { settings.setFramingPoint(CGPoint(x: $0, y: settings.framingPoint.y)) }
                ), in: 0...1, step: 0.01)
                .accessibilityLabel("Horizontal framing position")
            }

            LabeledContent("Vertical") {
                Slider(value: Binding(
                    get: { Double(settings.framingPoint.y) },
                    set: { settings.setFramingPoint(CGPoint(x: settings.framingPoint.x, y: $0)) }
                ), in: 0...1, step: 0.01)
                .accessibilityLabel("Vertical framing position")
            }
        }
    }

    private var cameraSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Video Input")
                .font(.headline)

            Picker("Device", selection: Binding(
                get: { settings.selectedDeviceID ?? camera.devices.first?.uniqueID ?? "" },
                set: { settings.selectedDeviceID = $0.isEmpty ? nil : $0 }
            )) {
                ForEach(camera.devices, id: \.uniqueID) { device in
                    Text(device.localizedName).tag(device.uniqueID)
                }
            }
            .labelsHidden()

            HStack {
                Button("Refresh") { camera.refreshDevices() }
                Button("Start Camera") {
                    Task { await camera.requestAccessAndStart(deviceID: settings.selectedDeviceID) }
                }
                .keyboardShortcut("r", modifiers: [.command])
            }

            if camera.isRunning {
                Text(camera.receivedVideoFrame ? "Video frames received" : "Waiting for video frames…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let format = camera.captureFormatDescription, camera.isRunning {
                Text(format)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if camera.authorizationDenied {
                Text("Camera access denied. Enable it in System Settings → Privacy & Security → Camera.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let error = camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var viscaSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Datavideo VISCA (DVIP)")
                .font(.headline)

            LabeledContent("IP") {
                TextField("192.168.1.188", text: $settings.cameraIP)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 140)
            }
            LabeledContent("Port") {
                TextField("5002", value: $settings.cameraPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }
            LabeledContent("Camera ID") {
                Stepper(value: $settings.deviceAddress, in: 1...7) {
                    Text("\(settings.deviceAddress)")
                        .monospacedDigit()
                }
            }

            Button("Reconnect Head") {
                Task { await controller.reconnectVisca() }
            }

            HStack(spacing: 6) {
                Circle()
                    .fill(controller.connection.viscaConnected ? Color.green : Color.orange)
                    .frame(width: 8, height: 8)
                Text(controller.connection.viscaConnected ? "Connected" : "Not connected")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !controller.connection.lastCommandHex.isEmpty {
                Text(controller.connection.lastCommandHex)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    private var presetSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Position Memory").font(.headline)
                Spacer()
                Button("Clear All") { controller.confirmingPresetClear = true }
                    .disabled(controller.trackingEnabled || controller.sendingPreset)
                    .confirmationDialog("Clear all position memories?", isPresented: $controller.confirmingPresetClear) {
                        Button("Clear All", role: .destructive) {
                            Task { await controller.clearAllPresets() }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This resets memories 1–4 and Center on the connected head.")
                    }
            }

            HStack(spacing: 5) {
                ForEach(1...5, id: \.self) { number in
                    let slot = UInt8(number)
                    let name = number == 5 ? "Center" : "\(number)"
                    let markedSaved = settings.isPresetMarkedSaved(slot)
                    Button {
                        Task { await controller.recallPreset(slot) }
                    } label: {
                        Text(name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(markedSaved ? Color.white : Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .background(
                                markedSaved ? Color(red: 0.04, green: 0.33, blue: 0.80) : Color.secondary.opacity(0.18),
                                in: RoundedRectangle(cornerRadius: 6)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(number == 5 ? "Recall Center" : "Recall Memory \(number)")
                    .accessibilityValue(markedSaved ? "Save sent" : "No save recorded")
                }
            }
            .disabled(controller.trackingEnabled || controller.sendingPreset)

            Text(controller.trackingEnabled ? "Turn tracking off to recall a position."
                 : "Blue marks slots saved through PTZ Tracker.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let message = controller.presetMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func deadZoneSlider(_ title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(value.wrappedValue, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: AppSettings.deadZoneSizeRange)
                .accessibilityLabel(title)
        }
    }

    private var tuningSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Response")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Reaction speed")
                    Spacer()
                    Text(settings.reactionSpeed, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.reactionSpeed, in: 0.1...1.0)
                Text("Higher = faster pan/tilt for the same offset.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                deadZoneSlider("Dead zone width", value: $settings.deadZoneWidth)
                deadZoneSlider("Dead zone height", value: $settings.deadZoneHeight)
                Text("Leaving the dashed box starts a correction. The head holds again once the target is near the crosshair.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Sensitivity")
                    Spacer()
                    Text(settings.sensitivity, format: .number.precision(.fractionLength(2)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.sensitivity, in: 0.15...0.9)
                Text("Minimum Vision confidence to accept a target.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Toggle("Invert pan", isOn: $settings.invertPan)
            Toggle("Invert tilt", isOn: $settings.invertTilt)
        }
    }

    private var companionSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Bitfocus Companion")
                .font(.headline)

            LabeledContent("HTTP port") {
                TextField("18787", value: $settings.companionPort, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
            }

            Button("Restart Companion API") {
                controller.restartCompanionServer()
            }

            if controller.connection.companionListening {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Listening")
                        .font(.caption)
                        .foregroundStyle(.green)
                    Text(controller.connection.companionURL)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                    Text("Endpoints: /tracking/on · /tracking/off · /tracking/toggle · /status")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Companion API is not listening.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }

    private var targetSummary: String {
        if let target = controller.currentTarget {
            return String(
                format: "Target %.0f%% · center (%.2f, %.2f)",
                target.confidence * 100,
                target.center.x,
                target.center.y
            )
        }
        return "No target in frame"
    }
}
