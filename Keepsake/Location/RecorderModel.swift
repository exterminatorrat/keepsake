import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class RecorderModel {
    var samples: [RouteSample] = []
    var capabilities: LocationCapabilities
    var isRecordingRequested = false
    var locationMessage: String?
    var isStationary = false
    var isWaitingForLocation = false
    var storageMessage: String?
    var didRecoverIncompleteTail = false
    var alwaysAuthorizationDenied = false
    var isRequestingAlwaysAccess = false
    var invalidSampleCount = 0
    var duplicateSampleCount = 0
    var outOfOrderSampleCount = 0

    @ObservationIgnored private let repository: RouteRepository
    @ObservationIgnored private let authorizationObserver: LocationAuthorizationObserver
    @ObservationIgnored private var locationTask: Task<Void, Never>?
    @ObservationIgnored private var serviceDiagnosticsTask: Task<Void, Never>?
    @ObservationIgnored private var serviceSession: CLServiceSession?
    @ObservationIgnored private var backgroundActivitySession: CLBackgroundActivitySession?
    @ObservationIgnored private var recordingID: UUID?

    init(repository: RouteRepository = .local()) {
        self.repository = repository
        let observer = LocationAuthorizationObserver()
        authorizationObserver = observer
        capabilities = observer.capabilities
        observer.onChange = { [weak self] in
            self?.updatePermissions()
        }

        Task { [weak self] in
            await self?.loadHistory()
        }
    }

    var phase: RecorderPhase {
        RecorderStateMachine.phase(
            recordingRequested: isRecordingRequested,
            capabilities: capabilities,
            hasFix: samples.last != nil && !isWaitingForLocation
        )
    }

    var rejectedSampleCount: Int {
        invalidSampleCount + duplicateSampleCount + outOfOrderSampleCount
    }

    var backgroundDescription: String {
        switch capabilities.authorization {
        case .always:
            "Always access is allowed. iOS can still delay or stop updates."
        case .whileInUse:
            "While Using access. An active recording can continue in a visible background session."
        case .notDetermined:
            "Start a recording to choose location access."
        case .denied, .restricted:
            "Background recording is unavailable until location access is restored."
        }
    }

    func startRecording() {
        guard !isRecordingRequested, storageMessage == nil else {
            return
        }

        isRecordingRequested = true
        recordingID = UUID()
        locationMessage = nil
        isStationary = false
        isWaitingForLocation = false

        if capabilities.authorization == .notDetermined {
            authorizationObserver.requestWhenInUseAuthorization()
            return
        }

        startLocationUpdatesIfAllowed()
    }

    func stopRecording() {
        isRecordingRequested = false
        recordingID = nil
        isStationary = false
        isWaitingForLocation = false
        stopLocationUpdates()
        serviceDiagnosticsTask?.cancel()
        serviceDiagnosticsTask = nil
        serviceSession?.invalidate()
        serviceSession = nil
        alwaysAuthorizationDenied = false
        isRequestingAlwaysAccess = false
    }

    func requestAlwaysAccess() {
        guard isRecordingRequested,
              capabilities.authorization == .whileInUse,
              !alwaysAuthorizationDenied else {
            return
        }

        alwaysAuthorizationDenied = false
        isRequestingAlwaysAccess = true
        startAlwaysSession()
    }

    func refreshPermissions() {
        authorizationObserver.refreshServicesEnabled()
        updatePermissions()
    }

    func expireHistory(at now: Date = .now) {
        let cutoff = now.addingTimeInterval(-TimeInterval(RouteRepository.retentionDays) * 24 * 60 * 60)
        samples = RouteHistory.retainedSamples(samples, after: cutoff)
    }

    private func updatePermissions() {
        capabilities = authorizationObserver.capabilities

        if capabilities.authorization == .always {
            alwaysAuthorizationDenied = false
            isRequestingAlwaysAccess = false
        } else if capabilities.authorization == .denied || capabilities.authorization == .restricted {
            serviceDiagnosticsTask?.cancel()
            serviceDiagnosticsTask = nil
            serviceSession?.invalidate()
            serviceSession = nil
            isRequestingAlwaysAccess = false
        }

        if isRecordingRequested {
            if !capabilities.servicesEnabled
                || capabilities.authorization == .denied
                || capabilities.authorization == .restricted {
                stopLocationUpdates()
            } else {
                startLocationUpdatesIfAllowed()
            }
        }
    }

    func clearHistory() {
        Task { [weak self] in
            guard let self else {
                return
            }

            do {
                try await repository.clear()
                samples = []
                didRecoverIncompleteTail = false
                storageMessage = nil
            } catch {
                storageMessage = "Local history could not be cleared. No route data was sent."
            }
        }
    }

    private func loadHistory() async {
        do {
            let result = try await repository.load()
            samples = result.samples
            didRecoverIncompleteTail = result.recoveredIncompleteTail
        } catch RouteStorageError.backupExclusionFailed {
            storageMessage = "Local history could not be excluded from device backups. Recording is paused to protect privacy."
        } catch {
            storageMessage = "Local history could not be read. Recording is paused to protect existing data."
        }
    }

    private func startLocationUpdatesIfAllowed() {
        guard isRecordingRequested,
              capabilities.servicesEnabled,
              capabilities.authorization == .whileInUse || capabilities.authorization == .always,
              locationTask == nil else {
            return
        }

        if capabilities.authorization == .always && serviceSession == nil {
            startAlwaysSession()
        }

        guard let recordingID else {
            return
        }

        backgroundActivitySession = CLBackgroundActivitySession()
        isWaitingForLocation = true
        locationTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates(.default) {
                    guard !Task.isCancelled, let self else {
                        return
                    }

                    self.isStationary = update.stationary

                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.refreshPermissions()
                        continue
                    }

                    if let location = update.location {
                        await self.record(location, recordingID: recordingID, isStationary: update.stationary)
                    } else if update.locationUnavailable {
                        self.isWaitingForLocation = true
                    }
                }
            } catch {
                self?.stopAfterLocationFailure(for: recordingID)
            }
        }
    }

    private func startAlwaysSession() {
        serviceDiagnosticsTask?.cancel()
        serviceSession?.invalidate()
        let session = CLServiceSession(authorization: .always)
        serviceSession = session
        serviceDiagnosticsTask = Task { [weak self] in
            do {
                for try await diagnostic in session.diagnostics {
                    guard !Task.isCancelled, let self else {
                        return
                    }

                    if diagnostic.alwaysAuthorizationDenied {
                        self.alwaysAuthorizationDenied = true
                        self.isRequestingAlwaysAccess = false
                        session.invalidate()
                        self.serviceSession = nil
                        return
                    }

                    if !diagnostic.authorizationRequestInProgress,
                       self.capabilities.authorization == .always {
                        self.isRequestingAlwaysAccess = false
                    }
                }
            } catch {
                if !Task.isCancelled {
                    self?.isRequestingAlwaysAccess = false
                }
            }
        }
    }

    private func record(_ location: CLLocation, recordingID: UUID, isStationary: Bool) async {
        guard self.recordingID == recordingID else {
            return
        }

        let sample = RouteSample(location: location, recordingID: recordingID, isStationary: isStationary)
        let now = Date.now
        do {
            let result = try await repository.append(sample, now: now)
            guard self.recordingID == recordingID else {
                return
            }

            expireHistory(at: now)
            switch result {
            case .stored:
                samples.append(sample)
                isWaitingForLocation = false
            case .duplicate:
                duplicateSampleCount = min(duplicateSampleCount + 1, 999)
            case .outOfOrder:
                outOfOrderSampleCount = min(outOfOrderSampleCount + 1, 999)
            case .invalid, .expired:
                invalidSampleCount = min(invalidSampleCount + 1, 999)
            }
        } catch {
            guard self.recordingID == recordingID else {
                return
            }

            storageMessage = "A location sample could not be saved. Recording stopped to avoid losing more data."
            stopRecording()
        }
    }

    private func stopAfterLocationFailure(for recordingID: UUID) {
        guard self.recordingID == recordingID else {
            return
        }

        locationMessage = "Location updates stopped unexpectedly. Start a new recording to resume."
        stopRecording()
    }

    private func stopLocationUpdates() {
        locationTask?.cancel()
        locationTask = nil
        backgroundActivitySession?.invalidate()
        backgroundActivitySession = nil
    }
}
