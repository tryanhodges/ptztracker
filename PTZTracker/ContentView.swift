import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var camera: CameraCaptureService
    @EnvironmentObject private var controller: TrackingController

    @EnvironmentObject private var rehearsal: RehearsalSession

    private var trackingOverlay: some View {
        TrackingOverlayView(
            target: controller.currentTarget,
            candidates: controller.targetCandidates,
            deadZoneWidth: settings.deadZoneWidth,
            deadZoneHeight: settings.deadZoneHeight,
            framingPoint: settings.framingPoint,
            motion: controller.currentMotion,
            trackingEnabled: controller.trackingEnabled
        )
    }

    var body: some View {
        HSplitView {
            ZStack {
                Color.black
                if controller.controlPanelTab == .rehearsal, rehearsal.selected != nil {
                    RehearsalPreview(session: rehearsal, settings: settings)
                } else if camera.isRunning {
                    ZStack {
                        if camera.usingDeckLink {
                            DeckLinkPreviewView(layer: camera.deckLinkPreview)
                        } else {
                            VideoPreviewView(session: camera.session)
                        }
                        if controller.controlPanelTab != .rehearsal { trackingOverlay }
                        if controller.controlPanelTab == .ignoreZones {
                            IgnoreZoneEditor(zones: settings.ignoreZones, addZone: controller.addIgnoreZone)
                        } else if controller.controlPanelTab == .tracking {
                            framingInteraction
                        }
                    }
                    .aspectRatio(camera.videoAspectRatio, contentMode: .fit)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.ellipsis")
                            .font(.system(size: 42))
                            .foregroundStyle(.secondary)
                        Text("Waiting for video input")
                            .font(.title3.weight(.semibold))
                        Text("Choose your Thunderbolt capture device, then start the camera.")
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

    private var framingInteraction: some View {
        GeometryReader { geometry in
            Color.clear
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                    guard !controller.manualTargetSelection || controller.primaryTargetSelected,
                          geometry.size.width > 0, geometry.size.height > 0 else { return }
                    settings.setFramingPoint(CGPoint(
                        x: drag.location.x / geometry.size.width,
                        y: drag.location.y / geometry.size.height
                    ))
                }.onEnded { drag in
                    guard controller.manualTargetSelection, !controller.primaryTargetSelected,
                          geometry.size.width > 0, geometry.size.height > 0,
                          abs(drag.translation.width) < 6, abs(drag.translation.height) < 6
                    else { return }
                    controller.selectPrimaryTarget(at: CGPoint(
                        x: drag.location.x / geometry.size.width,
                        y: drag.location.y / geometry.size.height
                    ))
                })
                .accessibilityHidden(true)
        }
    }
}
