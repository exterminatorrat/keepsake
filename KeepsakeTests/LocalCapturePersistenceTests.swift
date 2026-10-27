import Foundation
import Testing
@testable import Keepsake

struct LocalCapturePersistenceTests {
    @Test func historyReceiptsRoundTripAndHaveDistinctContentDigests() throws {
        let clear = CaptureClearReceipt(
            operationID: UUID(),
            controlRevision: 2,
            deletionRevision: 1,
            clearedThroughSequence: 3,
            commandDigest: CaptureCommandDigest.clear(expectedControlRevision: 2)
        )
        let now = Date(timeIntervalSinceReferenceDate: 100)
        let prune = CapturePruneReceipt(
            operationID: UUID(),
            commandDigest: CaptureCommandDigest.prune(now: now, limit: 2),
            deletionRevision: 2,
            deletedRows: 2,
            deletedPayloadBytes: 200,
            hasMore: true
        )
        for receipt in [CaptureReceipt.clear(clear), .prune(prune)] {
            let encoded = try JSONEncoder().encode(receipt)
            #expect(try JSONDecoder().decode(CaptureReceipt.self, from: encoded) == receipt)
        }
        #expect(clear.commandDigest != prune.commandDigest)
        #expect(clear.commandDigest != CaptureCommandDigest.clear(expectedControlRevision: 3))
        #expect(prune.commandDigest != CaptureCommandDigest.prune(now: now, limit: 3))
        #expect(prune.commandDigest != CaptureCommandDigest.prune(now: now.addingTimeInterval(1), limit: 2))
    }

