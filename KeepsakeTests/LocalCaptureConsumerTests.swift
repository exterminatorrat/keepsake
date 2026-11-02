import CoreLocation
import Foundation
import Observation
import Testing
@testable import Keepsake

@MainActor
struct LocalCaptureConsumerTests {
    @Test(.timeLimit(.minutes(1)))
    func openingIsPassiveUntilExplicitStartRequestsPermission() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(
            store: store,
            reader: reader,
            authorization: .notDetermined
        )

        #expect(fixture.model.captureState == .stopped(controlRevision: 0))
        #expect(fixture.model.currentIntent == .stopped(controlRevision: 0))
        #expect(fixture.source.streamCount == 0)
        #expect(fixture.authorization.requestCount == 0)
        #expect(fixture.runtimePlatform.backgroundActivityHandles.isEmpty)

        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Expected the explicit Start action to request permission")
        } catch let error as LocalCaptureLifecycleError {
            #expect(error == .permissionRequestPending)
        } catch {
            Issue.record("Unexpected Start error: \(error)")
        }

        #expect(fixture.authorization.requestCount == 1)
        #expect(fixture.source.streamCount == 0)
        #expect(fixture.runtimePlatform.backgroundActivityHandles.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func resumeIsExplicitAndBackgroundInterruptionUpdatesTheConsumer() async throws {
        let recordingID = UUID()
        let store = LocalCaptureConsumerPersistenceFake(recordingID: recordingID)
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        guard case .resumeRequired(let previousEpoch, let controlRevision) = fixture.model.captureState else {
            Issue.record("Expected the verified active intent to require explicit resume")
            return
        }

        #expect(fixture.model.captureState == .resumeRequired(
            epoch: previousEpoch,
            controlRevision: previousEpoch.revision
        ))
        #expect(fixture.model.currentIntent == .resumeRequired(
            epoch: previousEpoch,
            controlRevision: previousEpoch.revision
        ))
        #expect(controlRevision == previousEpoch.revision)
        #expect(fixture.source.streamCount == 0)
        #expect(fixture.authorization.requestCount == 0)

        let resumedEpoch = try await fixture.model.resume()
        await fixture.source.waitForStreamCount(1)

        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > previousEpoch.revision)
        #expect(fixture.model.currentIntent == .recording(
            epoch: resumedEpoch,
            controlRevision: resumedEpoch.revision
        ))
        #expect(fixture.runtimePlatform.backgroundActivityHandles.count == 1)

        await waitForObservation(
            of: { fixture.model.lastInterruption },
            until: { $0 == .locationStreamEnded }
        ) {
            fixture.source.finish(stream: 0)
        }

        #expect(fixture.model.lastInterruption == .locationStreamEnded)
        #expect(fixture.model.captureState == .resumeRequired(
            epoch: resumedEpoch,
            controlRevision: resumedEpoch.revision
        ))
        #expect(fixture.model.currentIntent == .resumeRequired(
            epoch: resumedEpoch,
            controlRevision: resumedEpoch.revision
        ))
        #expect(fixture.source.streamCount == 1)
        #expect(await store.beginCallCount() == 1)
        #expect(await store.stopCallCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopRemainsAdmissibleWhileBeginIsPending() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let recordingID = UUID()
        await store.gateNextBegin()

        let begin = Task {
            try await fixture.model.startNewRecording(recordingID: recordingID)
        }
        await store.waitForBeginCall()

        let stop = Task { try await fixture.model.stop() }
        await waitForObservation(of: { fixture.model.captureState }, until: { state in
            if case .stopping = state {
                return true
            }
            return false
        })

        #expect(fixture.source.streamCount == 0)
        #expect(fixture.runtimePlatform.backgroundActivityHandles.isEmpty)

        await store.releaseBegin()

        do {
            _ = try await begin.value
            Issue.record("Expected Begin to be superseded by Stop")
        } catch let error as LocalCaptureCoordinatorError {
            #expect(error == .supersededByStop)
        } catch {
            Issue.record("Unexpected Begin error: \(error)")
        }

        _ = try await stop.value
        #expect(fixture.model.captureState == .stopped(controlRevision: 2))
        #expect(await store.beginCallCount() == 1)
        #expect(await store.stopCallCount() == 1)
        #expect(fixture.runtimePlatform.backgroundActivityHandles.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopRetryIsExplicitAfterAConfirmedNotCommittedFailure() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let epoch = try await fixture.model.startNewRecording(recordingID: UUID())
        await fixture.source.waitForStreamCount(1)
        await store.failNextStop()

        do {
            _ = try await fixture.model.stop()
            Issue.record("Expected Stop to remain unconfirmed after the injected failure")
        } catch let error as LocalCaptureCoordinatorError {
            guard case .stopUnconfirmed = error else {
                Issue.record("Unexpected Stop error: \(error)")
                return
            }
        } catch {
            Issue.record("Unexpected Stop error: \(error)")
        }

        guard case .stopUnconfirmed(_, let unconfirmedEpoch) = fixture.model.captureState else {
            Issue.record("Expected a failed Stop to remain explicitly unconfirmed")
            return
        }
        #expect(unconfirmedEpoch == epoch)
        #expect(await store.stopCallCount() == 1)

        _ = try await fixture.model.retryStop()

        #expect(fixture.model.captureState == .stopped(controlRevision: epoch.revision + 1))
        #expect(await store.stopCallCount() == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopClosesRuntimeWhileAnAdmittedAppendIsStillPending() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        _ = try await fixture.model.startNewRecording(recordingID: UUID())
        await fixture.source.waitForStreamCount(1)
        await store.gateNextAppend()
        fixture.source.emit(RecorderLocationUpdate(
            location: CLLocation(
                coordinate: CLLocationCoordinate2D(latitude: 10, longitude: 20),
                altitude: 0,
                horizontalAccuracy: 5,
                verticalAccuracy: 5,
                timestamp: Date(timeIntervalSinceReferenceDate: 100)
            ),
            stationary: false
        ))
        await store.waitForAppendCall()

        let stop = Task { try await fixture.model.stop() }
        await waitForObservation(of: { fixture.model.captureState }, until: { state in
            if case .stopping = state { return true }
            return false
        })
        #expect(fixture.runtimePlatform.backgroundActivityHandles.count == 1)
        #expect(fixture.runtimePlatform.backgroundActivityHandles.first?.isInvalidated == true)
        #expect(await store.stopCallCount() == 0)

        await store.releaseAppend()
        _ = try await stop.value
        #expect(fixture.model.captureState == .stopped(controlRevision: 2))
        #expect(await store.stopCallCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aPendingClearVetoesStart() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let operationID = UUID()
        await store.gateNextClear()

        let clear = Task {
            try await fixture.model.clearHistory(operationID: operationID)
        }
        await store.waitForClearCall()

        #expect(fixture.model.isClearingHistory)

        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Expected a pending clear to veto Start")
        } catch let error as LocalCaptureCoordinatorError {
            #expect(error == .historyClearPending)
        } catch {
            Issue.record("Unexpected Start error: \(error)")
        }

        await store.releaseClear()
        _ = try await clear.value

        #expect(await store.beginCallCount() == 0)
        #expect(await store.clearCallCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleClearCannotOverrideANewerRecordingIntent() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let newerRecording = try await store.beginExternally(recordingID: UUID())

        do {
            _ = try await fixture.model.clearHistory(operationID: UUID())
            Issue.record("Expected the stale clear revision to be rejected")
        } catch let error as CapturePersistenceError {
            #expect(error == .recordingActive)
        } catch {
            Issue.record("Unexpected Clear error: \(error)")
        }

        #expect(fixture.model.currentIntent == .resumeRequired(
            epoch: newerRecording.epoch,
            controlRevision: newerRecording.controlRevision
        ))

        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Expected the newer persisted intent to veto Start")
        } catch let error as LocalCaptureLifecycleError {
            #expect(error == .notStopped)
        } catch {
            Issue.record("Unexpected Start error: \(error)")
        }

        #expect(await store.clearCallCount() == 0)
        #expect(await store.beginCallCount() == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainClearVetoesStartUntilExplicitReconciliation() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let interval = historyInterval(start: 100)
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000)
        let query = Task {
            await fixture.model.selectHistoryQuery(interval: interval, queryNow: queryNow)
        }
        let historyRequest = await reader.nextRequest()
        let priorPage = historyPage(sequence: 1, nextCursor: nil)
        await reader.complete(historyRequest.id, with: priorPage)
        await query.value
        #expect(fixture.model.historyPage == priorPage)

        let operationID = UUID()
        await store.makeNextClearUncertainAfterCommit()

        do {
            _ = try await fixture.model.clearHistory(operationID: operationID)
            Issue.record("Expected an uncertain Clear result")
        } catch let error as LocalCaptureCoordinatorError {
            #expect(error == .unresolvedOperation(operationID))
        } catch {
            Issue.record("Unexpected Clear error: \(error)")
        }

        #expect(fixture.model.currentIntent == .unknown)
        #expect(fixture.model.historyPage == nil)

        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Expected an uncertain clear to veto Start")
        } catch let error as LocalCaptureLifecycleError {
            #expect(error == .notStopped)
        } catch {
            Issue.record("Unexpected Start error: \(error)")
        }

        #expect(await store.beginCallCount() == 0)

        let reconciliation = try await fixture.model.reconcileUncertain()
        guard case .clearCommitted(let receipt) = reconciliation else {
            Issue.record("Expected explicit reconciliation to verify the Clear receipt")
            return
        }

        #expect(receipt.operationID == operationID)
        #expect(fixture.model.currentIntent == .stopped(controlRevision: 0))
        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(await reader.requestCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearUsesTheExpectedRevisionAndReceiptAndDropsALateRead() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let interval = historyInterval(start: 100)
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000)
        let firstQuery = Task {
            await fixture.model.selectHistoryQuery(interval: interval, queryNow: queryNow)
        }
        let firstRequest = await reader.nextRequest()
        let cursor = historyCursor(sequence: 1, interval: interval, queryNow: queryNow)
        let firstPage = historyPage(sequence: 1, nextCursor: cursor)
        await reader.complete(firstRequest.id, with: firstPage)
        await firstQuery.value

        #expect(fixture.model.historyPage == firstPage)
        #expect(fixture.model.hasMoreHistoryPages)

        let nextPage = Task { await fixture.model.loadNextHistoryPage() }
        let nextRequest = await reader.nextRequest()
        #expect(nextRequest.cursor == cursor)
        #expect(fixture.model.historyPage == firstPage)
        await store.gateNextClear()

        let operationID = UUID()
        let clear = Task {
            try await fixture.model.clearHistory(operationID: operationID)
        }
        await store.waitForClearCall()

        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(fixture.model.isClearingHistory)

        await store.releaseClear()
        let receipt = try await clear.value
        let clearCalls = await store.recordedClearCalls()

        #expect(receipt.operationID == operationID)
        #expect(receipt.controlRevision == 0)
        #expect(clearCalls == [LocalCaptureConsumerClearCall(
            expectedControlRevision: 0,
            operationID: operationID
        )])
        #expect(!fixture.model.isClearingHistory)

        await reader.complete(nextRequest.id, with: historyPage(sequence: 2, nextCursor: nil))
        await nextPage.value

        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(await reader.requestCount() == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func maintenanceInvalidationDropsAnOutstandingPageUntilExplicitRefresh() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let interval = historyInterval(start: 100)
        let query = Task {
            await fixture.model.selectHistoryQuery(
                interval: interval,
                queryNow: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        }
        let request = await reader.nextRequest()

        fixture.model.invalidateHistoryForMaintenance()
        await reader.complete(request.id, with: historyPage(sequence: 1, nextCursor: nil))
        await query.value

        #expect(fixture.model.historyPage == nil)
        #expect(!fixture.model.isHistoryLoading)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(await reader.requestCount() == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func historyUsesTheExactCursorAndReplacesEachBoundedPage() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let interval = historyInterval(start: 100)
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000)
        var pageTask = Task {
            await fixture.model.selectHistoryQuery(interval: interval, queryNow: queryNow)
        }
        var request = await reader.nextRequest()
        var previousCursor: CapturePageCursor?

        for sequence in 1...5 {
            let nextCursor = sequence < 5
                ? historyCursor(sequence: Int64(sequence), interval: interval, queryNow: queryNow)
                : nil
            let page = historyPage(sequence: Int64(sequence), nextCursor: nextCursor)

            #expect(request.interval == interval)
            #expect(request.queryNow == queryNow)
            #expect(request.limit == LocalCaptureConsumerModel.defaultHistoryPageLimit)
            #expect(request.cursor == previousCursor)

            await reader.complete(request.id, with: page)
            await pageTask.value

            #expect(fixture.model.historyPage == page)
            #expect(fixture.model.historyPage?.items.map(\.sequence) == [Int64(sequence)])
            #expect(fixture.model.hasMoreHistoryPages == (sequence < 5))
            #expect(fixture.model.canLoadNextHistoryPage == (sequence < 5))

            guard sequence < 5 else {
                continue
            }
            previousCursor = nextCursor
            pageTask = Task { await fixture.model.loadNextHistoryPage() }
            request = await reader.nextRequest()
            let repeatedPageTask = Task { await fixture.model.loadNextHistoryPage() }
            await repeatedPageTask.value
            #expect(await reader.requestCount() == sequence + 1)
        }

        #expect(await reader.requestCount() == 5)
    }

    @Test(.timeLimit(.minutes(1)))
    func maintenanceBlocksQueuedStartAndClearWithoutBlockingStop() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        let receipt = CapturePruneReceipt(
            operationID: UUID(),
            commandDigest: CaptureCommandDigest.prune(now: Date(timeIntervalSinceReferenceDate: 2_000), limit: 64),
            deletionRevision: 0,
            deletedRows: 0,
            deletedPayloadBytes: 0,
            hasMore: false
        )
        let maintenance = Task {
            try await fixture.model.pruneHistory {
                startSignal.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
                return receipt
            }
        }
        var startIterator = started.makeAsyncIterator()
        _ = await startIterator.next()

        #expect(fixture.model.isMaintainingHistory)
        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Start must not overtake admitted maintenance")
        } catch let error as LocalCaptureConsumerError {
            #expect(error == .historyMaintenancePending)
        }
        do {
            _ = try await fixture.model.clearHistory()
            Issue.record("Clear must not overtake admitted maintenance")
        } catch let error as LocalCaptureConsumerError {
            #expect(error == .historyMaintenancePending)
        }
        let stop = try await fixture.model.stop()
        guard case .alreadyStopped = stop else {
            Issue.record("Stop should remain admissible during stopped maintenance")
            releaseSignal.yield(())
            _ = try await maintenance.value
            return
        }
        #expect(await store.beginCallCount() == 0)
        #expect(await store.clearCallCount() == 0)
        releaseSignal.yield(())
        #expect(try await maintenance.value == receipt)
        #expect(!fixture.model.isMaintainingHistory)
        #expect(!fixture.model.historyMaintenanceRequiresReopen)
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainMaintenanceRequiresANewVerifiedSessionAndNeverRetries() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let operationID = UUID()
        var attempts = 0
        do {
            _ = try await fixture.model.pruneHistory {
                attempts += 1
                throw CapturePersistenceError.outcomeUncertain(operationID)
            }
            Issue.record("Maintenance must surface its uncertain outcome")
        } catch let error as CapturePersistenceError {
            #expect(error == .outcomeUncertain(operationID))
        }
        #expect(fixture.model.historyMaintenanceRequiresReopen)
        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)

        do {
            _ = try await fixture.model.startNewRecording(recordingID: UUID())
            Issue.record("Unconfirmed maintenance must veto Start")
        } catch let error as LocalCaptureConsumerError {
            #expect(error == .historyMaintenanceRequiresReopen)
        }
        do {
            _ = try await fixture.model.pruneHistory {
                attempts += 1
                throw CapturePersistenceError.outcomeUncertain(operationID)
            }
            Issue.record("Maintenance must never replay through the old session")
        } catch let error as LocalCaptureConsumerError {
            #expect(error == .historyMaintenanceRequiresReopen)
        }
        await fixture.model.selectHistoryQuery(
            interval: historyInterval(start: 100),
            queryNow: Date(timeIntervalSinceReferenceDate: 2_000)
        )
        #expect(await reader.requestCount() == 0)
        #expect(await store.beginCallCount() == 0)
        #expect(attempts == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func historyPageLimitCannotExceedTheStorageMaximum() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(
            store: store,
            reader: reader,
            historyPageLimit: Int.max
        )
        let interval = historyInterval(start: 100)
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000)
        let query = Task {
            await fixture.model.selectHistoryQuery(interval: interval, queryNow: queryNow)
        }
        let request = await reader.nextRequest()

        #expect(request.limit == CapturePersistenceLimits.maximumPageRows)

        await reader.complete(request.id, with: historyPage(sequence: 1, nextCursor: nil))
        await query.value
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            CapturePersistenceError.cursorInvalidated,
            CapturePersistenceError.unavailable(.storeClosed)
        ]
    )
    func anInvalidatedCursorOrClosedStoreClearsTheWindowAndWaitsForRefresh(
        _ error: CapturePersistenceError
    ) async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let interval = historyInterval(start: 100)
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000)
        let query = Task {
            await fixture.model.selectHistoryQuery(interval: interval, queryNow: queryNow)
        }
        let firstRequest = await reader.nextRequest()
        let cursor = historyCursor(sequence: 1, interval: interval, queryNow: queryNow)
        await reader.complete(firstRequest.id, with: historyPage(sequence: 1, nextCursor: cursor))
        await query.value

        let nextPage = Task { await fixture.model.loadNextHistoryPage() }
        let nextRequest = await reader.nextRequest()
        #expect(nextRequest.cursor == cursor)
        await reader.fail(nextRequest.id, with: error)
        await nextPage.value

        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.historyError != nil)
        #expect(fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(!fixture.model.canLoadNextHistoryPage)
        #expect(await reader.requestCount() == 2)

        let refreshedNow = Date(timeIntervalSinceReferenceDate: 3_000)
        let refresh = Task { await fixture.model.refreshHistory(queryNow: refreshedNow) }
        let refreshedRequest = await reader.nextRequest()
        #expect(refreshedRequest.cursor == nil)
        #expect(refreshedRequest.interval == interval)
        #expect(refreshedRequest.queryNow == refreshedNow)
        await reader.complete(refreshedRequest.id, with: historyPage(sequence: 3, nextCursor: nil))
        await refresh.value

        #expect(fixture.model.historyPage?.items.map(\.sequence) == [3])
        #expect(fixture.model.historyError == nil)
        #expect(!fixture.model.isHistoryAwaitingExplicitRefresh)
        #expect(await reader.requestCount() == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func changingDayAndRefreshingDropLateReadsAndKeepOnlyTheNewestQuery() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let oldInterval = historyInterval(start: 100)
        let newInterval = historyInterval(start: 200)
        let initialNow = Date(timeIntervalSinceReferenceDate: 2_000)
        let refreshedNow = Date(timeIntervalSinceReferenceDate: 3_000)
        let oldQuery = Task {
            await fixture.model.selectHistoryQuery(interval: oldInterval, queryNow: initialNow)
        }
        let oldRequest = await reader.nextRequest()

        let newQuery = Task {
            await fixture.model.selectHistoryQuery(interval: newInterval, queryNow: initialNow)
        }
        let newRequest = await reader.nextRequest()
        #expect(newRequest.interval == newInterval)
        #expect(newRequest.cursor == nil)

        await reader.complete(oldRequest.id, with: historyPage(sequence: 1, nextCursor: nil))
        await oldQuery.value

        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.historyQuery?.interval == newInterval)
        #expect(fixture.model.isHistoryLoading)

        let refresh = Task { await fixture.model.refreshHistory(queryNow: refreshedNow) }
        let refreshedRequest = await reader.nextRequest()
        #expect(refreshedRequest.interval == newInterval)
        #expect(refreshedRequest.queryNow == refreshedNow)
        #expect(refreshedRequest.cursor == nil)

        await reader.complete(newRequest.id, with: historyPage(sequence: 2, nextCursor: nil))
        await newQuery.value

        #expect(fixture.model.historyPage == nil)
        #expect(fixture.model.historyQuery?.queryNow == refreshedNow)
        #expect(fixture.model.isHistoryLoading)

        let newestPage = historyPage(sequence: 3, nextCursor: nil)
        await reader.complete(refreshedRequest.id, with: newestPage)
        await refresh.value

        #expect(fixture.model.historyPage == newestPage)
        #expect(await reader.requestCount() == 3)
    }

    @Test(.timeLimit(.minutes(1)))
    func disposalCancelsAndDropsAnOutstandingPageRead() async throws {
        let store = LocalCaptureConsumerPersistenceFake()
        let reader = LocalCaptureHistoryReaderFake()
        let fixture = try await makeConsumerFixture(store: store, reader: reader)
        let query = Task {
            await fixture.model.selectHistoryQuery(
                interval: historyInterval(start: 100),
                queryNow: Date(timeIntervalSinceReferenceDate: 2_000)
            )
        }
        let request = await reader.nextRequest()

        fixture.model.dispose()

        #expect(fixture.model.historyPage == nil)
        #expect(!fixture.model.isHistoryLoading)

        await reader.complete(request.id, with: historyPage(sequence: 1, nextCursor: nil))
        await query.value

        #expect(fixture.model.historyPage == nil)
        #expect(await reader.requestCount() == 1)
    }
}

