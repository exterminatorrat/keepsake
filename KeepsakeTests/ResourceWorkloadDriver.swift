import Foundation
@testable import Keepsake

struct ResourceWorkloadDriver: Sendable {
    private let storeURL: URL
    private let seams: RouteStoreSeams
    private let hooks: ResourceWorkloadMetricHooks

    init(storeURL: URL, seams: RouteStoreSeams, hooks: ResourceWorkloadMetricHooks) {
        self.storeURL = storeURL
        self.seams = seams
        self.hooks = hooks
    }

    func run(
        stage: ResourceWorkloadStage,
        repetition: Int,
        operationID: UUID = UUID()
    ) async throws -> ResourceWorkloadDriverResult {
        guard (1...ResourceWorkloadFixture.repetitionCount).contains(repetition) else {
            throw ResourceWorkloadDriverError.invalidRepetition(repetition)
        }

        guard ResourceWorkloadFixture.pageLimitRows <= CapturePersistenceLimits.maximumPageRows else {
            throw ResourceWorkloadDriverError.configuredPageLimitExceeded
        }

        let fixture = ResourceWorkloadFixture(stage: stage, repetition: repetition)
        let stopOracle = fixture.stopOracle
        guard stopOracle.stopOperationCount == 1,
              stopOracle.receiptKind == .stop,
              stopOracle.stopUsesBeginReceiptControlRevision,
              stopOracle.receiptUsesBeginEpoch,
              stopOracle.activeEpochAfterStopIsNil,
              stopOracle.snapshotMatchesReceiptAfterReopen,
              stopOracle.lookupReturnsSameReceiptAfterReopen,
              !stopOracle.retryOrReconcileOnUncertainOutcome else {
            throw ResourceWorkloadDriverError.unsupportedStopOracle
        }
        var calls = ResourceWorkloadCallCounter()
        var appendedSampleCount = 0
        var inputEncodedPayloadBytes = 0
        var returnedSampleCount = 0
        var returnedEncodedPayloadBytes = 0

        func record(
            _ boundary: ResourceWorkloadMetricEvent.Boundary,
            batchIndex: Int? = nil,
            intervalIndex: Int? = nil,
            pageIndex: Int? = nil,
            boundarySampleCount: Int = 0,
            boundaryEncodedPayloadBytes: Int = 0
        ) {
            hooks.observe(ResourceWorkloadMetricEvent(
                operationID: operationID,
                stage: stage,
                repetition: repetition,
                boundary: boundary,
                monotonicTicks: hooks.monotonicNow(),
                calls: calls.snapshot(),
                appendedSampleCount: appendedSampleCount,
                returnedSampleCount: returnedSampleCount,
                inputEncodedPayloadBytes: inputEncodedPayloadBytes,
                returnedEncodedPayloadBytes: returnedEncodedPayloadBytes,
                batchIndex: batchIndex,
                intervalIndex: intervalIndex,
                pageIndex: pageIndex,
                boundarySampleCount: boundarySampleCount,
                boundaryEncodedPayloadBytes: boundaryEncodedPayloadBytes
            ))
        }

        record(.operationStarted)
        record(.stageStarted)
        var openStore: RouteStore?

        do {
            calls.openCreateEmpty += 1
            let createdStore = try RouteStore.createFoundation(at: storeURL, seams: seams)
            openStore = createdStore

            calls.readControl += 1
            let initialControl = try await createdStore.readControl()
            guard initialControl == CaptureControlSnapshot(
                revision: 0,
                activeEpoch: nil,
                lastControlReceipt: nil
            ) else {
                throw ResourceWorkloadDriverError.initialControlMismatch
            }

            calls.beginRecording += 1
            let beginReceipt = try await createdStore.beginRecording(
                recordingID: fixture.recordingID,
                expectedControlRevision: stopOracle.beginExpectedControlRevision,
                operationID: operationID
            )
            let expectedEpoch = CaptureEpoch(recordingID: fixture.recordingID, revision: 1)
            let expectedBeginReceipt = CaptureControlReceipt(
                operationID: operationID,
                kind: .begin,
                epoch: expectedEpoch,
                controlRevision: 1,
                commandDigest: CaptureCommandDigest.begin(
                    recordingID: fixture.recordingID,
                    expectedControlRevision: stopOracle.beginExpectedControlRevision
                )
            )
            guard beginReceipt == expectedBeginReceipt else {
                throw ResourceWorkloadDriverError.beginReceiptMismatch
            }

            let appendNow = fixture.pageInterval(at: 0).queryNow
            for batchIndex in 0..<fixture.batchCount {
                let batch = fixture.batch(at: batchIndex)
                guard batch.count <= ResourceWorkloadFixture.batchRowLimit,
                      batch.count <= CapturePersistenceLimits.maximumBatchSamples else {
                    throw ResourceWorkloadDriverError.batchLimitExceeded(batchIndex)
                }
                let input = try CaptureBatchInput(samples: batch)
                let batchOperationID = UUID()
                calls.appendBatchCalls += 1
                record(
                    .batchStarted,
                    batchIndex: batchIndex,
                    boundarySampleCount: batch.count,
                    boundaryEncodedPayloadBytes: input.encodedPayloadBytes
                )
                let receipt = try await createdStore.appendBatch(
                    batch,
                    epoch: beginReceipt.epoch,
                    operationID: batchOperationID,
                    now: appendNow
                )
                guard receipt.operationID == batchOperationID,
                      receipt.epoch == beginReceipt.epoch,
                      receipt.items.map(\.sampleID) == batch.map(\.id),
                      receipt.items.allSatisfy({ $0.disposition == .stored }) else {
                    throw ResourceWorkloadDriverError.batchReceiptMismatch(batchIndex)
                }
                appendedSampleCount += batch.count
                inputEncodedPayloadBytes = try addingPayloadBytes(
                    inputEncodedPayloadBytes,
                    input.encodedPayloadBytes
                )
                record(
                    .batchCompleted,
                    batchIndex: batchIndex,
                    boundarySampleCount: batch.count,
                    boundaryEncodedPayloadBytes: input.encodedPayloadBytes
                )
            }

            let stopOperationID = UUID()
            calls.stopRecording += 1
            record(.stopStarted)
            let stopReceipt = try await createdStore.stopRecording(
                epoch: beginReceipt.epoch,
                expectedControlRevision: beginReceipt.controlRevision,
                operationID: stopOperationID
            )
            record(.stopReturned)
            let expectedStopReceipt = CaptureControlReceipt(
                operationID: stopOperationID,
                kind: stopOracle.receiptKind,
                epoch: beginReceipt.epoch,
                controlRevision: beginReceipt.controlRevision + stopOracle.receiptControlRevisionIncrement,
                commandDigest: CaptureCommandDigest.stop(
                    epoch: beginReceipt.epoch,
                    expectedControlRevision: beginReceipt.controlRevision
                )
            )
            guard stopReceipt == expectedStopReceipt else {
                throw ResourceWorkloadDriverError.stopReceiptMismatch
            }

            await createdStore.close()
            calls.closeTotalIncludingReopenVerified += 1
            openStore = nil

            calls.reopenVerified += 1
            let reopenedStore = try RouteStore.openFoundation(at: storeURL, seams: seams)
            openStore = reopenedStore

            calls.readControl += 1
            let stoppedControl = try await reopenedStore.readControl()
            let expectedStoppedControl = CaptureControlSnapshot(
                revision: stopReceipt.controlRevision,
                activeEpoch: nil,
                lastControlReceipt: stopReceipt
            )
            guard stoppedControl == expectedStoppedControl else {
                throw ResourceWorkloadDriverError.stoppedControlMismatch
            }

            calls.lookupStopReceipt += 1
            let lookup = try await reopenedStore.lookupReceipt(operationID: stopOperationID)
            guard case let .found(.control(durableStopReceipt)) = lookup,
                  durableStopReceipt == stopReceipt else {
                throw ResourceWorkloadDriverError.stopReceiptLookupMismatch
            }
            record(.stopCompleted)

            let rowsPerInterval = stage.rowCount / fixture.pageIntervalCount
            let expectedHighWaterSequence = Int64(stage.rowCount)
            var cursorStoreOpenID: UUID?
            for intervalIndex in 0..<fixture.pageIntervalCount {
                let pageOracle = fixture.pageInterval(at: intervalIndex)
                let firstSampleIndex = intervalIndex * rowsPerInterval
                let intervalEndSampleIndex = firstSampleIndex + rowsPerInterval
                guard stage.rowCount.isMultiple(of: fixture.pageIntervalCount),
                      intervalEndSampleIndex <= stage.rowCount else {
                    throw ResourceWorkloadDriverError.intervalSampleCountMismatch(intervalIndex)
                }

                    var cursor: CapturePageCursor?
                    var pageIndex = 0
                    while true {
                        guard pageIndex < pageOracle.pageCount else {
                            throw ResourceWorkloadDriverError.pageCountMismatch(
                                intervalIndex: intervalIndex,
                                expected: pageOracle.pageCount,
                                actual: pageIndex + 1
                            )
                        }
                        let expectedRows = pageOracle.rowCount(at: pageIndex)
                        guard expectedRows <= ResourceWorkloadFixture.pageLimitRows,
                              expectedRows <= CapturePersistenceLimits.maximumPageRows else {
                            throw ResourceWorkloadDriverError.pageLimitExceeded(intervalIndex, pageIndex)
                        }
                        let sampleStart = pageIndex * ResourceWorkloadFixture.pageLimitRows
                        let expectedFirstSampleIndex = firstSampleIndex + sampleStart
                        let expectedEndSampleIndex = expectedFirstSampleIndex + expectedRows
                        guard expectedEndSampleIndex <= intervalEndSampleIndex else {
                            throw ResourceWorkloadDriverError.pageRowsMismatch(
                                intervalIndex: intervalIndex,
                                pageIndex: pageIndex,
                                expected: expectedRows,
                                actual: max(0, intervalEndSampleIndex - expectedFirstSampleIndex)
                            )
                        }
                        let expectedPageSamples = (expectedFirstSampleIndex..<expectedEndSampleIndex).map {
                            fixture.sample(at: $0)
                        }
                        let expectedPagePayloadBytes = try encodedPayloadBytes(for: expectedPageSamples)
                        if let cursor {
                            guard cursor.highWaterSequence == expectedHighWaterSequence,
                                  cursor.deletionRevision == 0,
                                  let cursorStoreOpenID,
                                  cursor.storeOpenID == cursorStoreOpenID else {
                                throw ResourceWorkloadDriverError.cursorIdentityMismatch(intervalIndex, pageIndex)
                            }
                        }
                        calls.readPageCalls += 1
                        record(.pageStarted, intervalIndex: intervalIndex, pageIndex: pageIndex)
                        let page = try await reopenedStore.readPage(
                            interval: pageOracle.interval,
                            now: pageOracle.queryNow,
                            limit: ResourceWorkloadFixture.pageLimitRows,
                        cursor: cursor
                    )
                    record(.pageReturned, intervalIndex: intervalIndex, pageIndex: pageIndex)
                    guard page.items.count == expectedRows else {
                            throw ResourceWorkloadDriverError.pageRowsMismatch(
                                intervalIndex: intervalIndex,
                                pageIndex: pageIndex,
                                expected: expectedRows,
                                actual: page.items.count
                            )
                        }
                        guard RouteStoreFiles.exactSamplesEquality(
                            page.items.map(\.sample),
                            expectedPageSamples
                        ) else {
                            throw ResourceWorkloadDriverError.pageSamplesMismatch(intervalIndex, pageIndex)
                        }
                        let expectedSequenceStart = Int64(expectedFirstSampleIndex + 1)
                        let expectedSequences = Array(
                            expectedSequenceStart..<(expectedSequenceStart + Int64(expectedRows))
                        )
                        guard page.items.map(\.sequence) == expectedSequences else {
                            throw ResourceWorkloadDriverError.pageSequencesMismatch(intervalIndex, pageIndex)
                        }
                        guard page.items.allSatisfy({ $0.epoch == beginReceipt.epoch }) else {
                            throw ResourceWorkloadDriverError.pageEpochMismatch(intervalIndex, pageIndex)
                        }
                        guard page.encodedPayloadBytes <= CapturePersistenceLimits.maximumPagePayloadBytes,
                              page.encodedPayloadBytes == expectedPagePayloadBytes else {
                            throw ResourceWorkloadDriverError.pagePayloadMismatch(
                                intervalIndex: intervalIndex,
                                pageIndex: pageIndex,
                                expected: expectedPagePayloadBytes,
                                actual: page.encodedPayloadBytes
                            )
                        }

                        returnedSampleCount += page.items.count
                        returnedEncodedPayloadBytes = try addingPayloadBytes(
                            returnedEncodedPayloadBytes,
                            page.encodedPayloadBytes
                        )
                        let expectsContinuation = pageIndex + 1 < pageOracle.pageCount
                        if expectsContinuation {
                            guard let nextCursor = page.nextCursor,
                                  let lastItem = page.items.last else {
                                throw ResourceWorkloadDriverError.missingCursor(intervalIndex, pageIndex)
                            }
                            guard nextCursor.highWaterSequence == expectedHighWaterSequence,
                                  nextCursor.deletionRevision == 0 else {
                                throw ResourceWorkloadDriverError.cursorIdentityMismatch(intervalIndex, pageIndex)
                            }
                            if let cursorStoreOpenID {
                                guard nextCursor.storeOpenID == cursorStoreOpenID else {
                                    throw ResourceWorkloadDriverError.cursorIdentityMismatch(intervalIndex, pageIndex)
                                }
                            } else {
                                cursorStoreOpenID = nextCursor.storeOpenID
                            }
                            guard nextCursor.interval == pageOracle.interval,
                                  nextCursor.queryNow == pageOracle.queryNow,
                                  nextCursor.lastObservedAt == lastItem.sample.observedAt,
                                  nextCursor.lastSequence == lastItem.sequence else {
                                throw ResourceWorkloadDriverError.cursorProgressMismatch(intervalIndex, pageIndex)
                            }
                            cursor = nextCursor
                        } else {
                            guard page.nextCursor == nil else {
                                throw ResourceWorkloadDriverError.unexpectedTerminalCursor(intervalIndex)
                            }
                        }
                        record(
                            .pageCompleted,
                            intervalIndex: intervalIndex,
                            pageIndex: pageIndex,
                            boundarySampleCount: page.items.count,
                            boundaryEncodedPayloadBytes: page.encodedPayloadBytes
                        )
                        pageIndex += 1
                        if !expectsContinuation {
                            break
                        }
                    }
                    guard pageIndex == pageOracle.pageCount else {
                        throw ResourceWorkloadDriverError.pageCountMismatch(
                            intervalIndex: intervalIndex,
                            expected: pageOracle.pageCount,
                            actual: pageIndex
                        )
                    }
                }

            guard appendedSampleCount == stage.rowCount,
                  returnedSampleCount == stage.rowCount else {
                throw ResourceWorkloadDriverError.workloadSampleCountMismatch
            }
            guard inputEncodedPayloadBytes == returnedEncodedPayloadBytes else {
                throw ResourceWorkloadDriverError.totalPayloadBytesMismatch(
                    expected: inputEncodedPayloadBytes,
                    actual: returnedEncodedPayloadBytes
                )
            }

            await reopenedStore.close()
            calls.closeTotalIncludingReopenVerified += 1
            calls.finalClose += 1
            openStore = nil
            let observedCalls = calls.snapshot()
            guard observedCalls.matches(fixture.apiCalls) else {
                throw ResourceWorkloadDriverError.apiCallCountMismatch
            }
            record(.stageCompleted)
            record(.operationCompleted)

            return ResourceWorkloadDriverResult(
                operationID: operationID,
                stage: stage,
                repetition: repetition,
                recordingID: fixture.recordingID,
                stopReceipt: stopReceipt,
                durableStopReceipt: durableStopReceipt,
                stoppedControl: stoppedControl,
                appendedSampleCount: appendedSampleCount,
                returnedSampleCount: returnedSampleCount,
                inputEncodedPayloadBytes: inputEncodedPayloadBytes,
                returnedEncodedPayloadBytes: returnedEncodedPayloadBytes,
                calls: observedCalls
            )
        } catch {
            if let openStore {
                await openStore.close()
                calls.closeTotalIncludingReopenVerified += 1
            }
            record(.stageFailed)
            record(.operationFailed)
            throw error
        }
    }
}

