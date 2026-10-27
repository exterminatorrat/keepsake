import Darwin
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Keepsake

struct CaptureHistoryTests {
    @Test(arguments: [1, 3], [false, true])
    func pageProtectionFailureClosesTheWriterBeforeOrAfterReadCommit(failingCheck: Int, backupFailure: Bool) async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let checks = Mutex(0)
        let seams = captureHistoryStorageSeams(readProtection: { url in
            if url == fixture.store {
                let count = checks.withLock { value in
                    value += 1
                    return value
                }
                if count >= failingCheck {
                    if backupFailure {
                        var mutableURL = url
                        var values = URLResourceValues()
                        values.isExcludedFromBackup = false
                        try mutableURL.setResourceValues(values)
                    } else {
                        return nil
                    }
                }
            }
            return try captureHistoryReadProtection(url)
        })
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store, seams: seams)
        let now = Date.now
        await expectCaptureHistoryError(.unavailable(backupFailure ? .backupExclusionFailed : .protectionFailed)) {
            _ = try await store.readPage(
                interval: CapturePageInterval(start: now.addingTimeInterval(-1), end: now),
                now: now,
                limit: 1,
                cursor: nil
            )
        }
        await expectCaptureHistoryError(.unavailable(.storeClosed)) {
            _ = try await store.readControl()
        }
        #expect(checks.withLock { $0 } >= failingCheck)
        await store.close()
        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        #expect(try await reopened.readControl().revision == 0)
        await reopened.close()
    }

    @Test func pagesAtTheRowLimitAndPreservesEpochAndExactSamples() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(1)
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: captureHistoryUUID(2)
        )
        let samples = (0..<260).map { index in
            captureHistorySample(
                at: 1_999_000_000 + Double(index),
                id: captureHistoryUUID(10_000 + index),
                recordingID: recordingID,
                latitude: index == 0 ? -0.0 : 12.3456,
                longitude: index == 0 ? -0.0 : -45.6789,
                includeOptionalMeasurements: index == 0
            )
        }

        for start in stride(from: 0, to: samples.count, by: CapturePersistenceLimits.maximumBatchSamples) {
            let end = min(start + CapturePersistenceLimits.maximumBatchSamples, samples.count)
            let batch = Array(samples[start..<end])
            let receipt = try await store.appendBatch(
                batch,
                epoch: begin.epoch,
                operationID: captureHistoryUUID(20_000 + start),
                now: now
            )
            #expect(receipt.items.allSatisfy { $0.disposition == .stored })
        }

        let interval = CapturePageInterval(
            start: samples[0].observedAt,
            end: samples[samples.count - 1].observedAt.addingTimeInterval(1)
        )
        let firstPage = try await store.readPage(interval: interval, now: now, limit: CapturePersistenceLimits.maximumPageRows, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)
        let secondPage = try await store.readPage(
            interval: interval,
            now: now,
            limit: CapturePersistenceLimits.maximumPageRows,
            cursor: cursor
        )
        let allItems = firstPage.items + secondPage.items

        #expect(firstPage.items.count == CapturePersistenceLimits.maximumPageRows)
        #expect(secondPage.items.count == samples.count - CapturePersistenceLimits.maximumPageRows)
        #expect(firstPage.encodedPayloadBytes <= CapturePersistenceLimits.maximumPagePayloadBytes)
        #expect(secondPage.encodedPayloadBytes <= CapturePersistenceLimits.maximumPagePayloadBytes)
        #expect(RouteStoreFiles.exactSamplesEquality(allItems.map(\.sample), samples))
        #expect(allItems.allSatisfy { $0.epoch == begin.epoch })
        #expect(zip(allItems, allItems.dropFirst()).allSatisfy { $0.0.sequence < $0.1.sequence })
        #expect(secondPage.nextCursor == nil)
        await store.close()
    }

    @Test func pageEnvelopesRetainTheEpochThatAdmittedEachSample() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let firstRecordingID = captureHistoryUUID(3)
        let secondRecordingID = captureHistoryUUID(4)
        let firstSample = captureHistorySample(
            at: 1_999_999_000,
            id: captureHistoryUUID(5),
            recordingID: firstRecordingID,
            latitude: -0.0,
            longitude: -0.0,
            includeOptionalMeasurements: true
        )
        let secondSample = captureHistorySample(
            at: 1_999_999_060,
            id: captureHistoryUUID(6),
            recordingID: secondRecordingID
        )
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let firstEpoch = try await store.beginRecording(
            recordingID: firstRecordingID,
            expectedControlRevision: 0,
            operationID: captureHistoryUUID(7)
        )
        _ = try await store.appendBatch([firstSample], epoch: firstEpoch.epoch, operationID: captureHistoryUUID(8), now: now)
        let stopped = try await store.stopRecording(
            epoch: firstEpoch.epoch,
            expectedControlRevision: firstEpoch.controlRevision,
            operationID: captureHistoryUUID(9)
        )
        let secondEpoch = try await store.beginRecording(
            recordingID: secondRecordingID,
            expectedControlRevision: stopped.controlRevision,
            operationID: captureHistoryUUID(10)
        )
        _ = try await store.appendBatch([secondSample], epoch: secondEpoch.epoch, operationID: captureHistoryUUID(11), now: now)

        let page = try await store.readPage(
            interval: CapturePageInterval(start: firstSample.observedAt, end: now),
            now: now,
            limit: 10,
            cursor: nil
        )

        #expect(RouteStoreFiles.exactSamplesEquality(page.items.map(\.sample), [firstSample, secondSample]))
        #expect(page.items.map(\.epoch) == [firstEpoch.epoch, secondEpoch.epoch])
        #expect(page.items[0].sample.latitude.bitPattern == Double(-0.0).bitPattern)
        #expect(page.items[0].sample.longitude.bitPattern == Double(-0.0).bitPattern)
        #expect(page.items[0].sample.altitude?.bitPattern == Double(-0.0).bitPattern)
        await store.close()
    }

    @Test func intervalIsHalfOpenAndRetainsTheExactNinetyDayBoundary() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let queryNow = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let admissionNow = queryNow.addingTimeInterval(-100)
        let cutoff = queryNow.addingTimeInterval(-90 * 86_400)
        let recordingID = captureHistoryUUID(30)
        let older = captureHistorySample(at: cutoff.timeIntervalSinceReferenceDate - 1, id: captureHistoryUUID(31), recordingID: recordingID)
        let boundary = captureHistorySample(at: cutoff.timeIntervalSinceReferenceDate, id: captureHistoryUUID(32), recordingID: recordingID)
        let intervalStart = captureHistorySample(at: queryNow.timeIntervalSinceReferenceDate - 100, id: captureHistoryUUID(33), recordingID: recordingID)
        let inside = captureHistorySample(at: queryNow.timeIntervalSinceReferenceDate - 75, id: captureHistoryUUID(34), recordingID: recordingID)
        let intervalEnd = captureHistorySample(at: queryNow.timeIntervalSinceReferenceDate - 50, id: captureHistoryUUID(35), recordingID: recordingID)
        let samples = [older, boundary, intervalStart, inside, intervalEnd]
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(36))
        _ = try await store.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(37), now: admissionNow)

        let interval = CapturePageInterval(start: older.observedAt, end: intervalEnd.observedAt)
        let boundaryPage = try await store.readPage(interval: interval, now: queryNow, limit: 10, cursor: nil)
        let advancedPage = try await store.readPage(
            interval: interval,
            now: queryNow.addingTimeInterval(0.5),
            limit: 10,
            cursor: nil
        )

        #expect(RouteStoreFiles.exactSamplesEquality(boundaryPage.items.map(\.sample), [boundary, intervalStart, inside]))
        #expect(RouteStoreFiles.exactSamplesEquality(advancedPage.items.map(\.sample), [intervalStart, inside]))
        await store.close()
    }

    @Test func appendsAfterTheFirstPageStayOutsideItsCursorHighWater() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(40)
        let samples = (0..<3).map { index in
            captureHistorySample(at: 1_999_999_000 + Double(index), id: captureHistoryUUID(41 + index), recordingID: recordingID)
        }
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(44))
        _ = try await store.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(45), now: now)

        let interval = CapturePageInterval(start: samples[0].observedAt, end: now)
        let firstPage = try await store.readPage(interval: interval, now: now, limit: 1, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)
        let appended = captureHistorySample(at: 1_999_999_003, id: captureHistoryUUID(46), recordingID: recordingID)
        _ = try await store.appendBatch([appended], epoch: begin.epoch, operationID: captureHistoryUUID(47), now: now)

        let continuation = try await store.readPage(interval: interval, now: now, limit: 10, cursor: cursor)
        let freshQuery = try await store.readPage(interval: interval, now: now, limit: 10, cursor: nil)

        #expect(continuation.items.map(\.sample.id) == samples.dropFirst().map(\.id))
        #expect(freshQuery.items.map(\.sample.id) == samples.map(\.id) + [appended.id])
        await store.close()
    }

    @Test func cursorsRejectChangedQueriesForeignStoresReopensAndMalformedState() async throws {
        let firstFixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(firstFixture.container) }
        let secondFixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(secondFixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(50)
        let samples = [
            captureHistorySample(at: 1_999_999_000, id: captureHistoryUUID(51), recordingID: recordingID),
            captureHistorySample(at: 1_999_999_001, id: captureHistoryUUID(52), recordingID: recordingID)
        ]
        let firstStore = try CaptureHistoryStoreFactory.create(at: firstFixture.store)
        let begin = try await firstStore.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(53))
        _ = try await firstStore.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(54), now: now)
        let interval = CapturePageInterval(start: samples[0].observedAt, end: now)
        let firstPage = try await firstStore.readPage(interval: interval, now: now, limit: 1, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)

        await expectCaptureHistoryError(.invalidCursor) {
            _ = try await firstStore.readPage(
                interval: CapturePageInterval(start: interval.start.addingTimeInterval(1), end: interval.end),
                now: now,
                limit: 1,
                cursor: cursor
            )
        }
        await expectCaptureHistoryError(.invalidCursor) {
            _ = try await firstStore.readPage(interval: interval, now: now.addingTimeInterval(1), limit: 1, cursor: cursor)
        }
        let malformed = CapturePageCursor(
            storeOpenID: cursor.storeOpenID,
            interval: cursor.interval,
            queryNow: cursor.queryNow,
            highWaterSequence: cursor.highWaterSequence,
            deletionRevision: cursor.deletionRevision,
            lastObservedAt: cursor.lastObservedAt,
            lastSequence: cursor.highWaterSequence + 1
        )
        await expectCaptureHistoryError(.invalidCursor) {
            _ = try await firstStore.readPage(interval: interval, now: now, limit: 1, cursor: malformed)
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await firstStore.readPage(
                interval: CapturePageInterval(start: interval.end, end: interval.start),
                now: now,
                limit: 1,
                cursor: nil
            )
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await firstStore.readPage(interval: interval, now: now, limit: 0, cursor: nil)
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await firstStore.readPage(interval: interval, now: now, limit: CapturePersistenceLimits.maximumPageRows + 1, cursor: nil)
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await firstStore.readPage(
                interval: CapturePageInterval(start: Date(timeIntervalSinceReferenceDate: .infinity), end: interval.end),
                now: now,
                limit: 1,
                cursor: nil
            )
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await firstStore.readPage(
                interval: interval,
                now: Date(timeIntervalSinceReferenceDate: .infinity),
                limit: 1,
                cursor: nil
            )
        }

        let otherStore = try CaptureHistoryStoreFactory.create(at: secondFixture.store)
        await expectCaptureHistoryError(.invalidCursor) {
            _ = try await otherStore.readPage(interval: interval, now: now, limit: 1, cursor: cursor)
        }
        await otherStore.close()
        await firstStore.close()

        let reopened = try CaptureHistoryStoreFactory.open(at: firstFixture.store)
        await expectCaptureHistoryError(.invalidCursor) {
            _ = try await reopened.readPage(interval: interval, now: now, limit: 1, cursor: cursor)
        }
        await reopened.close()
    }

    @Test func pageByteBudgetContinuesBeforeTheNextRecordWouldOverflow() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(60)
        let samples = (0..<3).map { index in
            captureHistorySample(at: 1_999_999_000 + Double(index), id: captureHistoryUUID(61 + index), recordingID: recordingID)
        }
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(64))
        _ = try await store.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(65), now: now)
        await store.close()

        let payloadBytes = 96 * 1_024
        for sample in samples {
            var payload = try JSONEncoder().encode(sample)
            try #require(payload.count < payloadBytes)
            payload.append(Data(repeating: 0x20, count: payloadBytes - payload.count))
            try captureHistoryRewritePayload(payload, sampleID: sample.id, at: fixture.store)
        }

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let interval = CapturePageInterval(start: samples[0].observedAt, end: now)
        let firstPage = try await reopened.readPage(interval: interval, now: now, limit: CapturePersistenceLimits.maximumPageRows, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)
        let secondPage = try await reopened.readPage(
            interval: interval,
            now: now,
            limit: CapturePersistenceLimits.maximumPageRows,
            cursor: cursor
        )

        #expect(firstPage.items.map(\.sample.id) == samples.prefix(2).map(\.id))
        #expect(firstPage.encodedPayloadBytes == payloadBytes * 2)
        #expect(secondPage.items.map(\.sample.id) == [samples[2].id])
        #expect(secondPage.encodedPayloadBytes == payloadBytes)
        #expect(secondPage.nextCursor == nil)
        await reopened.close()
    }

    @Test func pageRejectsAnOversizedPayloadBeforeAttemptingToDecodeIt() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(70)
        let sample = captureHistorySample(at: 1_999_999_000, id: captureHistoryUUID(71), recordingID: recordingID)
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(72))
        _ = try await store.appendBatch([sample], epoch: begin.epoch, operationID: captureHistoryUUID(73), now: now)
        await store.close()
        try captureHistoryRewritePayload(
            Data(repeating: 0x78, count: CapturePersistenceLimits.maximumPagePayloadBytes + 1),
            sampleID: sample.id,
            at: fixture.store
        )

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        await expectCaptureHistoryError(.oversizedRecord(sample.id)) {
            _ = try await reopened.readPage(
                interval: CapturePageInterval(start: sample.observedAt, end: now),
                now: now,
                limit: 1,
                cursor: nil
            )
        }
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == 1)
    }

    @Test func clearFencesRecordingAndSeparatesVisibilityFromBoundedPhysicalPruning() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(80)
        let samples = (0..<3).map { index in
            captureHistorySample(at: 1_999_999_000 + Double(index), id: captureHistoryUUID(81 + index), recordingID: recordingID)
        }
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(84))
        _ = try await store.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(85), now: now)
        let interval = CapturePageInterval(start: samples[0].observedAt, end: now)
        let preClearPage = try await store.readPage(interval: interval, now: now, limit: 1, cursor: nil)
        let preClearCursor = try #require(preClearPage.nextCursor)
        await expectCaptureHistoryError(.recordingActive) {
            _ = try await store.clearHistory(expectedControlRevision: begin.controlRevision, operationID: captureHistoryUUID(86))
        }

        let stopped = try await store.stopRecording(
            epoch: begin.epoch,
            expectedControlRevision: begin.controlRevision,
            operationID: captureHistoryUUID(87)
        )
        await expectCaptureHistoryError(.staleControlRevision) {
            _ = try await store.clearHistory(expectedControlRevision: begin.controlRevision, operationID: captureHistoryUUID(88))
        }
        let beforeClear = try await store.readControl()
        let clearID = captureHistoryUUID(89)
        let clearReceipt = try await store.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID)
        let afterClear = try await store.readControl()

        #expect(try await store.readPage(interval: interval, now: now, limit: 10, cursor: nil).items.isEmpty)
        await expectCaptureHistoryError(.cursorInvalidated) {
            _ = try await store.readPage(interval: interval, now: now, limit: 1, cursor: preClearCursor)
        }
        #expect(afterClear.revision == stopped.controlRevision)
        #expect(afterClear.activeEpoch == nil)
        #expect(afterClear.lastControlReceipt == stopped)
        #expect(afterClear.lastClearReceipt == clearReceipt)
        #expect(afterClear.deletionRevision == beforeClear.deletionRevision + 1)
        #expect(afterClear.clearedThroughSequence == clearReceipt.clearedThroughSequence)
        #expect(try await store.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID) == clearReceipt)
        await expectCaptureHistoryError(.operationConflict) {
            _ = try await store.clearHistory(expectedControlRevision: stopped.controlRevision + 1, operationID: clearID)
        }
        await store.close()

        let beforePrune = try captureHistoryPhysicalState(at: fixture.store)
        #expect(beforePrune.rowCount == samples.count)
        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let reopenedControl = try await reopened.readControl()
        #expect(reopenedControl.lastClearReceipt == clearReceipt)
        #expect(reopenedControl.lastControlReceipt == stopped)
        #expect(try await reopened.readPage(interval: interval, now: now, limit: 10, cursor: nil).items.isEmpty)

        let pruneID = captureHistoryUUID(90)
        let pruneReceipt = try await reopened.pruneHistory(now: now, limit: 1, operationID: pruneID)
        #expect(pruneReceipt.deletedRows == 1)
        #expect(pruneReceipt.hasMore)
        #expect(try await reopened.pruneHistory(now: now, limit: 1, operationID: pruneID) == pruneReceipt)
        await reopened.close()

        let afterPrune = try captureHistoryPhysicalState(at: fixture.store)
        #expect(afterPrune.rowCount == samples.count - 1)
        #expect(beforePrune.payloadBytes - afterPrune.payloadBytes == Int64(pruneReceipt.deletedPayloadBytes))
    }

    @Test func clearPostCommitUncertaintyIsResolvedByReopeningAndLookingUpItsReceipt() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recordingID = captureHistoryUUID(100)
        let sample = captureHistorySample(at: 1_999_999_000, id: captureHistoryUUID(101), recordingID: recordingID)
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(recordingID: recordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(102))
        _ = try await store.appendBatch([sample], epoch: begin.epoch, operationID: captureHistoryUUID(103), now: now)
        let stopped = try await store.stopRecording(
            epoch: begin.epoch,
            expectedControlRevision: begin.controlRevision,
            operationID: captureHistoryUUID(104)
        )
        await store.close()

        let clearID = captureHistoryUUID(105)
        let uncertain = try CaptureHistoryStoreFactory.open(
            at: fixture.store,
            seams: captureHistoryFaultSeams(at: .afterTransactionCommit)
        )
        await expectCaptureHistoryError(.outcomeUncertain(clearID)) {
            _ = try await uncertain.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID)
        }
        await uncertain.close()

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let lookup = try await reopened.lookupReceipt(operationID: clearID)
        guard case let .found(.clear(receipt)) = lookup else {
            Issue.record("Committed clear receipt was not found after reopening")
            await reopened.close()
            return
        }
        #expect(try await reopened.readPage(
            interval: CapturePageInterval(start: sample.observedAt, end: now),
            now: now,
            limit: 10,
            cursor: nil
        ).items.isEmpty)
        #expect(try await reopened.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID) == receipt)
        #expect(try await reopened.readControl().lastClearReceipt == receipt)
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == 1)
    }

    @Test func liveDuplicatesStayUntouchedAndClearedIdentifiersCanBeReusedAcrossReopen() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let oldRecordingID = captureHistoryUUID(110)
        let reusedID = captureHistoryUUID(111)
        let oldSample = captureHistorySample(at: 1_999_999_000, id: reusedID, recordingID: oldRecordingID)
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let oldBegin = try await store.beginRecording(recordingID: oldRecordingID, expectedControlRevision: 0, operationID: captureHistoryUUID(112))
        let firstReceipt = try await store.appendBatch([oldSample], epoch: oldBegin.epoch, operationID: captureHistoryUUID(113), now: now)
        let duplicateReceipt = try await store.appendBatch([oldSample], epoch: oldBegin.epoch, operationID: captureHistoryUUID(114), now: now)
        #expect(firstReceipt.items.first?.disposition == .stored)
        #expect(duplicateReceipt.items.first?.disposition == .duplicate)
        let stopped = try await store.stopRecording(
            epoch: oldBegin.epoch,
            expectedControlRevision: oldBegin.controlRevision,
            operationID: captureHistoryUUID(115)
        )
        let clearID = captureHistoryUUID(116)
        let clearReceipt = try await store.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID)
        let afterClear = try await store.readControl()
        let newRecordingID = captureHistoryUUID(117)
        #expect(try await store.reconcileSamples([oldSample], epoch: oldBegin.epoch).first?.match == .absentOrExpired)
        let newBegin = try await store.beginRecording(
            recordingID: newRecordingID,
            expectedControlRevision: afterClear.revision,
            operationID: captureHistoryUUID(118)
        )
        let afterBegin = try await store.readControl()
        #expect(afterBegin.deletionRevision == afterClear.deletionRevision)
        #expect(afterBegin.clearedThroughSequence == afterClear.clearedThroughSequence)
        #expect(afterBegin.lastClearReceipt == clearReceipt)

        let replacement = captureHistorySample(
            at: oldSample.observedAt.timeIntervalSinceReferenceDate + 20,
            id: reusedID,
            recordingID: newRecordingID,
            latitude: 13.125
        )
        let replacementReceipt = try await store.appendBatch([replacement], epoch: newBegin.epoch, operationID: captureHistoryUUID(119), now: now)
        #expect(replacementReceipt.items.first?.disposition == .stored)
        let afterReplacement = try await store.readControl()
        #expect(afterReplacement.deletionRevision == afterBegin.deletionRevision + 1)
        #expect(afterReplacement.clearedThroughSequence == clearReceipt.clearedThroughSequence)
        #expect(afterReplacement.lastClearReceipt == clearReceipt)
        #expect(try await store.clearHistory(expectedControlRevision: stopped.controlRevision, operationID: clearID) == clearReceipt)
        #expect(try await store.readControl() == afterReplacement)

        let interval = CapturePageInterval(start: oldSample.observedAt, end: now)
        let page = try await store.readPage(interval: interval, now: now, limit: 10, cursor: nil)
        #expect(RouteStoreFiles.exactSamplesEquality(page.items.map(\.sample), [replacement]))
        #expect(page.items.first?.epoch == newBegin.epoch)
        #expect(try await store.reconcileSamples([oldSample], epoch: oldBegin.epoch).first?.match == .conflicting)
        #expect(try await store.reconcileSamples([replacement], epoch: newBegin.epoch).first?.match == .matching)

        let stoppedAgain = try await store.stopRecording(
            epoch: newBegin.epoch,
            expectedControlRevision: afterReplacement.revision,
            operationID: captureHistoryUUID(120)
        )
        let afterStop = try await store.readControl()
        #expect(afterStop.lastControlReceipt == stoppedAgain)
        #expect(afterStop.lastClearReceipt == clearReceipt)
        #expect(afterStop.deletionRevision == afterReplacement.deletionRevision)
        #expect(afterStop.clearedThroughSequence == clearReceipt.clearedThroughSequence)
        await store.close()

        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == 1)
        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        #expect(try await reopened.readControl() == afterStop)
        #expect(RouteStoreFiles.exactSamplesEquality(
            try await reopened.readPage(interval: interval, now: now, limit: 10, cursor: nil).items.map(\.sample),
            [replacement]
        ))
        await reopened.close()
    }

    @Test func pruneIsBoundedReplaySafeAndInvalidatesCursorsOnlyAfterDeletion() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let seeded = try await captureHistoryPopulatePrunable(at: fixture.store, idBase: 130)
        let store = seeded.store
        let interval = CapturePageInterval(
            start: seeded.cutoff.addingTimeInterval(-2),
            end: seeded.cutoff.addingTimeInterval(2)
        )
        let firstPage = try await store.readPage(interval: interval, now: seeded.now, limit: 1, cursor: nil)
        let cursor = try #require(firstPage.nextCursor)
        let before = try await store.readControl()
        let firstID = captureHistoryUUID(140)
        let first = try await store.pruneHistory(now: seeded.now, limit: 1, operationID: firstID)
        let afterFirst = try await store.readControl()
        let firstReplay = try await store.pruneHistory(now: seeded.now, limit: 1, operationID: firstID)

        #expect(first.deletedRows == 1)
        #expect(first.deletedPayloadBytes > 0)
        #expect(first.hasMore)
        #expect(firstReplay == first)
        #expect(afterFirst.deletionRevision == before.deletionRevision + 1)
        #expect(afterFirst.hasSameRecordingIntent(as: before))
        await expectCaptureHistoryError(.cursorInvalidated) {
            _ = try await store.readPage(interval: interval, now: seeded.now, limit: 1, cursor: cursor)
        }

        let second = try await store.pruneHistory(now: seeded.now, limit: 1, operationID: captureHistoryUUID(141))
        let afterSecond = try await store.readControl()
        let pageBeforeNoOp = try await store.readPage(interval: interval, now: seeded.now, limit: 1, cursor: nil)
        let cursorBeforeNoOp = try #require(pageBeforeNoOp.nextCursor)
        let noOp = try await store.pruneHistory(now: seeded.now, limit: 1, operationID: captureHistoryUUID(142))
        let afterNoOp = try await store.readControl()
        let visible = try await store.readPage(interval: interval, now: seeded.now, limit: 10, cursor: nil)
        let continuationAfterNoOp = try await store.readPage(interval: interval, now: seeded.now, limit: 1, cursor: cursorBeforeNoOp)

        #expect(second.deletedRows == 1)
        #expect(!second.hasMore)
        #expect(afterSecond.deletionRevision == first.deletionRevision + 1)
        #expect(noOp.deletedRows == 0)
        #expect(!noOp.hasMore)
        #expect(afterNoOp.deletionRevision == afterSecond.deletionRevision)
        #expect(afterNoOp.hasSameRecordingIntent(as: before))
        #expect(RouteStoreFiles.exactSamplesEquality(visible.items.map(\.sample), Array(seeded.samples.suffix(2))))
        #expect(continuationAfterNoOp.items.map(\.sample.id) == [seeded.samples[3].id])
        await store.close()

        let physical = try captureHistoryPhysicalState(at: fixture.store)
        #expect(physical.rowCount == 2)
    }

    @Test func pruneStopsAtTheEncodedPayloadByteBudget() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let cutoff = Date(timeIntervalSinceReferenceDate: 1_900_000_000)
        let appendNow = cutoff.addingTimeInterval(10)
        let now = cutoff.addingTimeInterval(90 * 86_400)
        let recordingID = captureHistoryUUID(210)
        let samples = [-3.0, -2.0, -1.0, 0.0].enumerated().map { item in
            captureHistorySample(
                at: cutoff.timeIntervalSinceReferenceDate + item.element,
                id: captureHistoryUUID(211 + item.offset),
                recordingID: recordingID
            )
        }
        let store = try CaptureHistoryStoreFactory.create(at: fixture.store)
        let begin = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: captureHistoryUUID(215)
        )
        _ = try await store.appendBatch(samples, epoch: begin.epoch, operationID: captureHistoryUUID(216), now: appendNow)
        await store.close()

        let payloadBytes = 96 * 1_024
        for sample in samples {
            var payload = try JSONEncoder().encode(sample)
            try #require(payload.count < payloadBytes)
            payload.append(Data(repeating: 0x20, count: payloadBytes - payload.count))
            try captureHistoryRewritePayload(payload, sampleID: sample.id, at: fixture.store)
        }

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let first = try await reopened.pruneHistory(now: now, limit: 10, operationID: captureHistoryUUID(217))
        #expect(first.deletedRows == 2)
        #expect(first.deletedPayloadBytes == payloadBytes * 2)
        #expect(first.deletedPayloadBytes <= CapturePersistenceLimits.maximumPrunePayloadBytes)
        #expect(first.hasMore)

        let second = try await reopened.pruneHistory(now: now, limit: 10, operationID: captureHistoryUUID(218))
        #expect(second.deletedRows == 1)
        #expect(second.deletedPayloadBytes == payloadBytes)
        #expect(!second.hasMore)
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == 1)
    }

    @Test func pruneCapacityFailureLeavesHistoryAndReceiptLedgerUnchanged() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let seeded = try await captureHistoryPopulatePrunable(at: fixture.store, idBase: 150)
        await seeded.store.close()
        let denyRetentionCapacity = captureHistoryStorageSeams(requireCapacity: { url, bytes, check in
            if check == .retention {
                throw RouteStoreError.insufficientSpace
            }
            try RouteStoreFiles.requireCapacity(at: url, requiredBytes: bytes)
        })
        let constrained = try CaptureHistoryStoreFactory.open(at: fixture.store, seams: denyRetentionCapacity)
        let pruneID = captureHistoryUUID(160)
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await constrained.pruneHistory(now: seeded.now, limit: 0, operationID: captureHistoryUUID(161))
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await constrained.pruneHistory(
                now: seeded.now,
                limit: CapturePersistenceLimits.maximumPruneRows + 1,
                operationID: captureHistoryUUID(162)
            )
        }
        await expectCaptureHistoryError(.invalidHistoryRequest) {
            _ = try await constrained.pruneHistory(
                now: Date(timeIntervalSinceReferenceDate: .infinity),
                limit: 1,
                operationID: captureHistoryUUID(163)
            )
        }
        await expectCaptureHistoryError(.notCommitted(.insufficientSpace)) {
            _ = try await constrained.pruneHistory(now: seeded.now, limit: 1, operationID: pruneID)
        }
        await constrained.close()

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let control = try await reopened.readControl()
        #expect(control.deletionRevision == 0)
        #expect(control.clearedThroughSequence == 0)
        #expect(try await reopened.lookupReceipt(operationID: pruneID) == .unavailable)
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == seeded.samples.count)
    }

    @Test func prunePreCommitFailureRollsBackRowsMetadataAndReceipt() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let seeded = try await captureHistoryPopulatePrunable(at: fixture.store, idBase: 170)
        await seeded.store.close()
        let failing = try CaptureHistoryStoreFactory.open(
            at: fixture.store,
            seams: captureHistoryFaultSeams(at: .beforeTransactionCommit)
        )
        let pruneID = captureHistoryUUID(180)
        await expectCaptureHistoryError(.notCommitted(.injectedFault(.beforeTransactionCommit))) {
            _ = try await failing.pruneHistory(now: seeded.now, limit: 1, operationID: pruneID)
        }
        await failing.close()

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        #expect(try await reopened.readControl().deletionRevision == 0)
        #expect(try await reopened.lookupReceipt(operationID: pruneID) == .unavailable)
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == seeded.samples.count)
    }

    @Test func prunePostCommitUncertaintyRequiresReceiptReconciliationBeforeReplay() async throws {
        let fixture = try captureHistoryFixture()
        defer { captureHistoryRemoveFixture(fixture.container) }
        let seeded = try await captureHistoryPopulatePrunable(at: fixture.store, idBase: 190)
        await seeded.store.close()
        let pruneID = captureHistoryUUID(200)
        let uncertain = try CaptureHistoryStoreFactory.open(
            at: fixture.store,
            seams: captureHistoryFaultSeams(at: .afterTransactionCommit)
        )
        await expectCaptureHistoryError(.outcomeUncertain(pruneID)) {
            _ = try await uncertain.pruneHistory(now: seeded.now, limit: 1, operationID: pruneID)
        }
        await uncertain.close()

        let reopened = try CaptureHistoryStoreFactory.open(at: fixture.store)
        let lookup = try await reopened.lookupReceipt(operationID: pruneID)
        guard case let .found(.prune(receipt)) = lookup else {
            Issue.record("Committed prune receipt was not found after reopening")
            await reopened.close()
            return
        }
        let replay = try await reopened.pruneHistory(now: seeded.now, limit: 1, operationID: pruneID)
        let control = try await reopened.readControl()
        #expect(receipt.deletedRows == 1)
        #expect(receipt.hasMore)
        #expect(replay == receipt)
        #expect(control.deletionRevision == receipt.deletionRevision)
        await reopened.close()
        #expect(try captureHistoryPhysicalState(at: fixture.store).rowCount == seeded.samples.count - 1)
    }
}

