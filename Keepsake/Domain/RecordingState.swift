import Foundation

enum LocationAuthorization: Equatable, Sendable {
    case notDetermined
    case whileInUse
    case always
    case denied
    case restricted

    var title: String {
        switch self {
        case .notDetermined: "Not requested"
        case .whileInUse: "While Using"
        case .always: "Always"
        case .denied: "Denied"
        case .restricted: "Restricted"
        }
    }
}

struct LocationCapabilities: Equatable, Sendable {
    let servicesEnabled: Bool
    let authorization: LocationAuthorization
    let fullAccuracy: Bool
}

enum RecorderPhase: Equatable, Sendable {
    case stopped
    case servicesDisabled
    case requestingPermission
    case permissionDenied
    case waitingForFix
    case recording

    var title: String {
        switch self {
        case .stopped: "Not recording"
        case .servicesDisabled: "Location Services are off"
        case .requestingPermission: "Waiting for location permission"
        case .permissionDenied: "Location permission is unavailable"
        case .waitingForFix: "Recording · waiting for a fix"
        case .recording: "Recording locally"
        }
    }

    var symbol: String {
        switch self {
        case .stopped: "pause.circle"
        case .servicesDisabled, .permissionDenied: "location.slash"
        case .requestingPermission, .waitingForFix: "location.circle"
        case .recording: "record.circle"
        }
    }
}

enum RecorderStateMachine {
    static func phase(
        recordingRequested: Bool,
        capabilities: LocationCapabilities,
        hasFix: Bool
    ) -> RecorderPhase {
        guard recordingRequested else {
            return .stopped
        }

        guard capabilities.servicesEnabled else {
            return .servicesDisabled
        }

        switch capabilities.authorization {
        case .notDetermined:
            return .requestingPermission
        case .denied, .restricted:
            return .permissionDenied
        case .whileInUse, .always:
            return hasFix ? .recording : .waitingForFix
        }
    }
}