struct ResourceWorkloadMetricHooks: Sendable {
    let monotonicNow: @Sendable () -> UInt64
    let observe: @Sendable (ResourceWorkloadMetricEvent) -> Void
}

struct ResourceWorkloadMetricEvent: Equatable, Sendable {
    enum Boundary: Equatable, Sendable {
        case operationStarted
        case operationCompleted
        case operationFailed
        case stageStarted
        case stageCompleted
        case stageFailed
        case batchStarted
        case batchCompleted
        case pageStarted
        case pageReturned
        case pageCompleted
        case stopStarted
        case stopReturned
        case stopCompleted
    }

    let operationID: UUID
    let stage: ResourceWorkloadStage
    let repetition: Int
    let boundary: Boundary
    let monotonicTicks: UInt64
    let calls: ResourceWorkloadDriverCallCounts
    let appendedSampleCount: Int
    let returnedSampleCount: Int
    let inputEncodedPayloadBytes: Int
    let returnedEncodedPayloadBytes: Int
    let batchIndex: Int?
    let intervalIndex: Int?
    let pageIndex: Int?
    let boundarySampleCount: Int
    let boundaryEncodedPayloadBytes: Int
}

struct ResourceWorkloadDriverCallCounts: Equatable, Sendable {
    let openCreateEmpty: Int
    let readControl: Int
    let beginRecording: Int
    let appendBatchCalls: Int
    let stopRecording: Int
    let reopenVerified: Int
    let lookupStopReceipt: Int
    let readPageCalls: Int
    let finalClose: Int
    let closeTotalIncludingReopenVerified: Int
    let clearHistory: Int
    let pruneHistory: Int
    let reconcileSamples: Int
    let runtimeStartOrCoreLocationCalls: Int
    let runtimeStopCalls: Int

