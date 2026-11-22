import AVFoundation
import SwiftUI

struct ControlPanelView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: TrackingController
    @ObservedObject var camera: CameraCaptureService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                trackingSection
                Divider().opacity(0.35)
                cameraSection
                Divider().opacity(0.35)
                viscaSection
                Divider().opacity(0.35)
                tuningSection
                Divider().opacity(0.35)
                companionSection
            }
            .padding(16)
        }
        .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)
        .background(Color(nsColor: .controlBackgroundColor))
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

            Text(targetSummary)
                .font(.caption)
                .foregroundStyle(.secondary)
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

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Buffer (dead zone)")
                    Spacer()
                    Text(settings.bufferZone, format: .percent.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $settings.bufferZone, in: 0.02...0.4)
                Text("Ignore subject drift inside this center region.")
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