private struct CaptureHistorySeededPrune {
    let store: RouteStore
    let samples: [RouteSample]
    let cutoff: Date
    let now: Date
}

private struct CaptureHistoryPhysicalState: Equatable {
    let rowCount: Int
    let payloadBytes: Int64
}

private enum CaptureHistoryStoreFactory {
    static func create(at url: URL, seams: RouteStoreSeams = captureHistoryStorageSeams()) throws -> RouteStore {
        try RouteStore.createFoundation(at: url, seams: seams)
    }

    static func open(at url: URL, seams: RouteStoreSeams = captureHistoryStorageSeams()) throws -> RouteStore {
        try RouteStore.openFoundation(at: url, seams: seams)
    }
}

private func captureHistoryProtect(_ url: URL, as item: RouteStoreProtectedItem) throws {
    #if targetEnvironment(simulator)
    try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
        .completeUntilFirstUserAuthentication
    })
    #else
    try RouteStoreFiles.protectAndVerify(url, as: item)
    #endif
}

private func captureHistoryStorageSeams(
    protectAndVerify: @escaping @Sendable (URL, RouteStoreProtectedItem) throws -> Void = {
        try captureHistoryProtect($0, as: $1)
    },
    requireCapacity: @escaping @Sendable (URL, Int64, RouteStoreCapacityCheck) throws -> Void = { url, bytes, _ in
        try RouteStoreFiles.requireCapacity(at: url, requiredBytes: bytes)
    },
    fault: @escaping @Sendable (RouteStoreFaultPoint) throws -> Void = { _ in },
    readProtection: @escaping @Sendable (URL) throws -> FileProtectionType? = {
        try captureHistoryReadProtection($0)
    }
) -> RouteStoreSeams {
    RouteStoreSeams(
        protectAndVerify: protectAndVerify,
        requireCapacity: requireCapacity,
        fault: fault,
        readProtection: readProtection
    )
}

