import SwiftUI
import UIKit
import XCTest
@testable import Keepsake

final class LocalCaptureExperimentSyntheticVisualRenderEntryTests: XCTestCase {
    @MainActor
    func testRendersEmptyThenThreeThenTwoPointHistory() async throws {
        let fixture = try await LocalCaptureExperimentSyntheticVisualFixture.make()
        var host: SyntheticVisualRenderHost?
        defer {
            host?.detach()
            fixture.dispose()
        }
        let renderHost = try SyntheticVisualRenderHost.make(for: fixture.view)
        host = renderHost

        XCTAssertEqual(fixture.model.captureState, .stopped(controlRevision: 2))
        XCTAssertNil(fixture.model.historyPage)
        try attachScreenshot(named: "local-capture-synthetic-history-empty", from: renderHost)

        let initialAudit = await fixture.audit()
        try assertInertAudit(initialAudit, fixture: fixture, cursors: [])
        let stopReceipt = try XCTUnwrap(initialAudit.controlSnapshot.lastControlReceipt)

        await fixture.view.selectDay()

        let firstPage = try XCTUnwrap(fixture.model.historyPage)
        XCTAssertEqual(firstPage.items.map(\.sample.id), fixture.firstSampleIDs)
        XCTAssertTrue(firstPage.items.allSatisfy { $0.epoch == stopReceipt.epoch })
        XCTAssertEqual(firstPage.items.count, 3)
        XCTAssertEqual(firstPage.nextCursor, fixture.firstCursor)
        XCTAssertTrue(fixture.model.canLoadNextHistoryPage)
        XCTAssertEqual(fixture.model.captureState, .stopped(controlRevision: 2))
        XCTAssertEqual(fixture.model.historyQuery?.interval, fixture.interval)
        XCTAssertEqual(fixture.model.historyQuery?.queryNow, fixture.queryNow)
        XCTAssertEqual(fixture.model.historyQuery?.pageLimit, LocalCaptureConsumerModel.defaultHistoryPageLimit)
        try attachScreenshot(named: "local-capture-synthetic-history-three-points", from: renderHost)

        let firstPageAudit = await fixture.audit()
        try assertInertAudit(firstPageAudit, fixture: fixture, cursors: [nil])

        await fixture.model.loadNextHistoryPage()

        let nextPage = try XCTUnwrap(fixture.model.historyPage)
        XCTAssertEqual(nextPage.items.map(\.sample.id), fixture.nextSampleIDs)
        XCTAssertTrue(nextPage.items.allSatisfy { $0.epoch == stopReceipt.epoch })
        XCTAssertEqual(nextPage.items.count, 2)
        XCTAssertNil(nextPage.nextCursor)
        XCTAssertFalse(fixture.model.hasMoreHistoryPages)
        XCTAssertEqual(fixture.model.captureState, .stopped(controlRevision: 2))
        try attachScreenshot(named: "local-capture-synthetic-history-two-points", from: renderHost)

        let nextPageAudit = await fixture.audit()
        try assertInertAudit(nextPageAudit, fixture: fixture, cursors: [nil, fixture.firstCursor])
    }

    @MainActor
    private func assertInertAudit(
        _ audit: LocalCaptureExperimentSyntheticVisualFixtureAudit,
        fixture: LocalCaptureExperimentSyntheticVisualFixture,
        cursors: [CapturePageCursor?]
    ) throws {
        XCTAssertEqual(audit.controlReadCount, 1)
        XCTAssertEqual(audit.controlSnapshot.revision, 2)
        XCTAssertNil(audit.controlSnapshot.activeEpoch)

        let stopReceipt = try XCTUnwrap(audit.controlSnapshot.lastControlReceipt)
        XCTAssertEqual(stopReceipt.kind, .stop)
        XCTAssertEqual(stopReceipt.controlRevision, 2)
        XCTAssertEqual(stopReceipt.epoch.revision, 1)
        XCTAssertEqual(
            stopReceipt.commandDigest,
            CaptureCommandDigest.stop(epoch: stopReceipt.epoch, expectedControlRevision: 1)
        )

        XCTAssertEqual(audit.historyRequests.map(\.cursor), cursors)
        XCTAssertTrue(audit.historyRequests.allSatisfy {
            $0.interval == fixture.interval
                && $0.now == fixture.queryNow
                && $0.limit == LocalCaptureConsumerModel.defaultHistoryPageLimit
        })
        XCTAssertEqual(audit.forbiddenActionCount, 0)
        XCTAssertEqual(audit.unexpectedCallCount, 0)
        XCTAssertEqual(audit.unexpectedHistoryRequestCount, 0)
        XCTAssertEqual(audit.locationCollectCount, 0)
        XCTAssertEqual(audit.authorizationRefreshCount, 0)
        XCTAssertEqual(audit.authorizationRequestCount, 0)
        XCTAssertEqual(audit.servicesStatusReadCount, 0)
        XCTAssertEqual(audit.backgroundActivityHandleCount, 0)
        XCTAssertEqual(audit.serviceSessionHandleCount, 0)
        XCTAssertEqual(audit.pruneCalls, 0)
        XCTAssertEqual(audit.closeCalls, 0)
    }

