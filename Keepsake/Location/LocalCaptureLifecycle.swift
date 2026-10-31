import CoreLocation
import Foundation

enum LocalCaptureLifecycleError: Error, Equatable, Sendable {
    case notStopped
    case notResumeRequired
    case permissionRequestPending
    case locationServicesDisabled
    case authorizationDenied
}

enum LocalCaptureLifecycleInterruption: Equatable, Sendable {
    case authorizationLost
    case locationServicesDisabled
    case locationStreamEnded
    case locationStreamFailed(String)
    case alwaysAuthorizationDenied
    case serviceSessionEnded
    case serviceSessionFailed(String)
    case persistenceFailed(String)
}

@MainActor
final class LocalCaptureLifecycle {
    fileprivate nonisolated let coordinator: LocalCaptureCoordinator
    private let authorization: any RecorderAuthorizationObservation

    private(set) var lastError: String?
    private(set) var lastInterruption: LocalCaptureLifecycleInterruption?

    var state: LocalCaptureCoordinatorState {
        coordinator.state
    }

    var isStorageReady: Bool {
        coordinator.isStorageReady
    }

    var isAcceptingSamples: Bool {
        coordinator.isAcceptingSamples
    }

    var pendingSampleCount: Int {
        coordinator.pendingSampleCount
    }

    var pendingEncodedPayloadBytes: Int {
        coordinator.pendingEncodedPayloadBytes
    }

    private init(
        persistence: any LocalCapturePersistence,
        reopenVerifiedStore: @escaping @Sendable () async throws -> any LocalCapturePersistence,
        locationUpdateSource: any RecorderLocationUpdateSource,
        authorization: any RecorderAuthorizationObservation,
        runtimePlatform: any RecorderRuntimePlatform,
        now: @escaping @Sendable () -> Date,
        isLocationServicesEnabled: @escaping @MainActor () async -> Bool
    ) {
        self.authorization = authorization
        let runtime = LocalCaptureLifecycleRuntime(
            locationUpdateSource: locationUpdateSource,
            authorization: authorization,
            runtimePlatform: runtimePlatform,
            now: now,
            isLocationServicesEnabled: isLocationServicesEnabled
        )
        coordinator = LocalCaptureCoordinator(
            persistence: persistence,
            runtime: runtime,
            reopenVerifiedStore: reopenVerifiedStore
        )
        runtime.attach(self)

        authorization.onChange = { [weak self] in
            self?.authorizationChanged()
        }
    }

    deinit {
        let coordinator = coordinator
        Task { @MainActor in
            if case .active(let epoch, let generation, _) = coordinator.state {
                coordinator.runtimeInterrupted(epoch: epoch, generation: generation)
            }
        }
    }

    static func open(
        persistence: any LocalCapturePersistence,
        reopenVerifiedStore: @escaping @Sendable () async throws -> any LocalCapturePersistence,
        locationUpdateSource: any RecorderLocationUpdateSource,
        authorization: any RecorderAuthorizationObservation,
        runtimePlatform: any RecorderRuntimePlatform,
        now: @escaping @Sendable () -> Date = { .now },
        isLocationServicesEnabled: @escaping @MainActor () async -> Bool = {
            await SystemLocationServicesStatusSource().servicesEnabled()
        }
    ) async throws -> LocalCaptureLifecycle {
        let lifecycle = LocalCaptureLifecycle(
            persistence: persistence,
            reopenVerifiedStore: reopenVerifiedStore,
            locationUpdateSource: locationUpdateSource,
            authorization: authorization,
            runtimePlatform: runtimePlatform,
            now: now,
            isLocationServicesEnabled: isLocationServicesEnabled
        )
        _ = try await lifecycle.coordinator.refreshControl()
        return lifecycle
    }

    func startNewRecording(recordingID: UUID) async throws -> CaptureEpoch {
        try await perform {
            guard case .stopped = self.coordinator.state else {
                throw LocalCaptureLifecycleError.notStopped
            }
            try self.validateAuthorization()
            return try await self.coordinator.startRecording(recordingID: recordingID)
        }
    }

    func resume() async throws -> CaptureEpoch {
        try await perform {
            guard case .resumeRequired(let epoch, _) = self.coordinator.state else {
                throw LocalCaptureLifecycleError.notResumeRequired
            }
            try self.validateAuthorization()
            return try await self.coordinator.startRecording(recordingID: epoch.recordingID)
        }
    }

    func stop() async throws -> LocalCaptureStopResult {
        try await perform {
            try await self.coordinator.stopRecording()
        }
    }

    func retryStop() async throws -> LocalCaptureStopResult {
        try await perform {
            try await self.coordinator.retryStop()
        }
    }

    func reconcileUncertain() async throws -> LocalCaptureReconciliationResult {
        try await perform {
            try await self.coordinator.reconcileUncertain()
        }
    }

    fileprivate func runtimeEnded(
        epoch: CaptureEpoch,
        generation: UUID,
        interruption: LocalCaptureLifecycleInterruption
    ) {
        guard coordinator.runtimeInterrupted(epoch: epoch, generation: generation) else {
            return
        }
        lastInterruption = interruption
    }