    func matches(_ oracle: ResourceWorkloadAPICallOracle) -> Bool {
        openCreateEmpty == oracle.openCreateEmpty
            && readControl == oracle.readControl
            && beginRecording == oracle.beginRecording
            && appendBatchCalls == oracle.appendBatchCalls
            && stopRecording == oracle.stopRecording
            && reopenVerified == oracle.reopenVerified
            && lookupStopReceipt == oracle.lookupStopReceipt
            && readPageCalls == oracle.readPageCalls
            && finalClose == oracle.finalClose
            && closeTotalIncludingReopenVerified == oracle.closeTotalIncludingReopenVerified
            && clearHistory == oracle.clearHistory
            && pruneHistory == oracle.pruneHistory
            && reconcileSamples == oracle.reconcileSamples
            && runtimeStartOrCoreLocationCalls == oracle.runtimeStartOrCoreLocationCalls
            && runtimeStopCalls == oracle.runtimeStopCalls
    }
}

struct ResourceWorkloadDriverResult: Equatable, Sendable {
    let operationID: UUID
    let stage: ResourceWorkloadStage
    let repetition: Int
    let recordingID: UUID
    let stopReceipt: CaptureControlReceipt
    let durableStopReceipt: CaptureControlReceipt
    let stoppedControl: CaptureControlSnapshot
    let appendedSampleCount: Int
    let returnedSampleCount: Int
    let inputEncodedPayloadBytes: Int
    let returnedEncodedPayloadBytes: Int
    let calls: ResourceWorkloadDriverCallCounts
}

