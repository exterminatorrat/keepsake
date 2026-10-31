import SwiftUI

@main
@MainActor
struct KeepsakeApp: App {
    #if KEEPSAKE_EXPERIMENTAL_LOCAL_CAPTURE
    var body: some Scene {
        WindowGroup {
            LocalCaptureExperimentHost()
        }
    }
    #else
    @State private var recorder = RecorderModel()

    var body: some Scene {
        WindowGroup {
            RouteHomeView(recorder: recorder)
        }
    }
    #endif
}
