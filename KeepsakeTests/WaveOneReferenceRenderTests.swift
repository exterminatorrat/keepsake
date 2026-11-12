import SwiftUI
import UIKit
import XCTest
@testable import Keepsake

@MainActor
final class WaveOneReferenceRenderTests: XCTestCase {
    func testScreenReferenceAttachments() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KEEPSAKE_REFERENCE_RENDER"] == "1",
            "Manual reference scheme only; requires the separate native/MapKit render scope."
        )
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        XCTAssertEqual(scenes.count, 1)
        let scene = try XCTUnwrap(scenes.first)
        let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        window.overrideUserInterfaceStyle = .light
        let host = ReferenceHostController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            host.removeFixture()
            window.isHidden = true
            window.rootViewController = nil
            previousKeyWindow?.makeKey()
        }

        for (name, view) in fixtures {
            let controller = ReferenceFixtureController(rootView: view)
            host.show(controller)
            let needsMap = ["G01", "G02", "G03", "M01", "Offline", "GroupError"].contains(name)
            let readiness = ReferenceCaptureReadiness(
                window: window, host: host, content: controller, needsMap: needsMap
            )
            let state = await readiness.wait(timeout: 12)
            let record = XCTAttachment(data: try JSONEncoder().encode(state), uniformTypeIdentifier: "public.json")
            record.name = "READINESS-\(name)"
            record.lifetime = .keepAlways
            add(record)
            XCTAssertTrue(state.isReady, "Unsettled capture for \(name): \(state)")
            var drewHierarchy = false
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            XCTAssertTrue(drewHierarchy, "The native hierarchy did not render for \(name)")
            let attachment = XCTAttachment(image: image)
            attachment.name = "FIXTURE-\(name)-\(Int(window.bounds.width))x\(Int(window.bounds.height))pt"
            attachment.lifetime = .keepAlways
            add(attachment)
            host.removeFixture()
        }
    }

    private var fixtures: [(String, AnyView)] {
        let account = AccountIdentity(
            id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!),
            email: "fixture@example.com"
        )
        let group = SoloGroup(
            id: GroupID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!),
            ownerID: account.id,
            name: "My private group",
            createdAt: Date(timeIntervalSince1970: 100)
        )
        @MainActor func shell(_ state: GroupScreenState, _ presentation: GroupPresentation = .groupCollapsed, selector: Bool = false) -> AnyView {
            AnyView(GroupsShellView(
                account: account, state: state,
                onCreate: { _ in }, onRetry: {}, onSignOut: {},
                initialPresentation: presentation, initialSelectorOpen: selector
            ))
        }
        @MainActor func auth(_ state: AuthScreenState) -> AnyView {
            AnyView(NavigationStack {
                AuthScreenView(
                    state: state, onSendCode: { _ in }, onVerifyCode: { _ in },
                    onResend: {}, onChangeEmail: {}, onRetryConfiguration: {}
                )
                .toolbar(.hidden, for: .navigationBar)
            })
        }
        return [
            ("Email", auth(AuthScreenState())),
            ("Code", auth(AuthScreenState(step: .code, email: "fixture@example.com"))),
            ("AuthError", auth(AuthScreenState(step: .code, email: "fixture@example.com", errorMessage: AppServiceError.invalidCode.message))),
            ("Configuration", auth(AuthScreenState(configurationMessage: AppServiceError.configurationUnavailable.message))),
            ("G01", shell(.ready(group, offline: false))),
            ("G02", shell(.ready(group, offline: false), .groupExpanded)),
            ("G03", shell(.ready(group, offline: false), selector: true)),
            ("M01", shell(.ready(group, offline: false), .memberCollapsed)),
            ("M02", shell(.ready(group, offline: false), .memberExpanded)),
            ("S00", shell(.ready(group, offline: false), .settings)),
            ("Account", shell(.ready(group, offline: false), .account)),
            ("NoGroup", shell(.noGroup)),
            ("Loading", shell(.loading)),
            ("Offline", shell(.ready(group, offline: true))),
            ("GroupError", shell(.failed(message: "Connect to load your group.", offline: true)))
        ]
    }
}
