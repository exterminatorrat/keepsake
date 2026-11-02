import Darwin
import Foundation
import Synchronization
import Testing
@testable import Keepsake

struct ResourceWorkloadDriverTests {
    @Test(.timeLimit(.minutes(1)))
    func selectedBaselinePersistsExactSamplesAndStopReceiptWithMetricBoundaries() async throws {
        let fixture = ResourceWorkloadFixture(stage: .b0, repetition: 1)
        let storeFixture = try makeResourceWorkloadStoreFixture()
        defer { try? FileManager.default.removeItem(at: storeFixture.container) }
        let clock = Mutex<UInt64>(0)
        let events = Mutex<[ResourceWorkloadMetricEvent]>([])
        let hooks = ResourceWorkloadMetricHooks(
            monotonicNow: {
                clock.withLock { ticks in
                    ticks += 1
                    return ticks
                }
            },
            observe: { event in
                events.withLock { $0.append(event) }
            }
        )
        let operationID = UUID()
        let driver = ResourceWorkloadDriver(
            storeURL: storeFixture.store,
            seams: resourceWorkloadTestSeams(),
            hooks: hooks
        )
        let result = try await driver.run(stage: .b0, repetition: 1, operationID: operationID)
        var expectedPayloadBytes = 0
        for batchIndex in 0..<fixture.batchCount {
            let batch = try CaptureBatchInput(samples: fixture.batch(at: batchIndex))
            expectedPayloadBytes += batch.encodedPayloadBytes
        }
        let observedEvents = events.withLock { $0 }
        let expectedBoundaries: [ResourceWorkloadMetricEvent.Boundary] = [
            .operationStarted,
            .stageStarted,
            .batchStarted,
            .batchCompleted,
            .batchStarted,
            .batchCompleted,
            .stopStarted,
            .stopReturned,
            .stopCompleted,
            .pageStarted,
            .pageReturned,
            .pageCompleted,
            .stageCompleted,
            .operationCompleted
        ]

        #expect(result.operationID == operationID)
        #expect(result.stage == .b0)
        #expect(result.repetition == 1)
        #expect(result.recordingID == fixture.recordingID)
        #expect(result.appendedSampleCount == fixture.stage.rowCount)
        #expect(result.returnedSampleCount == fixture.stage.rowCount)
        #expect(result.inputEncodedPayloadBytes == expectedPayloadBytes)
        #expect(result.returnedEncodedPayloadBytes == expectedPayloadBytes)
        #expect(result.stopReceipt.kind == .stop)
        #expect(result.stopReceipt.epoch == CaptureEpoch(recordingID: fixture.recordingID, revision: 1))
        #expect(result.durableStopReceipt == result.stopReceipt)
        #expect(result.stoppedControl.activeEpoch == nil)
        #expect(result.stoppedControl.lastControlReceipt == result.stopReceipt)
        #expect(result.calls.matches(fixture.apiCalls))
        #expect(result.calls.appendBatchCalls == 2)
        #expect(result.calls.readPageCalls == 1)
        #expect(result.calls.finalClose == 1)
        #expect(result.calls.closeTotalIncludingReopenVerified == 2)
        #expect(observedEvents.map(\.boundary) == expectedBoundaries)
        #expect(observedEvents.allSatisfy {
            $0.operationID == operationID && $0.stage == .b0 && $0.repetition == 1
        })
        #expect(zip(observedEvents, observedEvents.dropFirst()).allSatisfy {
            $0.0.monotonicTicks < $0.1.monotonicTicks
        })
        #expect(observedEvents.filter { $0.boundary == .batchStarted }.map(\.boundarySampleCount) == [32, 28])
        #expect(observedEvents.filter { $0.boundary == .batchCompleted }.map(\.boundarySampleCount) == [32, 28])
        #expect(observedEvents.filter { $0.boundary == .pageCompleted }.map(\.boundarySampleCount) == [60])
        #expect(observedEvents.filter { $0.boundary == .pageCompleted }.map(\.boundaryEncodedPayloadBytes) == [expectedPayloadBytes])
        #expect(observedEvents.last?.calls == result.calls)
        #expect(observedEvents.last?.appendedSampleCount == fixture.stage.rowCount)
        #expect(observedEvents.last?.returnedSampleCount == fixture.stage.rowCount)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidRepetitionFailsBeforeOpeningOrEmittingWorkloadEvents() async throws {
        let storeFixture = try makeResourceWorkloadStoreFixture()
        defer { try? FileManager.default.removeItem(at: storeFixture.container) }
        let events = Mutex<[ResourceWorkloadMetricEvent]>([])
        let driver = ResourceWorkloadDriver(
            storeURL: storeFixture.store,
            seams: resourceWorkloadTestSeams(),
            hooks: ResourceWorkloadMetricHooks(
                monotonicNow: { 0 },
                observe: { event in events.withLock { $0.append(event) } }
            )
        )

        do {
            _ = try await driver.run(stage: .b0, repetition: 0)
            Issue.record("An invalid repetition must be rejected")
        } catch let error as ResourceWorkloadDriverError {
            #expect(error == .invalidRepetition(0))
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }

        #expect(events.withLock { $0.isEmpty })
        #expect(!FileManager.default.fileExists(atPath: storeFixture.store.path))
    }
}

private func makeResourceWorkloadStoreFixture() throws -> (container: URL, store: URL) {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw RouteStoreError.unsafePath
    }
    defer { Darwin.free(resolved) }
    let container = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("ResourceWorkload-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: container,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return (container, container.appendingPathComponent("store", isDirectory: true))
}

private func resourceWorkloadTestSeams() -> RouteStoreSeams {
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
        readProtection: { url in
            #if targetEnvironment(simulator)
            return .completeUntilFirstUserAuthentication
            #else
            return try RouteStoreFiles.readProtection(at: url)
            #endif
        }
    )
}
