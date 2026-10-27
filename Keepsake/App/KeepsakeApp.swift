import SwiftUI

@main
@MainActor
struct KeepsakeApp: App {
    @State private var recorder = RecorderModel()

    var body: some Scene {
        WindowGroup {
            RouteHomeView(recorder: recorder)
        }
    }
}
