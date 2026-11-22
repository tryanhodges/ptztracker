import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var camera: CameraCaptureService
    @EnvironmentObject private var controller: TrackingController

    var body: some View {
        HSplitView {
            ZStack {
                Color.black
                if camera.isRunning {
                    VideoPreviewView(session: camera.session)
                    TrackingOverlayView(
                        target: controller.currentTarget,
                        bufferZone: settings.bufferZone,
                        motion: controller.currentMotion,
                        trackingEnabled: controller.trackingEnabled
                    )
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.ellipsis")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Waiting for video input")
                            .font(.title3.weight(.semibold))
                        Text("Choose your Thunderbolt capture device in the sidebar, then start the camera.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: 360)
                        Button("Start Camera") {
                            Task { await camera.requestAccessAndStart(deviceID: settings.selectedDeviceID) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color(red: 1.0, green: 0.72, blue: 0.2))
                        .foregroundStyle(.black)
                    }
                    .padding()
                }
            }
            .frame(minWidth: 640, minHeight: 400)

            ControlPanelView(settings: settings, controller: controller, camera: camera)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