    @Test func historyMetadataDoesNotChangeRecordingIntentAndPreservesItsFence() throws {
        let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
        let stop = CaptureControlReceipt(
            operationID: UUID(),
            kind: .stop,
            epoch: epoch,
            controlRevision: 2,
            commandDigest: CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: 1)
        )
        let stopped = CaptureControlSnapshot(revision: 2, activeEpoch: nil, lastControlReceipt: stop)
        let clear = CaptureClearReceipt(
            operationID: UUID(),
            controlRevision: 2,
            deletionRevision: 1,
            clearedThroughSequence: 3,
            commandDigest: CaptureCommandDigest.clear(expectedControlRevision: 2)
        )
        let cleared = CaptureControlSnapshot(
            revision: 2,
            activeEpoch: nil,
            lastControlReceipt: stop,
            deletionRevision: 1,
            clearedThroughSequence: 3,
            lastClearReceipt: clear
        )
        #expect(cleared.hasValidHistoryState)
        #expect(cleared != stopped)
        #expect(cleared.hasSameRecordingIntent(as: stopped))
        let encoded = try JSONEncoder().encode(cleared)
        #expect(try JSONDecoder().decode(CaptureControlSnapshot.self, from: encoded) == cleared)
        let invalid = CaptureControlSnapshot(
            revision: 2,
            activeEpoch: nil,
            lastControlReceipt: stop,
            deletionRevision: 1,
            clearedThroughSequence: 3
        )
        #expect(!invalid.hasValidHistoryState)
    }

    @Test func controlAndBatchReceiptsRoundTripWithoutChangingDispositions() throws {
        let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
        let control = CaptureControlReceipt(
            operationID: UUID(),
            kind: .begin,
            epoch: epoch,
            controlRevision: 1,
            commandDigest: CaptureCommandDigest.begin(recordingID: epoch.recordingID, expectedControlRevision: 0)
        )
        let batch = CaptureBatchReceipt(
            operationID: UUID(),
            epoch: epoch,
            commandDigest: "synthetic-command-digest",
            items: [SampleIngestResult.stored, .duplicate, .outOfOrder, .invalid, .expired].map {
                CaptureSampleResult(sampleID: UUID(), disposition: $0)
            }
        )
        for receipt in [CaptureReceipt.control(control), .batch(batch)] {
            let encoded = try JSONEncoder().encode(receipt)
            #expect(try JSONDecoder().decode(CaptureReceipt.self, from: encoded) == receipt)
        }
    }

    @Test func commandKindsRevisionsAndOrderedPayloadsHaveDifferentDigests() throws {
        let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
        let first = sample(recordingID: epoch.recordingID, seconds: 1)
        let second = sample(recordingID: epoch.recordingID, seconds: 2)
        let ordered = try CaptureBatchInput(samples: [first, second])
        let reversed = try CaptureBatchInput(samples: [second, first])
        #expect(CaptureCommandDigest.begin(recordingID: epoch.recordingID, expectedControlRevision: 0)
            != CaptureCommandDigest.begin(recordingID: epoch.recordingID, expectedControlRevision: 1))
        #expect(CaptureCommandDigest.begin(recordingID: epoch.recordingID, expectedControlRevision: 1)
            != CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: 1))
        #expect(CaptureCommandDigest.batch(epoch: epoch, input: ordered)
            != CaptureCommandDigest.batch(epoch: epoch, input: reversed))
        #expect(CaptureCommandDigest.batch(epoch: epoch, input: ordered)
            == CaptureCommandDigest.batch(epoch: epoch, input: ordered))
    }

    @Test func digestPreservesSignedZeroAndOptionalMeasurementDistinctions() throws {
        let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
        let id = UUID()
        let positive = sample(id: id, recordingID: epoch.recordingID, seconds: 1, latitude: 0)
        let negative = sample(id: id, recordingID: epoch.recordingID, seconds: 1, latitude: -0.0)
        let optional = sample(id: id, recordingID: epoch.recordingID, seconds: 1, latitude: 0, speed: 0)
        let digest = CaptureCommandDigest.batch(epoch: epoch, input: try CaptureBatchInput(samples: [positive]))
        #expect(digest != CaptureCommandDigest.batch(epoch: epoch, input: try CaptureBatchInput(samples: [negative])))
        #expect(digest != CaptureCommandDigest.batch(epoch: epoch, input: try CaptureBatchInput(samples: [optional])))
    }

    @Test func invalidNonfiniteSampleRemainsFingerprintableWithoutJSONEncodingIt() throws {
        let epoch = CaptureEpoch(recordingID: UUID(), revision: 1)
        let invalid = sample(recordingID: epoch.recordingID, seconds: 1, latitude: .nan)
        #expect(!invalid.isValid)
        let input = try CaptureBatchInput(samples: [invalid])
        #expect(input.encodedPayloadBytes == 0)
        #expect(input.samples.count == 1)
        #expect(CaptureCommandDigest.batch(epoch: epoch, input: input).count == 64)
    }

    @Test func countBoundRejectsBeforeEncodingAndPayloadAccountingIsExact() throws {
        let recordingID = UUID()
        let invalid = sample(recordingID: recordingID, seconds: 1, latitude: .nan)
        #expect(throws: CapturePersistenceError.batchTooLarge) {
            _ = try CaptureBatchInput(samples: Array(repeating: invalid, count: CapturePersistenceLimits.maximumBatchSamples + 1))
        }
        let samples = (0..<CapturePersistenceLimits.maximumBatchSamples).map {
            sample(recordingID: recordingID, seconds: Double($0))
        }
        let input = try CaptureBatchInput(samples: samples)
        let encodedBytes = try samples.reduce(0) { count, sample in
            count + (try JSONEncoder().encode(sample)).count
        }
        #expect(input.encodedPayloadBytes == encodedBytes)
        #expect(input.encodedPayloadBytes <= CapturePersistenceLimits.maximumPendingPayloadBytes)
    }
}

private func sample(
    id: UUID = UUID(),
    recordingID: UUID,
    seconds: TimeInterval,
    latitude: Double = 10,
    speed: Double? = nil
) -> RouteSample {
    RouteSample(
        id: id,
        recordingID: recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: seconds),
        latitude: latitude,
        longitude: 20,
        horizontalAccuracy: 5,
        speed: speed,
        isStationary: false
    )
}