    private func authorizationChanged() {
        guard case .active(let epoch, let generation, _) = coordinator.state else {
            return
        }

        guard let interruption = currentAuthorizationInterruption else {
            return
        }

        runtimeEnded(epoch: epoch, generation: generation, interruption: interruption)
    }

    fileprivate var currentAuthorizationInterruption: LocalCaptureLifecycleInterruption? {
        let capabilities = authorization.capabilities
        guard capabilities.servicesEnabled else {
            return .locationServicesDisabled
        }
        switch capabilities.authorization {
        case .whileInUse, .always:
            return nil
        case .notDetermined, .denied, .restricted:
            return .authorizationLost
        }
    }

    private func validateAuthorization() throws {
        authorization.refreshServicesEnabled()
        let capabilities = authorization.capabilities
        guard capabilities.servicesEnabled else {
            throw LocalCaptureLifecycleError.locationServicesDisabled
        }

        switch capabilities.authorization {
        case .whileInUse, .always:
            return
        case .notDetermined:
            authorization.requestWhenInUseAuthorization()
            throw LocalCaptureLifecycleError.permissionRequestPending
        case .denied, .restricted:
            throw LocalCaptureLifecycleError.authorizationDenied
        }
    }

    private func perform<Value>(_ operation: @MainActor () async throws -> Value) async throws -> Value {
        lastError = nil
        do {
            return try await operation()
        } catch {
            lastError = String(describing: error)
            throw error
        }
    }
}

@MainActor
private final class LocalCaptureLifecycleRuntime: LocalCaptureRuntimeControl {
    private let locationUpdateSource: any RecorderLocationUpdateSource
    private let authorization: any RecorderAuthorizationObservation
    private let runtimePlatform: any RecorderRuntimePlatform
    private let now: @Sendable () -> Date
    private let isLocationServicesEnabled: @MainActor () async -> Bool
    private weak var lifecycle: LocalCaptureLifecycle?

    init(
        locationUpdateSource: any RecorderLocationUpdateSource,
        authorization: any RecorderAuthorizationObservation,
        runtimePlatform: any RecorderRuntimePlatform,
        now: @escaping @Sendable () -> Date,
        isLocationServicesEnabled: @escaping @MainActor () async -> Bool
    ) {
        self.locationUpdateSource = locationUpdateSource
        self.authorization = authorization
        self.runtimePlatform = runtimePlatform
        self.now = now
        self.isLocationServicesEnabled = isLocationServicesEnabled
    }

    func attach(_ lifecycle: LocalCaptureLifecycle) {
        self.lifecycle = lifecycle
    }

    func start(epoch: CaptureEpoch, generation: UUID) -> any LocalCaptureRuntimeHandle {
        guard let lifecycle else {
            preconditionFailure("Lifecycle runtime started before attachment")
        }

        let session = LocalCaptureRuntimeSession(
            epoch: epoch,
            coordinator: lifecycle.coordinator,
            locationUpdateSource: locationUpdateSource,
            authorization: authorization,
            runtimePlatform: runtimePlatform,
            isLocationServicesEnabled: isLocationServicesEnabled,
            now: now,
            onTermination: { [weak lifecycle] interruption in
                guard let lifecycle else {
                    return
                }
                lifecycle.runtimeEnded(epoch: epoch, generation: generation, interruption: interruption)
            }
        )
        session.start()
        return session
    }
}

@MainActor
private final class LocalCaptureRuntimeSession: LocalCaptureRuntimeHandle {
    private nonisolated let taskLifetime = RecorderTaskLifetime()

    private let epoch: CaptureEpoch
    private weak var coordinator: LocalCaptureCoordinator?
    private let locationUpdateSource: any RecorderLocationUpdateSource
    private let authorization: any RecorderAuthorizationObservation
    private let runtimePlatform: any RecorderRuntimePlatform
    private let isLocationServicesEnabled: @MainActor () async -> Bool
    private var resources: LocalCaptureRuntimeResources?
    private let now: @Sendable () -> Date
    private let onTermination: @MainActor (LocalCaptureLifecycleInterruption) -> Void
    private var isAcceptingUpdates = true

    init(
        epoch: CaptureEpoch,
        coordinator: LocalCaptureCoordinator,
        locationUpdateSource: any RecorderLocationUpdateSource,
        authorization: any RecorderAuthorizationObservation,
        runtimePlatform: any RecorderRuntimePlatform,
        isLocationServicesEnabled: @escaping @MainActor () async -> Bool,
        now: @escaping @Sendable () -> Date,
        onTermination: @escaping @MainActor (LocalCaptureLifecycleInterruption) -> Void
    ) {
        self.epoch = epoch
        self.coordinator = coordinator
        self.locationUpdateSource = locationUpdateSource
        self.authorization = authorization
        self.runtimePlatform = runtimePlatform
        self.isLocationServicesEnabled = isLocationServicesEnabled
        self.now = now
        self.onTermination = onTermination
    }