enum ResourceWorkloadDriverError: Error, Equatable, Sendable {
    case invalidRepetition(Int)
    case configuredPageLimitExceeded
    case unsupportedStopOracle
    case initialControlMismatch
    case beginReceiptMismatch
    case batchLimitExceeded(Int)
    case batchReceiptMismatch(Int)
    case intervalSampleCountMismatch(Int)
    case pageCountMismatch(intervalIndex: Int, expected: Int, actual: Int)
    case pageLimitExceeded(Int, Int)
    case pageRowsMismatch(intervalIndex: Int, pageIndex: Int, expected: Int, actual: Int)
    case pageSamplesMismatch(Int, Int)
    case pageSequencesMismatch(Int, Int)
    case pageEpochMismatch(Int, Int)
    case pagePayloadMismatch(intervalIndex: Int, pageIndex: Int, expected: Int, actual: Int)
    case missingCursor(Int, Int)
    case cursorIdentityMismatch(Int, Int)
    case cursorProgressMismatch(Int, Int)
    case unexpectedTerminalCursor(Int)
    case stopReceiptMismatch
    case stoppedControlMismatch
    case stopReceiptLookupMismatch
    case workloadSampleCountMismatch
    case totalPayloadBytesMismatch(expected: Int, actual: Int)
    case apiCallCountMismatch
    case payloadByteOverflow
}