private func captureHistoryReadProtection(_ url: URL) throws -> FileProtectionType? {
    #if targetEnvironment(simulator)
    return .completeUntilFirstUserAuthentication
    #else
    return try RouteStoreFiles.readProtection(at: url)
    #endif
}

private func captureHistoryFaultSeams(at point: RouteStoreFaultPoint) -> RouteStoreSeams {
    captureHistoryStorageSeams(fault: { actual in
        if actual == point {
            throw RouteStoreError.injectedFault(actual)
        }
    })
}

private func captureHistoryPopulatePrunable(at storeURL: URL, idBase: Int) async throws -> CaptureHistorySeededPrune {
    let cutoff = Date(timeIntervalSinceReferenceDate: 1_900_000_000)
    let appendNow = cutoff.addingTimeInterval(10)
    let now = cutoff.addingTimeInterval(90 * 86_400)
    let recordingID = captureHistoryUUID(idBase)
    let samples = [-2.0, -1.0, 0.0, 1.0].enumerated().map { item in
        captureHistorySample(
            at: cutoff.timeIntervalSinceReferenceDate + item.element,
            id: captureHistoryUUID(idBase + item.offset + 1),
            recordingID: recordingID
        )
    }
    let store = try CaptureHistoryStoreFactory.create(at: storeURL)
    let begin = try await store.beginRecording(
        recordingID: recordingID,
        expectedControlRevision: 0,
        operationID: captureHistoryUUID(idBase + 10_000)
    )
    _ = try await store.appendBatch(
        samples,
        epoch: begin.epoch,
        operationID: captureHistoryUUID(idBase + 10_001),
        now: appendNow
    )
    return CaptureHistorySeededPrune(store: store, samples: samples, cutoff: cutoff, now: now)
}

