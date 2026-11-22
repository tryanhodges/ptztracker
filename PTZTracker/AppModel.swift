import Combine
import SwiftUI

@MainActor
final class AppModel: ObservableObject {
    let settings: AppSettings
    let camera: CameraCaptureService
    let controller: TrackingController

    init() {
        let settings = AppSettings()
        let camera = CameraCaptureService()
        self.settings = settings
        self.camera = camera
        self.controller = TrackingController(settings: settings, camera: camera)
    }
}