private struct ResourceWorkloadCallCounter {
    var openCreateEmpty = 0
    var readControl = 0
    var beginRecording = 0
    var appendBatchCalls = 0
    var stopRecording = 0
    var reopenVerified = 0
    var lookupStopReceipt = 0
    var readPageCalls = 0
    var finalClose = 0
    var closeTotalIncludingReopenVerified = 0

    func snapshot() -> ResourceWorkloadDriverCallCounts {
        ResourceWorkloadDriverCallCounts(
            openCreateEmpty: openCreateEmpty,
            readControl: readControl,
            beginRecording: beginRecording,
            appendBatchCalls: appendBatchCalls,
            stopRecording: stopRecording,
            reopenVerified: reopenVerified,
            lookupStopReceipt: lookupStopReceipt,
            readPageCalls: readPageCalls,
            finalClose: finalClose,
            closeTotalIncludingReopenVerified: closeTotalIncludingReopenVerified,
            clearHistory: 0,
            pruneHistory: 0,
            reconcileSamples: 0,
            runtimeStartOrCoreLocationCalls: 0,
            runtimeStopCalls: 0
        )
    }
}

private func encodedPayloadBytes(for samples: [RouteSample]) throws -> Int {
    let encoder = JSONEncoder()
    var total = 0
    for sample in samples {
        total = try addingPayloadBytes(total, encoder.encode(sample).count)
    }
    return total
}

private func addingPayloadBytes(_ total: Int, _ additional: Int) throws -> Int {
    let (sum, overflow) = total.addingReportingOverflow(additional)
    guard !overflow else {
        throw ResourceWorkloadDriverError.payloadByteOverflow
    }
    return sum
}