private func captureHistoryFixture() throws -> (container: URL, store: URL) {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw RouteStoreError.unsafePath
    }
    defer { Darwin.free(resolved) }
    let container = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("CaptureHistory-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: container,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return (container, container.appendingPathComponent("store", isDirectory: true))
}

private func captureHistoryRemoveFixture(_ container: URL) {
    try? FileManager.default.removeItem(at: container)
}

private func captureHistoryUUID(_ value: Int) -> UUID {
    let high = UInt8(truncatingIfNeeded: value >> 8)
    let low = UInt8(truncatingIfNeeded: value)
    return UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, high, low))
}

private func captureHistorySample(
    at referenceSeconds: TimeInterval,
    id: UUID,
    recordingID: UUID,
    latitude: Double = 12.3456,
    longitude: Double = -45.6789,
    includeOptionalMeasurements: Bool = false
) -> RouteSample {
    RouteSample(
        id: id,
        recordingID: recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: referenceSeconds),
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracy: 7.5,
        altitude: includeOptionalMeasurements ? -0.0 : nil,
        verticalAccuracy: includeOptionalMeasurements ? 2.75 : nil,
        speed: includeOptionalMeasurements ? 1.125 : nil,
        speedAccuracy: includeOptionalMeasurements ? 0.5 : nil,
        course: includeOptionalMeasurements ? 270.25 : nil,
        courseAccuracy: includeOptionalMeasurements ? 1.75 : nil,
        isStationary: includeOptionalMeasurements
    )
}