@MainActor
private struct LocalCaptureConsumerFixture {
    let model: LocalCaptureConsumerModel
    let source: LocalCaptureConsumerLocationSourceFake
    let authorization: LocalCaptureConsumerAuthorizationFake
    let runtimePlatform: LocalCaptureConsumerRuntimePlatformFake
}

@MainActor
private func makeConsumerFixture(
    store: LocalCaptureConsumerPersistenceFake,
    reader: LocalCaptureHistoryReaderFake,
    authorization locationAuthorization: LocationAuthorization = .whileInUse,
    historyPageLimit: Int = LocalCaptureConsumerModel.defaultHistoryPageLimit
) async throws -> LocalCaptureConsumerFixture {
    let source = LocalCaptureConsumerLocationSourceFake()
    let authorization = LocalCaptureConsumerAuthorizationFake(
        capabilities: LocationCapabilities(
            servicesEnabled: true,
            authorization: locationAuthorization,
            fullAccuracy: locationAuthorization == .whileInUse || locationAuthorization == .always
        )
    )
    let runtimePlatform = LocalCaptureConsumerRuntimePlatformFake()
    let lifecycle = try await LocalCaptureLifecycle.open(
        persistence: store,
        reopenVerifiedStore: { store },
        locationUpdateSource: source,
        authorization: authorization,
        runtimePlatform: runtimePlatform,
        now: { Date(timeIntervalSinceReferenceDate: 10_000) },
        isLocationServicesEnabled: { authorization.capabilities.servicesEnabled }
    )
    let model = LocalCaptureConsumerModel(
        lifecycle: lifecycle,
        historyReader: reader,
        historyPageLimit: historyPageLimit
    )
    return LocalCaptureConsumerFixture(
        model: model,
        source: source,
        authorization: authorization,
        runtimePlatform: runtimePlatform
    )
}

