import Foundation
import Testing
@testable import Keepsake

struct LocalCaptureWriteAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func allUpdatesModeAdmitsEveryObservation() {
        var admission = LocalCaptureWriteAdmission()
        let recordingID = UUID()
        let invalid = sample(recordingID: recordingID, second: 1, latitude: 91)
        let duplicate = sample(recordingID: recordingID, second: 1)

        let admittedInvalidSample = admission.shouldAdmit(invalid)
        #expect(admittedInvalidSample)
        let admittedDuplicateSample = admission.shouldAdmit(duplicate)
        #expect(admittedDuplicateSample)
        let admittedRepeatedDuplicateSample = admission.shouldAdmit(duplicate)
        #expect(admittedRepeatedDuplicateSample)
    }

    @Test(.timeLimit(.minutes(1)))
    func firstSampleAndRecordingChangesStartFreshAnchors() {
        var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let firstRecordingID = UUID()
        let secondRecordingID = UUID()

        let admittedFirstRecordingSample = admission.shouldAdmit(
            sample(recordingID: firstRecordingID, second: 100))
        #expect(admittedFirstRecordingSample)
        let rejectedFirstRecordingNextSample = admission.shouldAdmit(
            sample(recordingID: firstRecordingID, second: 101))
        #expect(!rejectedFirstRecordingNextSample)
        let admittedSecondRecordingSample = admission.shouldAdmit(
            sample(recordingID: secondRecordingID, second: 1))
        #expect(admittedSecondRecordingSample)
        let rejectedSecondRecordingNextSample = admission.shouldAdmit(
            sample(recordingID: secondRecordingID, second: 2))
        #expect(!rejectedSecondRecordingNextSample)
    }

    @Test(.timeLimit(.minutes(1)))
    func stationaryMovementAndAccuracyTransitionsAreAdmitted() {
        var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let recordingID = UUID()

        #expect(LocalCaptureWriteAdmission.reliableAccuracyBoundaryMeters == RouteHistory.maximumRouteAccuracy)

        let admittedStationaryStart = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 0, stationary: true))
        #expect(admittedStationaryStart)
        let admittedMovementTransition = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 1, stationary: false))
        #expect(admittedMovementTransition)
        let admittedStationaryTransition = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 2, stationary: true))
        #expect(admittedStationaryTransition)
        let rejectedAccuracyBoundary = admission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 3,
            accuracy: LocalCaptureWriteAdmission.reliableAccuracyBoundaryMeters,
            stationary: true
        ))
        #expect(!rejectedAccuracyBoundary)
        let admittedAboveAccuracyBoundary = admission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 4,
            accuracy: LocalCaptureWriteAdmission.reliableAccuracyBoundaryMeters + 0.1,
            stationary: true
        ))
        #expect(admittedAboveAccuracyBoundary)
        let admittedAtAccuracyBoundaryAfterRecovery = admission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 5,
            accuracy: LocalCaptureWriteAdmission.reliableAccuracyBoundaryMeters,
            stationary: true
        ))
        #expect(admittedAtAccuracyBoundaryAfterRecovery)
    }

    @Test(.timeLimit(.minutes(1)))
    func heartbeatsAdmitAtExactMovingAndStationaryBoundaries() {
        let recordingID = UUID()
        var movingAdmission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)

        let admittedInitialMovingSample = movingAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 0, stationary: false))
        #expect(admittedInitialMovingSample)
        let rejectedMovingBeforeHeartbeat = movingAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 14, stationary: false))
        #expect(!rejectedMovingBeforeHeartbeat)
        let admittedMovingHeartbeat = movingAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 15, stationary: false))
        #expect(admittedMovingHeartbeat)
        let rejectedMovingBeforeNextHeartbeat = movingAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 29, stationary: false))
        #expect(!rejectedMovingBeforeNextHeartbeat)
        let admittedNextMovingHeartbeat = movingAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 30, stationary: false))
        #expect(admittedNextMovingHeartbeat)

        var stationaryAdmission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let admittedInitialStationarySample = stationaryAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 0))
        #expect(admittedInitialStationarySample)
        let rejectedStationaryBeforeHeartbeat = stationaryAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 59))
        #expect(!rejectedStationaryBeforeHeartbeat)
        let admittedStationaryHeartbeat = stationaryAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 60))
        #expect(admittedStationaryHeartbeat)
    }

    @Test(.timeLimit(.minutes(1)))
    func jitterIsSuppressedUntilMovementExceedsDistanceAndAccuracyBoundaries() {
        let recordingID = UUID()
        var minimumDistanceAdmission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)

        let admittedInitialDistanceSample = minimumDistanceAdmission.shouldAdmit(
            sample(recordingID: recordingID, second: 0, stationary: false))
        #expect(admittedInitialDistanceSample)
        let rejectedSubthresholdMovement = minimumDistanceAdmission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 1,
            latitude: latitude(northMeters: 24.9),
            stationary: false
        ))
        #expect(!rejectedSubthresholdMovement)
        let admittedMovementBeyondThreshold = minimumDistanceAdmission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 2,
            latitude: latitude(northMeters: 25.1),
            stationary: false
        ))
        #expect(admittedMovementBeyondThreshold)

        var accuracyAdmission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let admittedInitialAccuracySample = accuracyAdmission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 0,
            accuracy: 40,
            stationary: false
        ))
        #expect(admittedInitialAccuracySample)
        let rejectedSubthresholdAccuracyChange = accuracyAdmission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 1,
            latitude: latitude(northMeters: 39.9),
            accuracy: 40,
            stationary: false
        ))
        #expect(!rejectedSubthresholdAccuracyChange)
        let admittedAccuracyChangeBeyondThreshold = accuracyAdmission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 2,
            latitude: latitude(northMeters: 40.1),
            accuracy: 40,
            stationary: false
        ))
        #expect(admittedAccuracyChangeBeyondThreshold)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidAndOutOfOrderSamplesAreAdmittedWithoutMovingTheAnchor() {
        var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let recordingID = UUID()

        let admittedInitialSample = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 10))
        #expect(admittedInitialSample)
        let rejectedNearSample = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 11))
        #expect(!rejectedNearSample)
        let admittedInvalidCoordinate = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 100, latitude: 91, stationary: false))
        #expect(admittedInvalidCoordinate)
        let rejectedAfterInvalidCoordinate = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 12))
        #expect(!rejectedAfterInvalidCoordinate)
        let admittedDelayedMovement = admission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 11.5,
            latitude: latitude(northMeters: 100),
            stationary: false
        ))
        #expect(admittedDelayedMovement)
        let admittedOlderSample = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 9))
        #expect(admittedOlderSample)
        let admittedEqualTimestamp = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 11.5))
        #expect(admittedEqualTimestamp)
        let admittedReturnSample = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 13))
        #expect(admittedReturnSample)
    }

    @Test(.timeLimit(.minutes(1)))
    func delayedMovementAndReturnPersistAcrossSuppressedAndRejectedObservations() async throws {
        let parent = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("WriteAdmission-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: parent,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = try RouteStore.createFoundation(
            at: parent.appendingPathComponent("store", isDirectory: true),
            seams: RouteStoreSeams(protectAndVerify: { url, item in
                #if targetEnvironment(simulator)
                try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
                    .completeUntilFirstUserAuthentication
                })
                #else
                try RouteStoreFiles.protectAndVerify(url, as: item)
                #endif
            }, readProtection: { url in
                #if targetEnvironment(simulator)
                return .completeUntilFirstUserAuthentication
                #else
                return try RouteStoreFiles.readProtection(at: url)
                #endif
            })
        )

        do {
            let recordingID = UUID()
            let now = Date(timeIntervalSinceReferenceDate: 100)
            let begin = try await store.beginRecording(
                recordingID: recordingID,
                expectedControlRevision: 0,
                operationID: UUID()
            )
            let observations = [
                sample(recordingID: recordingID, second: 10),
                sample(recordingID: recordingID, second: 12),
                sample(recordingID: recordingID, second: 11.5, latitude: latitude(northMeters: 100), stationary: false),
                sample(recordingID: recordingID, second: 9),
                sample(recordingID: recordingID, second: 11.5),
                sample(recordingID: recordingID, second: 13)
            ]
            var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
            var admissions: [Bool] = []
            var dispositions: [SampleIngestResult] = []

            for observation in observations {
                let admitted = admission.shouldAdmit(observation)
                admissions.append(admitted)
                if admitted {
                    let receipt = try await store.appendBatch(
                        [observation],
                        epoch: begin.epoch,
                        operationID: UUID(),
                        now: now
                    )
                    #expect(receipt.epoch == begin.epoch)
                    #expect(receipt.items.count == 1)
                    #expect(receipt.items.first?.sampleID == observation.id)
                    dispositions.append(contentsOf: receipt.items.map(\.disposition))
                }
            }

            #expect(admissions == [true, false, true, true, true, true])
            #expect(dispositions == [.stored, .stored, .outOfOrder, .outOfOrder, .stored])
            let stop = try await store.stopRecording(
                epoch: begin.epoch,
                expectedControlRevision: begin.controlRevision,
                operationID: UUID()
            )
            let page = try await store.readPage(
                interval: CapturePageInterval(start: Date(timeIntervalSinceReferenceDate: 0), end: now),
                now: now,
                limit: 128,
                cursor: nil
            )
            #expect(page.items.map(\.sample) == [observations[0], observations[2], observations[5]])
            #expect(page.items.map(\.sequence) == [1, 2, 3])
            #expect(page.nextCursor == nil)
            let control = try await store.readControl()
            #expect(control.activeEpoch == nil)
            #expect(control.lastControlReceipt == stop)
            await store.close()
        } catch {
            await store.close()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func longStationarySequenceUsesOnlySixtySecondHeartbeats() {
        var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let recordingID = UUID()
        var admittedCount = 0

        for second in stride(from: 0, through: 1_795, by: 5) {
            if admission.shouldAdmit(sample(recordingID: recordingID, second: TimeInterval(second))) {
                admittedCount += 1
            }
        }

        #expect(admittedCount == 30)
    }

    @Test(.timeLimit(.minutes(1)))
    func longMovingSequenceBoundsSuppressionToFifteenSecondHeartbeats() {
        var admission = LocalCaptureWriteAdmission(mode: .boundedMovementStationary)
        let recordingID = UUID()
        var admittedCount = 0

        for second in 0...1_800 {
            let eastMeters = Double(second) * 0.5
            let update = sample(
                recordingID: recordingID,
                second: TimeInterval(second),
                longitude: longitude(eastMeters: eastMeters),
                stationary: false
            )
            if admission.shouldAdmit(update) {
                admittedCount += 1
            }
        }

        #expect(admittedCount == 121)
    }
}

private func sample(
    recordingID: UUID,
    second: TimeInterval,
    latitude: Double = 0,
    longitude: Double = 0,
    accuracy: Double = 5,
    stationary: Bool = true
) -> RouteSample {
    RouteSample(
        recordingID: recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: second),
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracy: accuracy,
        isStationary: stationary
    )
}

private func latitude(northMeters: Double) -> Double {
    northMeters / 6_371_008.8 * 180 / .pi
}

private func longitude(eastMeters: Double) -> Double {
    eastMeters / 6_371_008.8 * 180 / .pi
}