private func captureHistoryPhysicalState(at storeURL: URL) throws -> CaptureHistoryPhysicalState {
    let databaseURL = storeURL.appendingPathComponent(RouteStoreFiles.databaseName)
    var database: OpaquePointer?
    let opened = databaseURL.path.withCString {
        sqlite3_open_v2($0, &database, SQLITE_OPEN_READONLY, nil)
    }
    guard opened == SQLITE_OK, let database else {
        if let database {
            _ = sqlite3_close_v2(database)
        }
        throw RouteStoreError.corruptDatabase
    }
    defer { _ = sqlite3_close_v2(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(
        database,
        "SELECT COUNT(*), COALESCE(SUM(length(payload)), 0) FROM route_samples",
        -1,
        &statement,
        nil
    ) == SQLITE_OK, let statement else {
        throw RouteStoreError.corruptDatabase
    }
    defer { sqlite3_finalize(statement) }
    guard sqlite3_step(statement) == SQLITE_ROW else {
        throw RouteStoreError.corruptDatabase
    }
    let state = CaptureHistoryPhysicalState(
        rowCount: Int(sqlite3_column_int64(statement, 0)),
        payloadBytes: sqlite3_column_int64(statement, 1)
    )
    guard sqlite3_step(statement) == SQLITE_DONE else {
        throw RouteStoreError.corruptDatabase
    }
    return state
}

private func captureHistoryRewritePayload(_ payload: Data, sampleID: UUID, at storeURL: URL) throws {
    let databaseURL = storeURL.appendingPathComponent(RouteStoreFiles.databaseName)
    var database: OpaquePointer?
    let opened = databaseURL.path.withCString {
        sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil)
    }
    guard opened == SQLITE_OK, let database else {
        if let database {
            _ = sqlite3_close_v2(database)
        }
        throw RouteStoreError.corruptDatabase
    }
    defer { _ = sqlite3_close_v2(database) }

    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(database, "UPDATE route_samples SET payload = ? WHERE sample_id = ?", -1, &statement, nil) == SQLITE_OK,
          let statement else {
        throw RouteStoreError.corruptDatabase
    }

    let status = payload.withUnsafeBytes { bytes in
        sampleID.uuidString.withCString { identifier in
            defer { sqlite3_finalize(statement) }
            guard sqlite3_bind_blob(statement, 1, bytes.baseAddress, Int32(bytes.count), nil) == SQLITE_OK,
                  sqlite3_bind_text(statement, 2, identifier, -1, nil) == SQLITE_OK else {
                return SQLITE_ERROR
            }
            return sqlite3_step(statement)
        }
    }
    guard status == SQLITE_DONE, sqlite3_changes(database) == 1 else {
        throw RouteStoreError.corruptDatabase
    }
}

private func expectCaptureHistoryError(
    _ expected: CapturePersistenceError,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected a typed CapturePersistenceError", sourceLocation: sourceLocation)
    } catch let error as CapturePersistenceError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type: \(error)", sourceLocation: sourceLocation)
    }
}