private func historyInterval(start: TimeInterval) -> CapturePageInterval {
    let intervalStart = Date(timeIntervalSinceReferenceDate: start)
    return CapturePageInterval(start: intervalStart, end: intervalStart.addingTimeInterval(86_400))
}

private func historyCursor(
    sequence: Int64,
    interval: CapturePageInterval,
    queryNow: Date
) -> CapturePageCursor {
    CapturePageCursor(
        storeOpenID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
        interval: interval,
        queryNow: queryNow,
        highWaterSequence: 100,
        deletionRevision: 1,
        lastObservedAt: interval.start.addingTimeInterval(TimeInterval(sequence)),
        lastSequence: sequence
    )
}

private func historyPage(sequence: Int64, nextCursor: CapturePageCursor?) -> CapturePage {
    let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
    let sample = RouteSample(
        recordingID: epoch.recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: TimeInterval(sequence)),
        latitude: 37.3317,
        longitude: -122.0301,
        horizontalAccuracy: 5,
        isStationary: false
    )
    return CapturePage(
        items: [CaptureSampleEnvelope(sample: sample, epoch: epoch, sequence: sequence)],
        encodedPayloadBytes: 64,
        nextCursor: nextCursor
    )
}

@MainActor
private func waitForObservation<Value>(
    of value: @escaping @MainActor () -> Value,
    until predicate: @escaping (Value) -> Bool,
    triggering trigger: @MainActor () -> Void = {}
) async {
    while !predicate(value()) {
        await withCheckedContinuation { continuation in
            withObservationTracking {
                _ = value()
            } onChange: {
                Task { @MainActor in
                    continuation.resume()
                }
            }
            trigger()
        }
    }
}

