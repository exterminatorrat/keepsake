import Foundation

enum LocalCaptureWriteAdmissionMode: Equatable, Sendable {
    case allUpdates
    case boundedMovementStationary
}

struct LocalCaptureWriteAdmission: Sendable {
    static let minimumMovementMeters = 25.0
    static let reliableAccuracyBoundaryMeters = RouteHistory.maximumRouteAccuracy
    static let movingHeartbeat: TimeInterval = 15
    static let stationaryHeartbeat: TimeInterval = 60

    private let mode: LocalCaptureWriteAdmissionMode
    private var lastAdmittedSample: RouteSample?
    private var lastObservedAt: Date?

    init(mode: LocalCaptureWriteAdmissionMode = .allUpdates) {
        self.mode = mode
    }

    mutating func shouldAdmit(_ sample: RouteSample) -> Bool {
        guard mode == .boundedMovementStationary else {
            return true
        }
        guard sample.isValid else {
            return true
        }
        guard let lastAdmittedSample else {
            self.lastAdmittedSample = sample
            lastObservedAt = sample.observedAt
            return true
        }
        guard sample.recordingID == lastAdmittedSample.recordingID else {
            self.lastAdmittedSample = sample
            lastObservedAt = sample.observedAt
            return true
        }
        guard let lastObservedAt, sample.observedAt > lastObservedAt else {
            return true
        }
        self.lastObservedAt = sample.observedAt

        let elapsed = sample.observedAt.timeIntervalSince(lastAdmittedSample.observedAt)
        guard elapsed.isFinite else {
            return true
        }

        let crossedStationaryBoundary = sample.isStationary != lastAdmittedSample.isStationary
        let crossedAccuracyBoundary = isReliable(sample) != isReliable(lastAdmittedSample)
        let movementBoundary = max(
            Self.minimumMovementMeters,
            max(sample.horizontalAccuracy, lastAdmittedSample.horizontalAccuracy)
        )
        let heartbeat = sample.isStationary ? Self.stationaryHeartbeat : Self.movingHeartbeat

        guard crossedStationaryBoundary
                || crossedAccuracyBoundary
                || elapsed >= heartbeat
                || distance(from: lastAdmittedSample, to: sample) >= movementBoundary else {
            return false
        }

        self.lastAdmittedSample = sample
        return true
    }

    private func isReliable(_ sample: RouteSample) -> Bool {
        sample.horizontalAccuracy <= Self.reliableAccuracyBoundaryMeters
    }

    private func distance(from first: RouteSample, to second: RouteSample) -> Double {
        let firstLatitude = radians(first.latitude)
        let secondLatitude = radians(second.latitude)
        let latitudeDelta = secondLatitude - firstLatitude
        let longitudeDelta = radians(second.longitude - first.longitude)
        let latitudeTerm = sin(latitudeDelta / 2)
        let longitudeTerm = sin(longitudeDelta / 2)
        let haversine = latitudeTerm * latitudeTerm
            + cos(firstLatitude) * cos(secondLatitude) * longitudeTerm * longitudeTerm
        return 2 * 6_371_008.8 * atan2(sqrt(haversine), sqrt(max(0, 1 - haversine)))
    }

    private func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}