    deinit {
        taskLifetime.cancelAll()
    }

    func start() {
        let taskLifetime = taskLifetime
        let locationTaskID = UUID()
        let source = locationUpdateSource
        let servicesEnabled = isLocationServicesEnabled
        let locationTask = Task { @MainActor [weak self, taskLifetime, source, servicesEnabled] in
            defer { taskLifetime.finish(locationTaskID) }

            guard !Task.isCancelled else {
                return
            }
            let enabled = await servicesEnabled()
            guard !Task.isCancelled,
                  let resources = self?.makeResources(servicesEnabled: enabled) else {
                return
            }
            defer { resources.close() }

            do {
                try await source.collect { [weak self] update in
                    guard !Task.isCancelled,
                          let self,
                          self.isAcceptingUpdates else {
                        return false
                    }

                    if update.authorizationDenied || update.authorizationDeniedGlobally {
                        self.report(.authorizationLost)
                        return false
                    }

                    guard let location = update.location else {
                        return true
                    }

                    do {
                        let sample = RouteSample(
                            location: location,
                            recordingID: self.epoch.recordingID,
                            isStationary: update.stationary
                        )
                        let input = try CaptureBatchInput(samples: [sample])
                        guard let coordinator = self.coordinator else {
                            return false
                        }
                        _ = try await coordinator.append(input, now: self.now())
                    } catch {
                        guard self.isAcceptingUpdates else {
                            return false
                        }
                        self.report(.persistenceFailed(String(describing: error)))
                        return false
                    }

                    return !Task.isCancelled && self.isAcceptingUpdates
                }

                if !Task.isCancelled, let self, self.isAcceptingUpdates {
                    self.report(.locationStreamEnded)
                }
            } catch {
                if !Task.isCancelled, let self, self.isAcceptingUpdates {
                    self.report(.locationStreamFailed(String(describing: error)))
                }
            }
        }
        taskLifetime.retain(locationTask, for: locationTaskID)
    }

    private func makeResources(servicesEnabled: Bool) -> LocalCaptureRuntimeResources? {
        guard isAcceptingUpdates else {
            return nil
        }
        let capabilities = authorization.capabilities
        guard servicesEnabled && capabilities.servicesEnabled else {
            report(.locationServicesDisabled)
            return nil
        }
        guard capabilities.authorization == .whileInUse || capabilities.authorization == .always else {
            report(.authorizationLost)
            return nil
        }

        let resources = LocalCaptureRuntimeResources(
            backgroundActivity: runtimePlatform.makeBackgroundActivityHandle(),
            serviceSession: capabilities.authorization == .always
                ? runtimePlatform.makeServiceSessionHandle()
                : nil
        )
        self.resources = resources
        if let serviceSession = resources.serviceSession {
            startServiceSession(serviceSession)
        }
        return resources
    }

    private func startServiceSession(_ serviceSession: any RecorderServiceSessionHandle) {
        let taskLifetime = taskLifetime
        let serviceTaskID = UUID()
        let serviceTask = Task { @MainActor [weak self, taskLifetime, serviceSession] in
            defer {
                serviceSession.invalidate()
                taskLifetime.finish(serviceTaskID)
            }

            guard !Task.isCancelled else {
                return
            }

            do {
                try await serviceSession.collectDiagnostics { [weak self] diagnostic in
                    guard !Task.isCancelled,
                          let self,
                          self.isAcceptingUpdates else {
                        return
                    }

                    if diagnostic.alwaysAuthorizationDenied {
                        self.report(.alwaysAuthorizationDenied)
                    }
                }

                if !Task.isCancelled, let self, self.isAcceptingUpdates {
                    self.report(.serviceSessionEnded)
                }
            } catch {
                if !Task.isCancelled, let self, self.isAcceptingUpdates {
                    self.report(.serviceSessionFailed(String(describing: error)))
                }
            }
        }
        taskLifetime.retain(serviceTask, for: serviceTaskID)
    }

    func stop() {
        guard isAcceptingUpdates else {
            return
        }
        isAcceptingUpdates = false
        taskLifetime.cancelAll()
        resources?.close()
    }

    private func report(_ interruption: LocalCaptureLifecycleInterruption) {
        guard isAcceptingUpdates else {
            return
        }
        onTermination(interruption)
    }
}

@MainActor
private final class LocalCaptureRuntimeResources {
    private let backgroundActivity: any RecorderBackgroundActivityHandle
    let serviceSession: (any RecorderServiceSessionHandle)?
    private var isClosed = false

    init(
        backgroundActivity: any RecorderBackgroundActivityHandle,
        serviceSession: (any RecorderServiceSessionHandle)?
    ) {
        self.backgroundActivity = backgroundActivity
        self.serviceSession = serviceSession
    }

    func close() {
        guard !isClosed else {
            return
        }
        isClosed = true
        backgroundActivity.invalidate()
        serviceSession?.invalidate()
    }
}