@MainActor
private final class LocalCaptureConsumerLocationSourceFake: RecorderLocationUpdateSource {
    private var continuations: [AsyncThrowingStream<RecorderLocationUpdate, Error>.Continuation] = []
    private var streamWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var streamCount: Int {
        continuations.count
    }

    func collect(_ receive: @escaping @MainActor (RecorderLocationUpdate) async -> Bool) async throws {
        let (stream, continuation) = AsyncThrowingStream<RecorderLocationUpdate, Error>.makeStream(
            of: RecorderLocationUpdate.self,
            throwing: Error.self
        )
        continuations.append(continuation)
        let ready = streamWaiters.filter { $0.0 <= continuations.count }
        streamWaiters.removeAll { $0.0 <= continuations.count }
        for (_, waiter) in ready {
            waiter.resume()
        }

        for try await update in stream {
            guard await receive(update) else {
                return
            }
        }
    }

    func finish(stream index: Int) {
        continuations[index].finish()
    }

    func emit(_ update: RecorderLocationUpdate) {
        continuations[0].yield(update)
    }

    func waitForStreamCount(_ count: Int) async {
        guard continuations.count < count else {
            return
        }
        await withCheckedContinuation { streamWaiters.append((count, $0)) }
    }
}

@MainActor
private final class LocalCaptureConsumerAuthorizationFake: RecorderAuthorizationObservation {
    var capabilities: LocationCapabilities
    var onChange: (() -> Void)?
    private(set) var requestCount = 0

