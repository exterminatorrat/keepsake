import SwiftUI

@main
@MainActor
struct KeepsakeApp: App {
    @State private var session = AppSession(services: .production)

    var body: some Scene {
        WindowGroup {
            AppRootView(session: session)
        }
    }
}
