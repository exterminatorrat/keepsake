import Testing
@testable import Keepsake

@MainActor
struct LocalCaptureExperimentSyntheticVisualFixtureTests {
    @Test(.timeLimit(.minutes(1)))
    func historyStartsEmptyThenNextReplacesThreePointsWithTwoWithoutActions() async throws {
        let fixture = try await LocalCaptureExperimentSyntheticVisualFixture.make()
        defer { fixture.dispose() }

        #expect(fixture.model.captureState == .stopped(controlRevision: 2))
        #expect(fixture.model.historyPage == nil)

        let initialAudit = await fixture.audit()
        #expect(initialAudit.historyRequests.isEmpty)
        #expect(initialAudit.controlReadCount == 1)
        #expect(initialAudit.controlSnapshot.revision == 2)
        #expect(initialAudit.controlSnapshot.activeEpoch == nil)
        let stopReceipt = try #require(initialAudit.controlSnapshot.lastControlReceipt)
        #expect(stopReceipt.kind == .stop)
        #expect(stopReceipt.controlRevision == 2)
        #expect(stopReceipt.epoch.revision == 1)
        #expect(stopReceipt.commandDigest == CaptureCommandDigest.stop(
            epoch: stopReceipt.epoch,
            expectedControlRevision: 1
        ))

        await fixture.view.selectDay()

        let firstPage = try #require(fixture.model.historyPage)
        #expect(firstPage.items.map(\.sample.id) == fixture.firstSampleIDs)
        #expect(firstPage.items.allSatisfy { $0.epoch == stopReceipt.epoch })
        #expect(firstPage.nextCursor == fixture.firstCursor)
        #expect(fixture.model.canLoadNextHistoryPage)
        #expect(fixture.model.historyQuery?.interval == fixture.interval)
        #expect(fixture.model.historyQuery?.queryNow == fixture.queryNow)
        #expect(fixture.model.historyQuery?.pageLimit == LocalCaptureConsumerModel.defaultHistoryPageLimit)

        await fixture.model.loadNextHistoryPage()

        let nextPage = try #require(fixture.model.historyPage)
        #expect(nextPage.items.map(\.sample.id) == fixture.nextSampleIDs)
        #expect(nextPage.items.allSatisfy { $0.epoch == stopReceipt.epoch })
        #expect(nextPage.items.count == 2)
        #expect(nextPage.nextCursor == nil)
        #expect(!fixture.model.hasMoreHistoryPages)
        #expect(fixture.model.captureState == .stopped(controlRevision: 2))

        let audit = await fixture.audit()
        #expect(audit.historyRequests.map(\.cursor) == [nil, fixture.firstCursor])
        #expect(audit.historyRequests.allSatisfy {
            $0.interval == fixture.interval
                && $0.now == fixture.queryNow
                && $0.limit == LocalCaptureConsumerModel.defaultHistoryPageLimit
        })
        #expect(audit.forbiddenActionCount == 0)
        #expect(audit.unexpectedCallCount == 0)
        #expect(audit.unexpectedHistoryRequestCount == 0)
        #expect(audit.locationCollectCount == 0)
        #expect(audit.authorizationRefreshCount == 0)
        #expect(audit.authorizationRequestCount == 0)
        #expect(audit.servicesStatusReadCount == 0)
        #expect(audit.backgroundActivityHandleCount == 0)
        #expect(audit.serviceSessionHandleCount == 0)
        #expect(audit.pruneCalls == 0)
        #expect(audit.closeCalls == 0)
    }
}