    @MainActor
    private func attachScreenshot(
        named name: String,
        from host: SyntheticVisualRenderHost
    ) throws {
        guard let controller = host.controller, let view = controller.view else {
            throw SyntheticVisualRenderEntryError.hostUnavailable
        }
        host.window.setNeedsLayout()
        host.window.layoutIfNeeded()
        view.setNeedsLayout()
        view.layoutIfNeeded()

        guard host.isUnambiguousAndVisible, view.bounds.width > 0, view.bounds.height > 0 else {
            throw SyntheticVisualRenderEntryError.hostUnavailable
        }

        var hierarchyWasDrawn = false
        let image = UIGraphicsImageRenderer(bounds: view.bounds).image { _ in
            hierarchyWasDrawn = view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        guard hierarchyWasDrawn, image.size.width > 0, image.size.height > 0 else {
            throw SyntheticVisualRenderEntryError.hierarchyCaptureFailed
        }

        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

@MainActor
private final class SyntheticVisualRenderHost {
    let window: UIWindow
    private(set) var controller: UIHostingController<LocalCaptureExperimentView>?

    private let scene: UIWindowScene
    private let previousKeyWindow: UIWindow
    private var isDetached = false

    private init(
        window: UIWindow,
        controller: UIHostingController<LocalCaptureExperimentView>,
        scene: UIWindowScene,
        previousKeyWindow: UIWindow
    ) {
        self.window = window
        self.controller = controller
        self.scene = scene
        self.previousKeyWindow = previousKeyWindow
    }

    var isUnambiguousAndVisible: Bool {
        guard let controller else { return false }
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        let visibleWindows = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }

        return activeScenes.count == 1
            && activeScenes.first === scene
            && visibleWindows.count == 1
            && visibleWindows.first === window
            && window.isKeyWindow
            && window.rootViewController === controller
            && controller.view.window === window
    }

    static func make(for view: LocalCaptureExperimentView) throws -> SyntheticVisualRenderHost {
        let activeScenes = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
        guard activeScenes.count == 1, let scene = activeScenes.first else {
            throw SyntheticVisualRenderEntryError.ambiguousForegroundScene
        }

        let visibleWindows = scene.windows.filter { !$0.isHidden && $0.alpha > 0 }
        guard visibleWindows.count == 1,
              let previousKeyWindow = visibleWindows.first,
              previousKeyWindow.isKeyWindow,
              previousKeyWindow.rootViewController != nil else {
            throw SyntheticVisualRenderEntryError.ambiguousApplicationWindow
        }

        let window = UIWindow(windowScene: scene)
        let controller = UIHostingController(rootView: view)
        window.frame = scene.coordinateSpace.bounds
        window.backgroundColor = .systemBackground
        window.rootViewController = controller
        previousKeyWindow.isHidden = true
        window.makeKeyAndVisible()
        window.setNeedsLayout()
        window.layoutIfNeeded()
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()

        let host = SyntheticVisualRenderHost(
            window: window,
            controller: controller,
            scene: scene,
            previousKeyWindow: previousKeyWindow
        )
        guard host.isUnambiguousAndVisible else {
            host.detach()
            throw SyntheticVisualRenderEntryError.hostUnavailable
        }
        return host
    }

    func detach() {
        guard !isDetached else { return }
        isDetached = true
        window.isHidden = true
        window.rootViewController = nil
        controller = nil
        previousKeyWindow.isHidden = false
        previousKeyWindow.makeKeyAndVisible()
    }
}

private enum SyntheticVisualRenderEntryError: LocalizedError {
    case ambiguousForegroundScene
    case ambiguousApplicationWindow
    case hostUnavailable
    case hierarchyCaptureFailed

    var errorDescription: String? {
        switch self {
        case .ambiguousForegroundScene:
            "Expected exactly one foreground-active window scene."
        case .ambiguousApplicationWindow:
            "Expected exactly one visible, keyed application window with a root controller."
        case .hostUnavailable:
            "The synthetic render host was not the sole visible window in its active scene."
        case .hierarchyCaptureFailed:
            "UIKit did not produce a nonempty hierarchy screenshot."
        }
    }
}
