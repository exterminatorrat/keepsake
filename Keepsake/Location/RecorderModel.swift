import CoreLocation
import Foundation
import Observation

@MainActor
@Observable
final class RecorderModel {
    var samples: [RouteSample] = []
    var capabilities: LocationCapabilities
    var isRecordingRequested = false
    var isStorageReady = false
    var isClearingHistory = false
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

    @ObservationIgnored private let repository: any RecorderRepository
    @ObservationIgnored private let locationUpdateSource: any RecorderLocationUpdateSource
    @ObservationIgnored private let authorizationObserver: any RecorderAuthorizationObservation
    @ObservationIgnored private let runtimePlatform: any RecorderRuntimePlatform
    @ObservationIgnored private let clock: @Sendable () -> Date
    @ObservationIgnored nonisolated private let taskLifetime = RecorderTaskLifetime()
    @ObservationIgnored private var storageOperation: Task<Void, Never>?
    @ObservationIgnored private var storageRevision = 0
    @ObservationIgnored private var locationRuntime: LocationRuntime?
    @ObservationIgnored private var alwaysAccessSession: AlwaysAccessSession?
    @ObservationIgnored private var recordingID: UUID?
    @ObservationIgnored private var isAwaitingExplicitStart = false

    private struct LocationRuntime {
        let generation: UUID
        let recordingID: UUID
        let backgroundActivitySession: any RecorderBackgroundActivityHandle
        let task: Task<Void, Never>
    }

    private struct AlwaysAccessSession {
        let generation: UUID
        let session: any RecorderServiceSessionHandle
        let task: Task<Void, Never>
    }

    deinit {
        taskLifetime.cancelAll()
    }

    convenience init(repository: RouteRepository = .local()) {
        self.init(
            recorderRepository: RouteRepositoryAdapter(repository: repository),
            locationUpdateSource: LiveRecorderLocationUpdateSource(),
            authorizationObserver: LocationAuthorizationObserver(),
            runtimePlatform: CoreLocationRecorderRuntimePlatform(),
            clock: { .now }
        )
    }

    init(
        recorderRepository: any RecorderRepository,
        locationUpdateSource: any RecorderLocationUpdateSource,
        authorizationObserver: any RecorderAuthorizationObservation,
        runtimePlatform: any RecorderRuntimePlatform,
        clock: @escaping @Sendable () -> Date
    ) {
        self.repository = recorderRepository
        self.locationUpdateSource = locationUpdateSource
        self.authorizationObserver = authorizationObserver
        self.runtimePlatform = runtimePlatform
        self.clock = clock
        capabilities = authorizationObserver.capabilities
        authorizationObserver.onChange = { [weak self] in
            self?.updatePermissions()
        }

        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.loadHistory(revision: 0)
        }
        storageOperation = task
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
        guard !isRecordingRequested,
              isStorageReady,
              !isClearingHistory,
              storageMessage == nil else {
            return
        }

        isRecordingRequested = true
        recordingID = recordingID ?? UUID()
        isAwaitingExplicitStart = true
        locationMessage = nil
        isStationary = false
        isWaitingForLocation = false

        if capabilities.authorization == .denied || capabilities.authorization == .restricted {
            interruptPendingStart(message: "Location access is unavailable. Start again when access is available.")
            return
        }

        if capabilities.authorization == .notDetermined {
            authorizationObserver.requestWhenInUseAuthorization()
            return
        }

