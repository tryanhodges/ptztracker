import SwiftUI

@main
struct PTZTrackerApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model.settings)
                .environmentObject(model.camera)
                .environmentObject(model.controller)
                .environmentObject(model.controller.rehearsal)
                .task {
                    await model.controller.start()
                }
        }
        .defaultSize(width: 1180, height: 720)
        .commands {
            CommandMenu("Tracking") {
                Button(model.controller.trackingEnabled ? "Disable Tracking" : "Enable Tracking") {
                    model.controller.toggleTracking()
                }
                .keyboardShortcut("t", modifiers: [.command])
            }
        }
    }
}
