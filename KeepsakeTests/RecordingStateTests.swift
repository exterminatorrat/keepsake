import Testing
@testable import Keepsake

struct RecordingStateTests {
    @Test func recordingStateTracksPermissionAndFixTransitions() {
        let awaitingPermission = LocationCapabilities(
            servicesEnabled: true,
            authorization: .notDetermined,
            fullAccuracy: true
        )
        let foregroundOnly = LocationCapabilities(
            servicesEnabled: true,
            authorization: .whileInUse,
            fullAccuracy: false
        )
        let backgroundAllowed = LocationCapabilities(
            servicesEnabled: true,
            authorization: .always,
            fullAccuracy: true
        )

        #expect(RecorderStateMachine.phase(recordingRequested: false, capabilities: backgroundAllowed, hasFix: true) == .stopped)
        #expect(RecorderStateMachine.phase(recordingRequested: true, capabilities: awaitingPermission, hasFix: false) == .requestingPermission)
        #expect(RecorderStateMachine.phase(recordingRequested: true, capabilities: foregroundOnly, hasFix: false) == .waitingForFix)
        #expect(RecorderStateMachine.phase(recordingRequested: true, capabilities: foregroundOnly, hasFix: true) == .recording)
        #expect(RecorderStateMachine.phase(recordingRequested: true, capabilities: backgroundAllowed, hasFix: true) == .recording)
        #expect(RecorderStateMachine.phase(
            recordingRequested: true,
            capabilities: LocationCapabilities(servicesEnabled: false, authorization: .always, fullAccuracy: true),
            hasFix: false
        ) == .servicesDisabled)
        #expect(RecorderStateMachine.phase(
            recordingRequested: true,
            capabilities: LocationCapabilities(servicesEnabled: true, authorization: .denied, fullAccuracy: false),
            hasFix: false
        ) == .permissionDenied)
    }
}
