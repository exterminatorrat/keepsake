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
        let admittedOutOfOrderMovement = admission.shouldAdmit(sample(
            recordingID: recordingID,
            second: 11.5,
            latitude: latitude(northMeters: 100),
            stationary: false
        ))
        #expect(admittedOutOfOrderMovement)
        let rejectedAfterOutOfOrderSample = admission.shouldAdmit(
            sample(recordingID: recordingID, second: 13))
        #expect(!rejectedAfterOutOfOrderSample)
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
