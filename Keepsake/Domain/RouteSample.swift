import CoreLocation
import Foundation

struct RouteSample: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let recordingID: UUID
    let observedAt: Date
    let latitude: Double
    let longitude: Double
    let horizontalAccuracy: Double
    let altitude: Double?
    let verticalAccuracy: Double?
    let speed: Double?
    let speedAccuracy: Double?
    let course: Double?
    let courseAccuracy: Double?
    let isStationary: Bool

    init(
        id: UUID = UUID(),
        recordingID: UUID,
        observedAt: Date,
        latitude: Double,
        longitude: Double,
        horizontalAccuracy: Double,
        altitude: Double? = nil,
        verticalAccuracy: Double? = nil,
        speed: Double? = nil,
        speedAccuracy: Double? = nil,
        course: Double? = nil,
        courseAccuracy: Double? = nil,
        isStationary: Bool
    ) {
        self.id = id
        self.recordingID = recordingID
        self.observedAt = observedAt
        self.latitude = latitude
        self.longitude = longitude
        self.horizontalAccuracy = horizontalAccuracy
        self.altitude = altitude
        self.verticalAccuracy = verticalAccuracy
        self.speed = speed
        self.speedAccuracy = speedAccuracy
        self.course = course
        self.courseAccuracy = courseAccuracy
        self.isStationary = isStationary
    }

    init(location: CLLocation, recordingID: UUID, isStationary: Bool) {
        self.init(
            recordingID: recordingID,
            observedAt: location.timestamp,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            horizontalAccuracy: location.horizontalAccuracy,
            altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
            verticalAccuracy: Self.validMeasurement(location.verticalAccuracy),
            speed: Self.validMeasurement(location.speed),
            speedAccuracy: Self.validMeasurement(location.speedAccuracy),
            course: location.course >= 0 ? location.course : nil,
            courseAccuracy: Self.validMeasurement(location.courseAccuracy),
            isStationary: isStationary
        )
    }

    var isValid: Bool {
        observedAt.timeIntervalSince1970.isFinite
            && latitude.isFinite
            && (-90...90).contains(latitude)
            && longitude.isFinite
            && (-180...180).contains(longitude)
            && horizontalAccuracy.isFinite
            && horizontalAccuracy >= 0
            && (verticalAccuracy.map { $0 >= 0 } ?? true)
            && (speed.map { $0 >= 0 } ?? true)
            && (speedAccuracy.map { $0 >= 0 } ?? true)
            && (course.map { (0.0...360.0).contains($0) } ?? true)
            && (courseAccuracy.map { $0 >= 0 } ?? true)
            && [altitude, verticalAccuracy, speed, speedAccuracy, course, courseAccuracy]
                .compactMap { $0 }
                .allSatisfy(\.isFinite)
    }

    var fingerprint: RouteSampleFingerprint {
        RouteSampleFingerprint(observedAt: observedAt, latitude: latitude, longitude: longitude)
    }

    private static func validMeasurement(_ value: Double) -> Double? {
        value.isFinite && value >= 0 ? value : nil
    }
}

struct RouteSampleFingerprint: Hashable, Sendable {
    let observedAt: Date
    let latitude: Double
    let longitude: Double
}
