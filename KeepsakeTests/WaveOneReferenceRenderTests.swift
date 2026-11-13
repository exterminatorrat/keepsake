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

        let expectedMemberIDs = [
            "MemberPager-0": UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            "MemberPager-1": UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            "MemberPager-2": UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ]
        for (name, view) in fixtures {
            let controller = ReferenceFixtureController(rootView: view)
            host.show(controller)
            let needsMap = ["G01", "G02", "G03", "M01", "Offline", "GroupError"].contains(name)
            let readiness = ReferenceCaptureReadiness(
                window: window, host: host, content: controller, needsMap: needsMap,
                expectedMemberID: expectedMemberIDs[name]
            )
            let state = await readiness.wait(timeout: 12)
            let record = XCTAttachment(data: try JSONEncoder().encode(state), uniformTypeIdentifier: "public.json")
            record.name = "READINESS-\(name)"
            record.lifetime = .keepAlways
            add(record)
            XCTAssertTrue(state.isReady, "Unsettled capture for \(name): \(state)")
            if let memberViewport = state.memberViewport {
                XCTAssertEqual(memberViewport.centeredID, memberViewport.expectedID, "Wrong visible member for \(name)")
                XCTAssertTrue(memberViewport.isReady, "Member is not fully visible and centered for \(name)")
            }
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

    func testMemberPagerBindingDiagnostics() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["KEEPSAKE_REFERENCE_RENDER"] == "1",
            "Manual reference scheme only; requires its separate native diagnostic scope."
        )
        #if DEBUG
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        XCTAssertEqual(scenes.count, 1)
        let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil)
        let you = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let maya = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let jin = UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        let cases: [(name: String, root: Bool, external: Bool, index: Int, target: UUID)] = [
            ("PG-A-contained-initial", false, false, 1, maya),
            ("PG-B-root-initial", true, false, 1, maya),
            ("PG-C-contained-external", false, true, 0, maya),
            ("PG-D-root-external", true, true, 0, maya),
            ("PG-E-contained-initial-first", false, false, 0, you),
            ("PG-F-contained-initial-last", false, false, 2, jin)
        ]
        for item in cases {
            let previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
            let window = UIWindow(windowScene: scene)
            window.frame = scene.coordinateSpace.bounds
            window.overrideUserInterfaceStyle = .light
            let control = PagerBindingDiagnosticControl()
            let controller = ReferenceFixtureController(rootView: AnyView(
                GroupMemberPagerPreview(index: item.index, onSelectionAvailable: { binding in
                    control.binding = binding
                    control.bindingExportCount += 1
                })
            ))
            let host: ReferenceHostController? = item.root ? nil : ReferenceHostController()
            if let host {
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.show(controller)
            } else {
                window.rootViewController = controller
                window.makeKeyAndVisible()
            }
            defer {
                control.binding = nil
                host?.removeFixture()
                window.isHidden = true
                window.rootViewController = nil
                previousKeyWindow?.makeKey()
            }

            @MainActor func sample(expectedID: UUID) async -> ReferenceReadiness {
                let readiness = ReferenceCaptureReadiness(
                    window: window, host: host, content: controller, needsMap: false,
                    expectedMemberID: expectedID, observesMemberScroll: true
                )
                return await readiness.wait(timeout: 12)
            }

            @MainActor func retain(name: String, intendedID: UUID, state: ReferenceReadiness, sourcePhase: String, attempted: Bool) throws -> Bool {
                var drewHierarchy = false
                let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                    drewHierarchy = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
                }
                let imageAttachment = XCTAttachment(image: image)
                imageAttachment.name = "FIXTURE-\(name)-\(Int(window.bounds.width))x\(Int(window.bounds.height))pt"
                imageAttachment.lifetime = .keepAlways
                add(imageAttachment)
                let record = PagerBindingDiagnosticRecord(
                    caseName: item.name, hosting: item.root ? "root" : "contained", phase: name,
                    intendedMemberID: intendedID, readinessSourcePhase: sourcePhase, attempted: attempted,
                    selectedMemberID: control.binding?.wrappedValue?.rawValue,
                    bindingAvailable: control.binding != nil, hierarchyRendered: drewHierarchy,
                    bindingExportCount: control.bindingExportCount, externalWriteCount: control.externalWriteCount,
                    readiness: state
                )
                let encoder = JSONEncoder()
                encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "Infinity", negativeInfinity: "-Infinity", nan: "NaN")
                let dataAttachment = XCTAttachment(data: try encoder.encode(record), uniformTypeIdentifier: "public.json")
                dataAttachment.name = "READINESS-\(name)"
                dataAttachment.lifetime = .keepAlways
                add(dataAttachment)
                XCTAssertTrue(drewHierarchy, "The native hierarchy did not render for \(name)")
                return drewHierarchy
            }

            let terminalName = item.name + "-terminal"
            let terminal: ReferenceReadiness
            let terminalSourcePhase: String
            let terminalAttempted: Bool
            if item.external {
                let baselineName = item.name + "-baseline"
                let baseline = await sample(expectedID: you)
                let baselineRendered = try retain(name: baselineName, intendedID: you, state: baseline, sourcePhase: baselineName, attempted: true)
                XCTAssertTrue(baseline.isReady, "Unready You baseline for \(item.name): \(baseline)")
                XCTAssertEqual(control.binding?.wrappedValue?.rawValue, you, "Wrong selected baseline for \(item.name)")
                if baselineRendered && baseline.isReady, let binding = control.binding, binding.wrappedValue?.rawValue == you {
                    control.externalWriteCount += 1
                    binding.wrappedValue = AccountID(rawValue: maya)
                    terminal = await sample(expectedID: maya)
                    terminalSourcePhase = terminalName
                    terminalAttempted = true
                } else {
                    XCTFail("External write not issued because baseline/render/binding was unavailable for \(item.name)")
                    terminal = baseline
                    terminalSourcePhase = baselineName
                    terminalAttempted = false
                }
            } else {
                terminal = await sample(expectedID: item.target)
                terminalSourcePhase = terminalName
                terminalAttempted = true
            }
            _ = try retain(name: terminalName, intendedID: item.target, state: terminal, sourcePhase: terminalSourcePhase, attempted: terminalAttempted)
            XCTAssertTrue(terminalAttempted, "No terminal request was attempted for \(item.name)")
            XCTAssertEqual(control.externalWriteCount, item.external && terminalAttempted ? 1 : 0)
            if terminalAttempted {
                XCTAssertEqual(control.binding?.wrappedValue?.rawValue, item.target, "Wrong selected target for \(item.name)")
                XCTAssertTrue(terminal.isReady, "Unsettled terminal for \(item.name): \(terminal)")
                XCTAssertEqual(terminal.memberViewport?.centeredID, item.target, "Wrong visible terminal member for \(item.name)")
                XCTAssertTrue(terminal.memberScroll?.isObservable == true, "Unobservable native scroll owner for \(item.name)")
            }
        }
        #else
        throw XCTSkip("The diagnostic preview and layout probes require the manual Debug configuration.")
        #endif
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
        var result: [(String, AnyView)] = [
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
        #if DEBUG
        result += AuthReferencePose.allCases.map { pose in
            (pose.rawValue, AnyView(AuthWorkflowPreview(pose: pose)))
        }
        result += (0..<3).map { index in
            ("MemberPager-\(index)", AnyView(GroupMemberPagerPreview(index: index)))
        }
        #endif
        return result
    }
}

@MainActor
private final class PagerBindingDiagnosticControl {
    var binding: Binding<AccountID?>?
    var bindingExportCount = 0
    var externalWriteCount = 0
}

private struct PagerBindingDiagnosticRecord: Codable {
    let caseName: String
    let hosting: String
    let phase: String
    let intendedMemberID: UUID
    let readinessSourcePhase: String
    let attempted: Bool
    let selectedMemberID: UUID?
    let bindingAvailable: Bool
    let hierarchyRendered: Bool
    let bindingExportCount: Int
    let externalWriteCount: Int
    let readiness: ReferenceReadiness
}