    init(capabilities: LocationCapabilities) {
        self.capabilities = capabilities
    }

    func refreshServicesEnabled() {}

    func requestWhenInUseAuthorization() {
        requestCount += 1
    }
}

@MainActor
private final class LocalCaptureConsumerRuntimePlatformFake: RecorderRuntimePlatform {
    private(set) var backgroundActivityHandles: [LocalCaptureConsumerBackgroundActivityFake] = []

    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle {
        let handle = LocalCaptureConsumerBackgroundActivityFake()
        backgroundActivityHandles.append(handle)
        return handle
    }

    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle {
        LocalCaptureConsumerServiceSessionFake()
    }
}

@MainActor
private final class LocalCaptureConsumerBackgroundActivityFake: RecorderBackgroundActivityHandle {
    private(set) var isInvalidated = false

    func invalidate() {
        isInvalidated = true
    }
}

@MainActor
private final class LocalCaptureConsumerServiceSessionFake: RecorderServiceSessionHandle {
    func collectDiagnostics(
        _ receive: @escaping @MainActor (RecorderServiceDiagnostic) async -> Void
    ) async throws {}

    func invalidate() {}
}

private struct LocalCaptureConsumerClearCall: Equatable, Sendable {
    let expectedControlRevision: Int64
    let operationID: UUID
}

