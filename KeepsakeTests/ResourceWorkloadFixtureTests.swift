import Foundation
import Testing
@testable import Keepsake

struct ResourceWorkloadFixtureTests {
    @Test(.timeLimit(.minutes(1)))
    func stagesMatchTheCorrectedV2Order() {
        let stages = ResourceWorkloadStage.allCases.map(\.rawValue)

        #expect(stages == ["B0", "stationary", "walk", "drive", "H1", "H2"])
    }

    @Test(.timeLimit(.minutes(1)), arguments: ResourceWorkloadStage.allCases)
    func eachStageExposesExactBatchPageAndStopExpectations(_ stage: ResourceWorkloadStage) {
        let fixture = ResourceWorkloadFixture(stage: stage, repetition: 1)
        let calls = fixture.apiCalls
        let stop = fixture.stopOracle

        #expect(fixture.batchCount == (stage.rowCount + 31) / 32)
        #expect(calls.openCreateEmpty == 1)
        #expect(calls.readControl == 2)
        #expect(calls.beginRecording == 1)
        #expect(calls.appendBatchCalls == fixture.batchCount)
        #expect(calls.stopRecording == 1)
        #expect(calls.reopenVerified == 1)
        #expect(calls.lookupStopReceipt == 1)
        #expect(calls.readPageCalls == stage.queryIntervalCount * stage.pageCountPerInterval)
        #expect(calls.finalClose == 1)
        #expect(calls.closeTotalIncludingReopenVerified == 2)
        #expect(calls.clearHistory == 0)
        #expect(calls.pruneHistory == 0)
        #expect(calls.reconcileSamples == 0)
        #expect(calls.runtimeStartOrCoreLocationCalls == 0)
        #expect(calls.runtimeStopCalls == 0)

        #expect(stop.beginExpectedControlRevision == 0)
        #expect(stop.stopOperationCount == 1)
        #expect(stop.receiptKind == .stop)
        #expect(stop.stopUsesBeginReceiptControlRevision)
        #expect(stop.receiptUsesBeginEpoch)
        #expect(stop.receiptControlRevisionIncrement == 1)
        #expect(stop.activeEpochAfterStopIsNil)
        #expect(stop.snapshotMatchesReceiptAfterReopen)
        #expect(stop.lookupReturnsSameReceiptAfterReopen)
        #expect(!stop.retryOrReconcileOnUncertainOutcome)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ResourceWorkloadStage.allCases)
    func batchesStayBoundedValidAndStrictlyTimed(_ stage: ResourceWorkloadStage) throws {
        let fixture = ResourceWorkloadFixture(stage: stage, repetition: 1)
        var rowCount = 0
        var previousObservedAt: Date?

        for batchIndex in 0..<fixture.batchCount {
            let batch = fixture.batch(at: batchIndex)
            let expectedBatchSize = min(32, stage.rowCount - batchIndex * 32)
            let input = try CaptureBatchInput(samples: batch)
            let batchIDs = Set(batch.map(\.id))
            let allSamplesAreValid = batch.allSatisfy(\.isValid)

            #expect(batch.count == expectedBatchSize)
            #expect(batch.count <= 32)
            #expect(batch.count <= CapturePersistenceLimits.maximumBatchSamples)
            #expect(input.samples.count == batch.count)
            #expect(input.encodedPayloadBytes <= CapturePersistenceLimits.maximumPendingPayloadBytes)
            #expect(allSamplesAreValid)
            #expect(batchIDs.count == batch.count)

            for sample in batch {
                if let previousObservedAt {
                    let timestampsAreStrictlyIncreasing = sample.observedAt > previousObservedAt
                    #expect(timestampsAreStrictlyIncreasing)
                }
                previousObservedAt = sample.observedAt
            }

            rowCount += batch.count
        }

        #expect(rowCount == stage.rowCount)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ResourceWorkloadStage.allCases)
    func pageIntervalsHaveFixedQueryTimesAndExactRows(_ stage: ResourceWorkloadStage) {
        let fixture = ResourceWorkloadFixture(stage: stage, repetition: 1)
        let expectedQueryNowOffset = stage == .h2 ? 604_800.0 : stage.timeWindowSeconds
        let pageLimitFitsSource = ResourceWorkloadFixture.pageLimitRows <= CapturePersistenceLimits.maximumPageRows
        let sourcePagePayloadLimit = CapturePersistenceLimits.maximumPagePayloadBytes

        #expect(fixture.pageIntervalCount == stage.queryIntervalCount)
        #expect(pageLimitFitsSource)
        #expect(sourcePagePayloadLimit == 262_144)

        for intervalIndex in 0..<fixture.pageIntervalCount {
            let page = fixture.pageInterval(at: intervalIndex)
            let expectedStartOffset = stage == .h2 ? Double(intervalIndex * 86_400) : 0
            let expectedEndOffset = expectedStartOffset + stage.timeWindowSeconds
            let expectedPageCount = stage.isHistory ? 12 : 1
            var intervalRowCount = 0

            #expect(page.interval.start == ResourceWorkloadFixture.anchor.addingTimeInterval(expectedStartOffset))
            #expect(page.interval.end == ResourceWorkloadFixture.anchor.addingTimeInterval(expectedEndOffset))
            #expect(page.queryNow == ResourceWorkloadFixture.anchor.addingTimeInterval(expectedQueryNowOffset))
            #expect(page.pageCount == expectedPageCount)

            for pageIndex in 0..<page.pageCount {
                let pageRows = page.rowCount(at: pageIndex)
                let expectedRows: Int
                if stage.isHistory {
                    expectedRows = pageIndex == 11 ? 32 : 128
                } else {
                    expectedRows = 60
                }

                #expect(pageRows == expectedRows)
                #expect(pageRows <= ResourceWorkloadFixture.pageLimitRows)
                intervalRowCount += pageRows
            }

            #expect(intervalRowCount == stage.rowCount / stage.queryIntervalCount)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func indexedSamplesMatchDeterministicUUIDAndGeometryGoldens() {
        let baseline = ResourceWorkloadFixture(stage: .b0, repetition: 1)
        let firstBaseline = baseline.sample(at: 0)
        let lastBaseline = baseline.sample(at: 59)
        let baselineRecordingID = baseline.recordingID.uuidString
        let firstBaselineID = firstBaseline.id.uuidString
        let lastBaselineID = lastBaseline.id.uuidString
        let baselineOptionalMeasurementsAreNil = [
            firstBaseline.altitude,
            firstBaseline.verticalAccuracy,
            firstBaseline.speed,
            firstBaseline.speedAccuracy,
            firstBaseline.course,
            firstBaseline.courseAccuracy
        ].allSatisfy { $0 == nil }

        #expect(baselineRecordingID == "ECF1D4DF-7DBA-538A-BA47-CDE19AEDAA27")
        #expect(firstBaselineID == "9333F1BF-D229-5AD9-8A6B-BAE70AAD6927")
        #expect(lastBaselineID == "CCCB001D-ED53-5006-9F00-3F43CAFD4227")
        #expect(firstBaseline.recordingID == baseline.recordingID)
        #expect(firstBaseline.horizontalAccuracy == 5)
        #expect(baselineOptionalMeasurementsAreNil)
        #expect(firstBaseline.latitude == 0)
        #expect(abs(firstBaseline.observedAt.timeIntervalSince(ResourceWorkloadFixture.anchor)) < 1e-6)
        #expect(abs(lastBaseline.longitude - 0.0005300060176305177) < 1e-15)
        #expect(abs(lastBaseline.observedAt.timeIntervalSince(ResourceWorkloadFixture.anchor) - 590) < 1e-6)
        #expect(!firstBaseline.isStationary)

        let stationary = ResourceWorkloadFixture(stage: .stationary, repetition: 2)
        let repeatedStationary = ResourceWorkloadFixture(stage: .stationary, repetition: 2)
        let anotherRepetition = ResourceWorkloadFixture(stage: .stationary, repetition: 3)
        let firstJitterPoint = stationary.sample(at: 0)
        let eastJitterPoint = stationary.sample(at: 1)
        let nextJitterCyclePoint = stationary.sample(at: 10)

        #expect(firstJitterPoint.id.uuidString == "BF9A340B-DC7E-5DBD-9B4E-4E374AD0419E")
        #expect(firstJitterPoint.id == repeatedStationary.sample(at: 0).id)
        #expect(firstJitterPoint.id != anotherRepetition.sample(at: 0).id)
        #expect(firstJitterPoint.latitude == nextJitterCyclePoint.latitude)
        #expect(firstJitterPoint.longitude == nextJitterCyclePoint.longitude)
        #expect(abs(eastJitterPoint.longitude - 0.000004491576420597608) < 1e-15)
        #expect(firstJitterPoint.isStationary)
        #expect(eastJitterPoint.isStationary)

        let walk = ResourceWorkloadFixture(stage: .walk, repetition: 1)
        let walkBeforePause = walk.sample(at: 29)
        let walkAfterPause = walk.sample(at: 30)
        let walkEndpoint = walk.sample(at: 59)
        let walkPauseHasSameCoordinates = walkBeforePause.latitude == walkAfterPause.latitude
            && walkBeforePause.longitude == walkAfterPause.longitude
        #expect(walkPauseHasSameCoordinates)
        #expect(walkBeforePause.isStationary)
        #expect(walkAfterPause.isStationary)
        #expect(abs(walkBeforePause.latitude - 0.0008983152841195215) < 1e-15)
        #expect(abs(walkBeforePause.longitude - 0.001796630568239043) < 1e-15)
        #expect(abs(walkEndpoint.latitude - 0.001796630568239043) < 1e-15)
        #expect(abs(walkEndpoint.longitude - 0.003593261136478086) < 1e-15)

        let drive = ResourceWorkloadFixture(stage: .drive, repetition: 1)
        let firstDriveStop = drive.sample(at: 20)
        let firstDriveStopEnd = drive.sample(at: 21)
        let secondDriveStop = drive.sample(at: 40)
        let secondDriveStopEnd = drive.sample(at: 41)
        let driveEndpoint = drive.sample(at: 59)
        let firstDriveStopHasSameCoordinates = firstDriveStop.latitude == firstDriveStopEnd.latitude
            && firstDriveStop.longitude == firstDriveStopEnd.longitude
        let secondDriveStopHasSameCoordinates = secondDriveStop.latitude == secondDriveStopEnd.latitude
            && secondDriveStop.longitude == secondDriveStopEnd.longitude
        #expect(firstDriveStopHasSameCoordinates)
        #expect(secondDriveStopHasSameCoordinates)
        #expect(firstDriveStop.isStationary)
        #expect(firstDriveStopEnd.isStationary)
        #expect(secondDriveStop.isStationary)
        #expect(secondDriveStopEnd.isStationary)
        #expect(abs(firstDriveStop.longitude - 0.015759917265254764) < 1e-15)
        #expect(abs(secondDriveStop.latitude - 0.008983152841195214) < 1e-15)
        #expect(abs(secondDriveStop.longitude - 0.021748685826051575) < 1e-15)
        #expect(abs(driveEndpoint.longitude - 0.035932611364780855) < 1e-15)

        let history = ResourceWorkloadFixture(stage: .h2, repetition: 5)
        let lastHistorySample = history.sample(at: 10_079)
        let historyRecordingID = history.recordingID.uuidString
        let lastHistorySampleID = lastHistorySample.id.uuidString

        #expect(historyRecordingID == "BF4076BD-A05C-51DD-9E77-4BBB8DB8E591")
        #expect(lastHistorySampleID == "B7F8A6DA-ABCA-50D4-BA70-D062D9E1E8BC")
        #expect(abs(lastHistorySample.latitude - 0.0003750466311199002) < 1e-15)
        #expect(abs(lastHistorySample.longitude - 0.00013250150440762942) < 1e-15)
        #expect(abs(lastHistorySample.observedAt.timeIntervalSince(ResourceWorkloadFixture.anchor) - 604_740) < 1e-6)
        #expect(!lastHistorySample.isStationary)
    }
}
