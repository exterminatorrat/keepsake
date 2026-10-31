import Darwin
import Foundation
import SQLite3
import Testing
@testable import Keepsake

struct CapturePersistenceTests {
    @Test func foundationProfileStartsStoppedAndRejectsUnfencedLegacyEntryPoints() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }

        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        #expect(try await store.readControl() == CaptureControlSnapshot(revision: 0, activeEpoch: nil, lastControlReceipt: nil))
        await expectCaptureErrorAsync(.notFoundationStore) {
            _ = try await store.load()
        }
        await expectCaptureErrorAsync(.notFoundationStore) {
            _ = try await store.append(makeCaptureSample(at: 1_000), now: Date(timeIntervalSinceReferenceDate: 2_000))
        }
        await expectCaptureErrorAsync(.notFoundationStore) {
            try await store.clear()
        }
        await expectCaptureErrorAsync(.notFoundationStore) {
            try await store.exportCompatibleLegacy(to: fixture.container.appendingPathComponent("legacy.jsonl"))
        }
        await store.close()

        expectRouteStoreError(.invalidManifest) {
            _ = try RouteStore.openExisting(at: fixture.store, seams: captureTestSeams())
        }

        let legacyURL = fixture.container.appendingPathComponent("legacy-store", isDirectory: true)
        let legacyStore = try RouteStore.createNew(at: legacyURL, seams: captureTestSeams())
        await expectCaptureErrorAsync(.notFoundationStore) {
            _ = try await legacyStore.readControl()
        }
        await legacyStore.close()
        expectRouteStoreError(.invalidManifest) {
            _ = try RouteStore.openFoundation(at: legacyURL, seams: captureTestSeams())
        }
    }

    @Test func controlsAdvanceEpochsAndSameCommandReplaysWithoutChangingCurrentState() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let recordingID = UUID()
        let beginID = UUID()

        let begin = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: beginID
        )
        #expect(begin.kind == .begin)
        #expect(begin.epoch == CaptureEpoch(recordingID: recordingID, revision: 1))
        #expect(try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: beginID
        ) == begin)
        await expectCaptureErrorAsync(.operationConflict) {
            _ = try await store.beginRecording(
                recordingID: UUID(),
                expectedControlRevision: 0,
                operationID: beginID
            )
        }
        await expectCaptureErrorAsync(.staleControlRevision) {
            _ = try await store.beginRecording(
                recordingID: recordingID,
                expectedControlRevision: 7,
                operationID: UUID()
            )
        }
        await expectCaptureErrorAsync(.activeRecordingMismatch) {
            _ = try await store.beginRecording(
                recordingID: UUID(),
                expectedControlRevision: 1,
                operationID: UUID()
            )
        }

        let resumed = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 1,
            operationID: UUID()
        )
        #expect(resumed.epoch == CaptureEpoch(recordingID: recordingID, revision: 2))
        #expect(resumed.controlRevision == 2)
        await expectCaptureErrorAsync(.staleEpoch) {
            _ = try await store.stopRecording(
                epoch: begin.epoch,
                expectedControlRevision: 2,
                operationID: UUID()
            )
        }
        await expectCaptureErrorAsync(.staleEpoch) {
            _ = try await store.appendBatch([], epoch: begin.epoch, operationID: UUID(), now: Date.now)
        }

        let stopID = UUID()
        let stopped = try await store.stopRecording(
            epoch: resumed.epoch,
            expectedControlRevision: 2,
            operationID: stopID
        )
        #expect(stopped.controlRevision == 3)
        #expect(stopped.kind == .stop)
        #expect(try await store.stopRecording(
            epoch: resumed.epoch,
            expectedControlRevision: 2,
            operationID: stopID
        ) == stopped)
        #expect(try await store.readControl() == CaptureControlSnapshot(
            revision: 3,
            activeEpoch: nil,
            lastControlReceipt: stopped
        ))
        let restarted = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 3,
            operationID: UUID()
        )
        #expect(try await store.stopRecording(
            epoch: resumed.epoch,
            expectedControlRevision: 2,
            operationID: stopID
        ) == stopped)
        #expect(try await store.readControl() == CaptureControlSnapshot(
            revision: 4,
            activeEpoch: restarted.epoch,
            lastControlReceipt: restarted
        ))
        await store.close()
    }

    @Test func batchesPreserveOrderAdmissionAndReconciliationResults() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let now = Date.now
        let recordingID = UUID()
        let epoch = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let first = makeCaptureSample(at: now.timeIntervalSinceReferenceDate - 100, recordingID: recordingID)
        let sameFingerprint = makeCaptureSample(
            at: first.observedAt.timeIntervalSinceReferenceDate,
            recordingID: recordingID
        )
        let outOfOrder = makeCaptureSample(
            at: first.observedAt.timeIntervalSinceReferenceDate - 1,
            recordingID: recordingID
        )
        let future = makeCaptureSample(at: now.timeIntervalSinceReferenceDate + 61, recordingID: recordingID)
        let expired = makeCaptureSample(
            at: now.timeIntervalSinceReferenceDate - 90 * 86_400 - 1,
            recordingID: recordingID
        )
        let wrongRecording = makeCaptureSample(
            at: now.timeIntervalSinceReferenceDate - 50,
            recordingID: UUID()
        )
        let samples = [first, first, sameFingerprint, outOfOrder, future, expired, wrongRecording]
        let operationID = UUID()
        let receipt = try await store.appendBatch(samples, epoch: epoch, operationID: operationID, now: now)
        #expect(receipt.items.map(\.sampleID) == samples.map(\.id))
        #expect(receipt.items.map(\.disposition) == [
            .stored, .duplicate, .duplicate, .outOfOrder, .invalid, .expired, .invalid
        ])
        #expect(try await store.appendBatch(samples, epoch: epoch, operationID: operationID, now: now) == receipt)

        let changed = RouteSample(
            id: first.id,
            recordingID: recordingID,
            observedAt: first.observedAt,
            latitude: first.latitude + 0.001,
            longitude: first.longitude,
            horizontalAccuracy: first.horizontalAccuracy,
            altitude: first.altitude,
            verticalAccuracy: first.verticalAccuracy,
            speed: first.speed,
            speedAccuracy: first.speedAccuracy,
            course: first.course,
            courseAccuracy: first.courseAccuracy,
            isStationary: first.isStationary
        )
        await expectCaptureErrorAsync(.operationConflict) {
            _ = try await store.appendBatch([changed], epoch: epoch, operationID: operationID, now: now)
        }
        let missing = makeCaptureSample(at: now.timeIntervalSinceReferenceDate - 25, recordingID: recordingID)
        #expect(try await store.reconcileSamples([first, changed, missing], epoch: epoch).map(\.match) == [
            .matching, .conflicting, .absentOrExpired
        ])
        await store.close()
        let reopened = try RouteStore.openFoundation(at: fixture.store, seams: captureTestSeams())
        #expect(try await reopened.lookupReceipt(operationID: operationID) == .found(.batch(receipt)))
        #expect(try await reopened.appendBatch(samples, epoch: epoch, operationID: operationID, now: now) == receipt)
        await reopened.close()

        let boundaryURL = fixture.container.appendingPathComponent("retention-boundary", isDirectory: true)
        let boundaryStore = try RouteStore.createFoundation(at: boundaryURL, seams: captureTestSeams())
        let boundaryRecordingID = UUID()
        let boundaryEpoch = try await boundaryStore.beginRecording(
            recordingID: boundaryRecordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let boundarySample = makeCaptureSample(
            at: now.timeIntervalSinceReferenceDate - 90 * 86_400,
            recordingID: boundaryRecordingID
        )
        let boundaryReceipt = try await boundaryStore.appendBatch(
            [boundarySample],
            epoch: boundaryEpoch,
            operationID: UUID(),
            now: now
        )
        #expect(boundaryReceipt.items.map(\.disposition) == [.stored])
        let laterNow = now.addingTimeInterval(90 * 86_400 + 1)
        let replacement = makeCaptureSample(
            at: laterNow.timeIntervalSinceReferenceDate - 60,
            id: boundarySample.id,
            recordingID: boundaryRecordingID
        )
        let replacementReceipt = try await boundaryStore.appendBatch(
            [replacement],
            epoch: boundaryEpoch,
            operationID: UUID(),
            now: laterNow
        )
        #expect(replacementReceipt.items.map(\.disposition) == [.stored])
        #expect(try await boundaryStore.reconcileSamples([boundarySample, replacement], epoch: boundaryEpoch).map(\.match) == [
            .absentOrExpired, .matching
        ])
        await boundaryStore.close()
    }

    @Test func batchLimitAndUncertainCommitOutcomesRemainTyped() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let recordingID = UUID()
        let epoch = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let oversized = (0...CapturePersistenceLimits.maximumBatchSamples).map {
            makeCaptureSample(at: Double($0), recordingID: recordingID)
        }
        await expectCaptureErrorAsync(.batchTooLarge) {
            _ = try await store.appendBatch(oversized, epoch: epoch, operationID: UUID(), now: Date.now)
        }
        await store.close()

        let preCommitFixture = try makeCaptureFixture()
        defer { removeCaptureFixture(preCommitFixture.container) }
        let preCommitStore = try RouteStore.createFoundation(
            at: preCommitFixture.store,
            seams: captureTestSeams(fault: { point in
                if point == .beforeTransactionCommit {
                    throw RouteStoreError.injectedFault(point)
                }
            })
        )
        let preCommitOperationID = UUID()
        await expectCaptureErrorAsync(.notCommitted(.injectedFault(.beforeTransactionCommit))) {
            _ = try await preCommitStore.beginRecording(
                recordingID: UUID(),
                expectedControlRevision: 0,
                operationID: preCommitOperationID
            )
        }
        await preCommitStore.close()
        let rolledBack = try RouteStore.openFoundation(at: preCommitFixture.store, seams: captureTestSeams())
        #expect(try await rolledBack.readControl().revision == 0)
        #expect(try await rolledBack.lookupReceipt(operationID: preCommitOperationID) == .unavailable)
        await rolledBack.close()

        let postCommitFixture = try makeCaptureFixture()
        defer { removeCaptureFixture(postCommitFixture.container) }
        let postCommitStore = try RouteStore.createFoundation(
            at: postCommitFixture.store,
            seams: captureTestSeams(fault: { point in
                if point == .afterTransactionCommit {
                    throw RouteStoreError.injectedFault(point)
                }
            })
        )
        let postCommitOperationID = UUID()
        await expectCaptureErrorAsync(.outcomeUncertain(postCommitOperationID)) {
            _ = try await postCommitStore.beginRecording(
                recordingID: UUID(),
                expectedControlRevision: 0,
                operationID: postCommitOperationID
            )
        }
        await postCommitStore.close()
        let reconciled = try RouteStore.openFoundation(at: postCommitFixture.store, seams: captureTestSeams())
        let reconciledControl = try await reconciled.readControl()
        #expect(reconciledControl.revision == 1)
        let reconciledReceipt = try #require(reconciledControl.lastControlReceipt)
        #expect(reconciledReceipt.operationID == postCommitOperationID)
        #expect(try await reconciled.lookupReceipt(operationID: postCommitOperationID) == .found(.control(reconciledReceipt)))
        await reconciled.close()
    }

    @Test func maximalLegalBatchReceiptRemainsReadableAfterReopen() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let now = Date.now
        let recordingID = UUID()
        let epoch = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let samples = (0..<CapturePersistenceLimits.maximumBatchSamples).map { index in
            makeCaptureSample(
                at: now.timeIntervalSinceReferenceDate - 100 + Double(index),
                recordingID: recordingID
            )
        }
        let operationID = UUID()
        let receipt = try await store.appendBatch(samples, epoch: epoch, operationID: operationID, now: now)
        let receiptBytes = try JSONEncoder().encode(CaptureReceipt.batch(receipt)).count
        #expect(receipt.items.count == CapturePersistenceLimits.maximumBatchSamples)
        #expect(receipt.items.allSatisfy { $0.disposition == .stored })
        #expect(receiptBytes > 0 && receiptBytes <= CapturePersistenceLimits.maximumReceiptPayloadBytes)
        await store.close()

        let reopened = try RouteStore.openFoundation(at: fixture.store, seams: captureTestSeams())
        #expect(try await reopened.lookupReceipt(operationID: operationID) == .found(.batch(receipt)))
        await reopened.close()
    }

    @Test func agedBatchReceiptIsUnavailableButStableSampleCanStillReconcile() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let recordingID = UUID()
        let beginID = UUID()
        let epoch = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: beginID
        ).epoch
        let oldNow = Date.now.addingTimeInterval(-8 * 24 * 60 * 60)
        let sample = makeCaptureSample(at: oldNow.timeIntervalSinceReferenceDate - 60, recordingID: recordingID)
        let batchID = UUID()
        _ = try await store.appendBatch([sample], epoch: epoch, operationID: batchID, now: oldNow)

        #expect(try await store.lookupReceipt(operationID: batchID) == .unavailable)
        let controlState = try await store.readControl()
        let controlReceipt = try #require(controlState.lastControlReceipt)
        #expect(controlReceipt.operationID == beginID)
        #expect(try await store.lookupReceipt(operationID: beginID) == .found(.control(controlReceipt)))
        #expect(try await store.reconcileSamples([sample], epoch: epoch).first?.match == .matching)
        await store.close()
    }

    @Test func corruptControlPayloadFailsClosedOnFoundationOpen() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        await store.close()
        try executeCaptureSQL(
            at: fixture.store,
            sql: "UPDATE capture_control SET payload = X'00' WHERE singleton = 1"
        )

        expectCaptureError(.invalidControlState) {
            _ = try RouteStore.openFoundation(at: fixture.store, seams: captureTestSeams())
        }
    }

    @Test func oversizedControlAndReceiptPayloadsFailClosedOnFoundationOpen() async throws {
        let controlFixture = try makeCaptureFixture()
        defer { removeCaptureFixture(controlFixture.container) }
        let controlStore = try RouteStore.createFoundation(at: controlFixture.store, seams: captureTestSeams())
        await controlStore.close()
        try executeCaptureSQL(
            at: controlFixture.store,
            sql: "UPDATE capture_control SET payload = zeroblob(\(CapturePersistenceLimits.maximumControlPayloadBytes + 1)) WHERE singleton = 1"
        )
        expectCaptureError(.invalidControlState) {
            _ = try RouteStore.openFoundation(at: controlFixture.store, seams: captureTestSeams())
        }

        let receiptFixture = try makeCaptureFixture()
        defer { removeCaptureFixture(receiptFixture.container) }
        let receiptStore = try RouteStore.createFoundation(at: receiptFixture.store, seams: captureTestSeams())
        let recordingID = UUID()
        let epoch = try await receiptStore.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let receiptOperationID = UUID()
        let receiptSample = makeCaptureSample(
            at: Date.now.timeIntervalSinceReferenceDate - 100,
            recordingID: recordingID
        )
        _ = try await receiptStore.appendBatch([receiptSample], epoch: epoch, operationID: receiptOperationID, now: .now)
        await receiptStore.close()
        try executeCaptureSQL(
            at: receiptFixture.store,
            sql: "UPDATE capture_receipts SET payload = zeroblob(\(CapturePersistenceLimits.maximumReceiptPayloadBytes + 1)) WHERE operation_id = '\(receiptOperationID.uuidString)'"
        )
        expectCaptureError(.invalidControlState) {
            _ = try RouteStore.openFoundation(at: receiptFixture.store, seams: captureTestSeams())
        }
    }

    @Test func oversizedSamplePayloadIsRejectedDuringBoundedReconciliation() async throws {
        let fixture = try makeCaptureFixture()
        defer { removeCaptureFixture(fixture.container) }
        let store = try RouteStore.createFoundation(at: fixture.store, seams: captureTestSeams())
        let recordingID = UUID()
        let epoch = try await store.beginRecording(
            recordingID: recordingID,
            expectedControlRevision: 0,
            operationID: UUID()
        ).epoch
        let sample = makeCaptureSample(at: Date.now.timeIntervalSinceReferenceDate - 100, recordingID: recordingID)
        _ = try await store.appendBatch([sample], epoch: epoch, operationID: UUID(), now: .now)
        await store.close()
        try executeCaptureSQL(
            at: fixture.store,
            sql: "UPDATE route_samples SET payload = zeroblob(\(CapturePersistenceLimits.maximumPendingPayloadBytes + 1)) WHERE sample_id = '\(sample.id.uuidString)'"
        )

        let reopened = try RouteStore.openFoundation(at: fixture.store, seams: captureTestSeams())
        await expectCaptureErrorAsync(.unavailable(.corruptDatabase)) {
            _ = try await reopened.reconcileSamples([sample], epoch: epoch)
        }
        await reopened.close()
    }
}