private actor LocalCaptureConsumerPersistenceFake: LocalCapturePersistence {
    private var control: CaptureControlSnapshot
    private let highWaterSequence: Int64
    private var receipts: [UUID: CaptureReceipt] = [:]
    private var beginGated = false
    private var beginBarrier: CheckedContinuation<Void, Never>?
    private var beginWaiters: [CheckedContinuation<Void, Never>] = []
    private var beginCalls = 0
    private var appendCalls = 0
    private var appendGated = false
    private var appendBarrier: CheckedContinuation<Void, Never>?
    private var appendWaiters: [CheckedContinuation<Void, Never>] = []
    private var stopCalls = 0
    private var clearCalls = 0
    private var clearGated = false
    private var clearBarrier: CheckedContinuation<Void, Never>?
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearUncertainAfterCommit = false
    private var failStop = false
    private var clearRequestLog: [LocalCaptureConsumerClearCall] = []

    init(recordingID: UUID? = nil, highWaterSequence: Int64 = 10) {
        self.highWaterSequence = highWaterSequence
        if let recordingID {
            let epoch = CaptureEpoch(recordingID: recordingID, revision: 1)
            let receipt = CaptureControlReceipt(
                operationID: UUID(),
                kind: .begin,
                epoch: epoch,
                controlRevision: 1,
                commandDigest: CaptureCommandDigest.begin(recordingID: recordingID, expectedControlRevision: 0)
            )
            control = CaptureControlSnapshot(
                revision: 1,
                activeEpoch: epoch,
                lastControlReceipt: receipt
            )
            receipts[receipt.operationID] = .control(receipt)
        } else {
            control = CaptureControlSnapshot(revision: 0, activeEpoch: nil, lastControlReceipt: nil)
        }
    }

    func readControl() async throws -> CaptureControlSnapshot {
        control
    }

    func beginRecording(
        recordingID: UUID,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        beginCalls += 1
        resume(&beginWaiters)
        if beginGated {
            await withCheckedContinuation { beginBarrier = $0 }
            beginGated = false
        }
        return try commitBegin(
            recordingID: recordingID,
            expectedControlRevision: expectedControlRevision,
            operationID: operationID
        )
    }

    func appendBatch(
        _ samples: [RouteSample],
        epoch: CaptureEpoch,
        operationID: UUID,
        now: Date
    ) async throws -> CaptureBatchReceipt {
        appendCalls += 1
        resume(&appendWaiters)
        if appendGated {
            await withCheckedContinuation { appendBarrier = $0 }
            appendGated = false
        }
        guard control.activeEpoch == epoch else {
            throw CapturePersistenceError.staleEpoch
        }
        let input = try CaptureBatchInput(samples: samples)
        let receipt = CaptureBatchReceipt(
            operationID: operationID,
            epoch: epoch,
            commandDigest: CaptureCommandDigest.batch(epoch: epoch, input: input),
            items: samples.map { CaptureSampleResult(sampleID: $0.id, disposition: .stored) }
        )
        receipts[operationID] = .batch(receipt)
        return receipt
    }

    func stopRecording(
        epoch: CaptureEpoch,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        stopCalls += 1
        if failStop {
            failStop = false
            throw CapturePersistenceError.notCommitted(.writeFailed)
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        guard control.activeEpoch == epoch else {
            throw CapturePersistenceError.staleEpoch
        }
        let nextRevision = expectedControlRevision + 1
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .stop,
            epoch: epoch,
            controlRevision: nextRevision,
            commandDigest: CaptureCommandDigest.stop(
                epoch: epoch,
                expectedControlRevision: expectedControlRevision
            )
        )
        control = CaptureControlSnapshot(
            revision: nextRevision,
            activeEpoch: nil,
            lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        return receipt
    }

    func clearHistory(
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureClearReceipt {
        clearCalls += 1
        clearRequestLog.append(LocalCaptureConsumerClearCall(
            expectedControlRevision: expectedControlRevision,
            operationID: operationID
        ))
        resume(&clearWaiters)
        if clearGated {
            await withCheckedContinuation { clearBarrier = $0 }
            clearGated = false
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        guard control.activeEpoch == nil else {
            throw CapturePersistenceError.recordingActive
        }

        let advancesFloor = highWaterSequence > control.clearedThroughSequence
        let deletionRevision = advancesFloor ? control.deletionRevision + 1 : control.deletionRevision
        let receipt = CaptureClearReceipt(
            operationID: operationID,
            controlRevision: expectedControlRevision,
            deletionRevision: deletionRevision,
            clearedThroughSequence: max(control.clearedThroughSequence, highWaterSequence),
            commandDigest: CaptureCommandDigest.clear(expectedControlRevision: expectedControlRevision)
        )
        control = CaptureControlSnapshot(
            revision: control.revision,
            activeEpoch: control.activeEpoch,
            lastControlReceipt: control.lastControlReceipt,
            deletionRevision: deletionRevision,
            clearedThroughSequence: receipt.clearedThroughSequence,
            lastClearReceipt: receipt
        )
        receipts[operationID] = .clear(receipt)
        if clearUncertainAfterCommit {
            clearUncertainAfterCommit = false
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }
        return receipt
    }

    func lookupReceipt(operationID: UUID) async throws -> CaptureReceiptLookup {
        guard let receipt = receipts[operationID] else {
            return .unavailable
        }
        return .found(receipt)
    }

    func reconcileSamples(
        _ samples: [RouteSample],
        epoch: CaptureEpoch
    ) async throws -> [CaptureSampleReconciliation] {
        samples.map { CaptureSampleReconciliation(sampleID: $0.id, match: .absentOrExpired) }
    }

    func beginExternally(recordingID: UUID) throws -> CaptureControlReceipt {
        try commitBegin(
            recordingID: recordingID,
            expectedControlRevision: control.revision,
            operationID: UUID()
        )
    }

    func gateNextBegin() {
        beginGated = true
    }

    func gateNextAppend() {
        appendGated = true
    }

    func waitForAppendCall() async {
        guard appendCalls == 0 else { return }
        await withCheckedContinuation { appendWaiters.append($0) }
    }

    func releaseAppend() {
        appendBarrier?.resume()
        appendBarrier = nil
    }

    func waitForBeginCall() async {
        guard beginCalls == 0 else {
            return
        }
        await withCheckedContinuation { beginWaiters.append($0) }
    }

    func releaseBegin() {
        beginBarrier?.resume()
        beginBarrier = nil
    }

    func beginCallCount() -> Int {
        beginCalls
    }

    func failNextStop() {
        failStop = true
    }

    func stopCallCount() -> Int {
        stopCalls
    }

    func gateNextClear() {
        clearGated = true
    }

    func waitForClearCall() async {
        guard clearCalls == 0 else {
            return
        }
        await withCheckedContinuation { clearWaiters.append($0) }
    }

    func releaseClear() {
        clearBarrier?.resume()
        clearBarrier = nil
    }

    func makeNextClearUncertainAfterCommit() {
        clearUncertainAfterCommit = true
    }

    func clearCallCount() -> Int {
        clearCalls
    }

    func recordedClearCalls() -> [LocalCaptureConsumerClearCall] {
        clearRequestLog
    }

    private func commitBegin(
        recordingID: UUID,
        expectedControlRevision: Int64,
        operationID: UUID
    ) throws -> CaptureControlReceipt {
        let digest = CaptureCommandDigest.begin(
            recordingID: recordingID,
            expectedControlRevision: expectedControlRevision
        )
        if let known = receipts[operationID] {
            guard case .control(let receipt) = known,
                  receipt.commandDigest == digest else {
                throw CapturePersistenceError.operationConflict
            }
            return receipt
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        if let activeEpoch = control.activeEpoch,
           activeEpoch.recordingID != recordingID {
            throw CapturePersistenceError.activeRecordingMismatch
        }
        guard control.revision < Int64.max else {
            throw CapturePersistenceError.revisionExhausted
        }
        let revision = control.revision + 1
        let epoch = CaptureEpoch(recordingID: recordingID, revision: revision)
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .begin,
            epoch: epoch,
            controlRevision: revision,
            commandDigest: digest
        )
        control = CaptureControlSnapshot(
            revision: revision,
            activeEpoch: epoch,
            lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        return receipt
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

private actor LocalCaptureHistoryReaderFake: LocalCaptureHistoryReading {
    struct Request: Equatable, Sendable {
        let id: UUID
        let interval: CapturePageInterval
        let queryNow: Date
        let limit: Int
        let cursor: CapturePageCursor?
    }

    private struct PendingRead {
        let request: Request
        let continuation: CheckedContinuation<CapturePage, any Error>
    }

    private var pendingReads: [UUID: PendingRead] = [:]
    private var requestQueue: [Request] = []
    private var requestWaiters: [CheckedContinuation<Request, Never>] = []
    private var totalRequests = 0

    func readPage(
        interval: CapturePageInterval,
        now: Date,
        limit: Int,
        cursor: CapturePageCursor?
    ) async throws -> CapturePage {
        let request = Request(
            id: UUID(),
            interval: interval,
            queryNow: now,
            limit: limit,
            cursor: cursor
        )
        totalRequests += 1
        return try await withCheckedThrowingContinuation { continuation in
            pendingReads[request.id] = PendingRead(request: request, continuation: continuation)
            if requestWaiters.isEmpty {
                requestQueue.append(request)
            } else {
                requestWaiters.removeFirst().resume(returning: request)
            }
        }
    }

    func nextRequest() async -> Request {
        if !requestQueue.isEmpty {
            return requestQueue.removeFirst()
        }
        return await withCheckedContinuation { requestWaiters.append($0) }
    }

    func complete(_ requestID: UUID, with page: CapturePage) {
        pendingReads.removeValue(forKey: requestID)?.continuation.resume(returning: page)
    }

    func fail(_ requestID: UUID, with error: CapturePersistenceError) {
        pendingReads.removeValue(forKey: requestID)?.continuation.resume(throwing: error)
    }

    func requestCount() -> Int {
        totalRequests
    }
}