        startLocationUpdatesIfAllowed()
    }

    func stopRecording() {
        isRecordingRequested = false
        recordingID = nil
        isAwaitingExplicitStart = false
        isStationary = false
        isWaitingForLocation = false
        stopLocationUpdates()
        stopAlwaysAccessSession()
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
            stopAlwaysAccessSession()
            isRequestingAlwaysAccess = false
        }

        guard isRecordingRequested else {
            return
        }

        let isAuthorized = capabilities.authorization == .whileInUse || capabilities.authorization == .always
        guard capabilities.servicesEnabled && isAuthorized else {
            if let runtime = locationRuntime {
                interruptRecording(
                    for: runtime.generation,
                    message: "Location access changed. Start again when access is available.",
                    preserveRecordingID: true
                )
            } else if isAwaitingExplicitStart,
                      (capabilities.authorization == .denied || capabilities.authorization == .restricted) {
                interruptPendingStart(
                    message: "Location access is unavailable. Start again when access is available."
                )
            }
            return
        }

        guard isAwaitingExplicitStart, locationRuntime == nil else {
            return
        }
        startLocationUpdatesIfAllowed()
    }

    func clearHistory() {
        guard !isClearingHistory else {
            return
        }

        if let runtime = locationRuntime {
            interruptRecording(
                for: runtime.generation,
                message: "Recording stopped because local history is being cleared."
            )
        } else if isRecordingRequested {
            interruptPendingStart(message: "Recording stopped because local history is being cleared.")
        }

        storageRevision += 1
        let revision = storageRevision
        let previousOperation = storageOperation
        isStorageReady = false
        isClearingHistory = true
        storageMessage = nil

        let task = Task { [weak self] in
            await previousOperation?.value
            guard let self, self.storageRevision == revision else {
                return
            }

            do {
                try await self.repository.clear()
                guard self.storageRevision == revision else {
                    return
                }

                self.samples = []
                self.didRecoverIncompleteTail = false
                self.storageMessage = nil
                self.isStorageReady = true
            } catch {
                guard self.storageRevision == revision else {
                    return
                }

                self.storageMessage = "Local history could not be cleared. Storage state is unknown, so recording is paused."
                self.isStorageReady = false
                if let runtime = self.locationRuntime {
                    self.interruptRecording(
                        for: runtime.generation,
                        message: "Recording stopped because local storage is unavailable."
                    )
                }
            }

            self.isClearingHistory = false
        }
        storageOperation = task
    }

    private func loadHistory(revision: Int) async {
        do {
            let result = try await repository.load()
            guard storageRevision == revision else {
                return
            }

            samples = result.samples
            didRecoverIncompleteTail = result.recoveredIncompleteTail
            storageMessage = nil
            isStorageReady = true
        } catch RouteStorageError.backupExclusionFailed {
            guard storageRevision == revision else {
                return
            }

            storageMessage = "Local history could not be excluded from device backups. Recording is paused to protect privacy."
            isStorageReady = false
        } catch {
            guard storageRevision == revision else {
                return
            }

            storageMessage = "Local history could not be read. Recording is paused to protect existing data."
            isStorageReady = false
        }
    }

    private func startLocationUpdatesIfAllowed() {
        guard isRecordingRequested,
              isStorageReady,
              !isClearingHistory,
              capabilities.servicesEnabled,
              capabilities.authorization == .whileInUse || capabilities.authorization == .always,
              locationRuntime == nil,
              let recordingID else {
            return
        }

        if capabilities.authorization == .always && alwaysAccessSession == nil {
            startAlwaysSession()
        }

        let generation = UUID()
        let backgroundActivitySession = runtimePlatform.makeBackgroundActivityHandle()
        let locationUpdateSource = self.locationUpdateSource
        let taskLifetime = self.taskLifetime
        isAwaitingExplicitStart = false
        isWaitingForLocation = true
        let task = Task { [weak self, taskLifetime, backgroundActivitySession] in
            defer {
                taskLifetime.finish(generation)
                backgroundActivitySession.invalidate()
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                try await locationUpdateSource.collect { [weak self] update in
                    guard !Task.isCancelled,
                          let self,
                          self.locationRuntime?.generation == generation else {
                        return false
                    }

                    self.isStationary = update.stationary

                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.refreshPermissions()
                        self.interruptRecording(
                            for: generation,
                            message: "Location access changed. Start again when access is available.",
                            preserveRecordingID: true
                        )
                        return false
                    }

                    if let location = update.location {
                        await self.record(
                            location,
                            recordingID: recordingID,
                            runtimeGeneration: generation,
                            isStationary: update.stationary
                        )
                    } else if update.locationUnavailable {
                        self.isWaitingForLocation = true
                    }

                    return !Task.isCancelled && self.locationRuntime?.generation == generation
                }

                guard !Task.isCancelled else {
                    return
                }
                self?.stopAfterLocationStreamEnd(for: generation)
            } catch {
                guard !Task.isCancelled else {
                    return
                }
                self?.stopAfterLocationFailure(for: generation)
            }
        }
        locationRuntime = LocationRuntime(
            generation: generation,
            recordingID: recordingID,
            backgroundActivitySession: backgroundActivitySession,
            task: task
        )
        taskLifetime.retain(task, for: generation)
    }

    private func startAlwaysSession() {
        stopAlwaysAccessSession()
        let generation = UUID()
        let session = runtimePlatform.makeServiceSessionHandle()
        let taskLifetime = self.taskLifetime
        let task = Task { [weak self, taskLifetime, session] in
            defer {
                taskLifetime.finish(generation)
                session.invalidate()
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                try await session.collectDiagnostics { [weak self] diagnostic in
                    guard !Task.isCancelled,
                          let self,
                          self.alwaysAccessSession?.generation == generation else {
                        return
                    }

                    if diagnostic.alwaysAuthorizationDenied {
                        self.alwaysAuthorizationDenied = true
                        self.isRequestingAlwaysAccess = false
                        self.stopAlwaysAccessSession(for: generation)
                        return
                    }

                    if !diagnostic.authorizationRequestInProgress,
                       self.capabilities.authorization == .always {
                        self.isRequestingAlwaysAccess = false
                    }
                }

                guard !Task.isCancelled,
                      let self,
                      self.alwaysAccessSession?.generation == generation else {
                    return
                }
                self.isRequestingAlwaysAccess = false
                self.stopAlwaysAccessSession(for: generation)
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.alwaysAccessSession?.generation == generation else {
                    return
                }
                self.isRequestingAlwaysAccess = false
                self.stopAlwaysAccessSession(for: generation)
            }
        }
        alwaysAccessSession = AlwaysAccessSession(generation: generation, session: session, task: task)
        taskLifetime.retain(task, for: generation)
    }

    private func record(
        _ location: CLLocation,
        recordingID: UUID,
        runtimeGeneration: UUID,
        isStationary: Bool
    ) async {
        guard locationRuntime?.generation == runtimeGeneration,
              self.recordingID == recordingID,
              isStorageReady,
              !isClearingHistory else {
            return
        }

        let sample = RouteSample(location: location, recordingID: recordingID, isStationary: isStationary)
        let now = clock()
        let revision = storageRevision
        let previousOperation = storageOperation
        isStorageReady = false

        let task = Task { [weak self] in
            await previousOperation?.value
            guard let self,
                  self.storageRevision == revision,
                  !self.isClearingHistory else {
                return
            }

            do {
                let result = try await self.repository.append(sample, now: now)
                guard self.storageRevision == revision else {
                    return
                }

                if self.recordingID == nil || self.recordingID == recordingID {
                    self.expireHistory(at: now)
                    switch result {
                    case .stored:
                        self.samples.append(sample)
                        if self.locationRuntime?.generation == runtimeGeneration {
                            self.isWaitingForLocation = false
                        }
                    case .duplicate:
                        self.duplicateSampleCount = min(self.duplicateSampleCount + 1, 999)
                    case .outOfOrder:
                        self.outOfOrderSampleCount = min(self.outOfOrderSampleCount + 1, 999)
                    case .invalid, .expired:
                        self.invalidSampleCount = min(self.invalidSampleCount + 1, 999)
                    }
                }

                self.isStorageReady = true
            } catch {
                guard self.storageRevision == revision else {
                    return
                }

                self.storageMessage = "A location sample could not be saved. Storage state is unknown, so recording is paused."
                self.isStorageReady = false
                if self.locationRuntime?.generation == runtimeGeneration {
                    self.stopAfterStorageFailure(for: runtimeGeneration)
                }
            }
        }
        storageOperation = task
        await task.value
    }

    private func stopAfterLocationStreamEnd(for generation: UUID) {
        interruptRecording(
            for: generation,
            message: "Location updates ended unexpectedly. Start a new recording to resume."
        )
    }

    private func stopAfterLocationFailure(for generation: UUID) {
        interruptRecording(
            for: generation,
            message: "Location updates stopped unexpectedly. Start a new recording to resume."
        )
    }

    private func stopAfterStorageFailure(for generation: UUID) {
        interruptRecording(
            for: generation,
            message: "Recording stopped because a location sample could not be saved."
        )
    }

    private func interruptRecording(
        for generation: UUID,
        message: String,
        preserveRecordingID: Bool = false
    ) {
        guard let runtime = locationRuntime, runtime.generation == generation else {
            return
        }

        locationMessage = message
        isRecordingRequested = false
        recordingID = preserveRecordingID ? runtime.recordingID : nil
        isAwaitingExplicitStart = false
        isStationary = false
        isWaitingForLocation = false
        stopLocationUpdates(for: generation)
        stopAlwaysAccessSession()
        isRequestingAlwaysAccess = false
    }

    private func interruptPendingStart(message: String) {
        locationMessage = message
        isRecordingRequested = false
        recordingID = nil
        isAwaitingExplicitStart = false
        isStationary = false
        isWaitingForLocation = false
        stopAlwaysAccessSession()
        isRequestingAlwaysAccess = false
    }

    private func stopLocationUpdates(for generation: UUID? = nil) {
        guard let runtime = locationRuntime else {
            return
        }
        if let generation, runtime.generation != generation {
            return
        }

        locationRuntime = nil
        runtime.task.cancel()
        runtime.backgroundActivitySession.invalidate()
    }

    private func stopAlwaysAccessSession(for generation: UUID? = nil) {
        guard let owner = alwaysAccessSession else {
            return
        }
        if let generation, owner.generation != generation {
            return
        }

        alwaysAccessSession = nil
        owner.task.cancel()
        owner.session.invalidate()
    }
}