private func captureTestSeams(
    fault: @escaping @Sendable (RouteStoreFaultPoint) throws -> Void = { _ in }
) -> RouteStoreSeams {
    RouteStoreSeams(
        protectAndVerify: { url, item in
            #if targetEnvironment(simulator)
            try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
                .completeUntilFirstUserAuthentication
            })
            #else
            try RouteStoreFiles.protectAndVerify(url, as: item)
            #endif
        },
        fault: fault
    )
}

private func makeCaptureFixture() throws -> (container: URL, store: URL) {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw RouteStoreError.unsafePath
    }
    defer { Darwin.free(resolved) }
    let container = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("CapturePersistence-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: container,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return (container, container.appendingPathComponent("store", isDirectory: true))
}

private func removeCaptureFixture(_ container: URL) {
    try? FileManager.default.removeItem(at: container)
}

private func executeCaptureSQL(at storeURL: URL, sql: String) throws {
    var database: OpaquePointer?
    let openStatus = storeURL.appendingPathComponent(RouteStoreFiles.databaseName).path.withCString { path in
        sqlite3_open_v2(path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
    }
    guard openStatus == SQLITE_OK, let openedDatabase = database else {
        if let database {
            _ = sqlite3_close_v2(database)
        }
        throw RouteStoreError.writeFailed
    }
    defer { _ = sqlite3_close_v2(openedDatabase) }
    guard sql.withCString({ sqlite3_exec(openedDatabase, $0, nil, nil, nil) }) == SQLITE_OK else {
        throw RouteStoreError.writeFailed
    }
}

private func makeCaptureSample(
    at referenceSeconds: TimeInterval,
    id: UUID = UUID(),
    recordingID: UUID = UUID(),
    latitude: Double = 12.3456
) -> RouteSample {
    RouteSample(
        id: id,
        recordingID: recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: referenceSeconds),
        latitude: latitude,
        longitude: -45.6789,
        horizontalAccuracy: 7.5,
        isStationary: false
    )
}

private func expectRouteStoreError(
    _ expected: RouteStoreError,
    operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try operation()
        Issue.record("Expected a typed RouteStoreError", sourceLocation: sourceLocation)
    } catch let error as RouteStoreError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
    }
}

private func expectCaptureError(
    _ expected: CapturePersistenceError,
    operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try operation()
        Issue.record("Expected a typed CapturePersistenceError", sourceLocation: sourceLocation)
    } catch let error as CapturePersistenceError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
    }
}

private func expectCaptureErrorAsync(
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
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
    }
}
