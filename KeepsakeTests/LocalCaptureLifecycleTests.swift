import CoreLocation
import Foundation
import Testing
@testable import Keepsake

@MainActor
struct LocalCaptureLifecycleTests {
    @Test(.timeLimit(.minutes(1)))
    func startupRequiresExplicitResumeAndOldCallbacksCannotAppendAfterResume() async throws {
        let store = CoordinatorPersistenceFake()
        let recordingID = UUID()
        let originalBegin = try await store.beginExternally(recordingID: recordingID)
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.notDetermined))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        let lifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )

        #expect(lifecycle.state == .resumeRequired(
            epoch: originalBegin.epoch,
            controlRevision: originalBegin.controlRevision
        ))
        #expect(authorization.requestCount == 0)
        #expect(source.streamCount == 0)
        #expect(platform.backgroundActivityHandles.isEmpty)
        await expectLifecycleError(.permissionRequestPending) {
            try await lifecycle.resume()
        }
        #expect(lifecycle.lastError != nil)
        #expect(authorization.requestCount == 1)
        let beginCallsBeforePermission = await store.beginCallCount()
        #expect(beginCallsBeforePermission == 0)

        authorization.update(capabilities(.whileInUse))
        #expect(lifecycle.state == .resumeRequired(
            epoch: originalBegin.epoch,
            controlRevision: originalBegin.controlRevision
        ))
        #expect(source.streamCount == 0)

        let firstEpoch = try await lifecycle.resume()
        await source.waitForStreamCount(1)
        #expect(firstEpoch.recordingID == recordingID)
        #expect(firstEpoch.revision > originalBegin.epoch.revision)

        let update = makeUpdate(seconds: 1_000)
        let firstCallbackAccepted = await source.deliver(update, to: 0)
        #expect(firstCallbackAccepted)
        let appendCallsAfterUpdate = await store.appendCallCount()
        #expect(appendCallsAfterUpdate == 1)

        source.finish(stream: 0)
        await source.waitForCollectionEnd(stream: 0)
        await waitUntil { lifecycle.state == .resumeRequired(
            epoch: firstEpoch,
            controlRevision: firstEpoch.revision
        ) }
        #expect(lifecycle.lastInterruption == .locationStreamEnded)
        let controlAfterInterruption = try await store.readControl()
        #expect(controlAfterInterruption.activeEpoch == firstEpoch)
        let stopCallsAfterInterruption = await store.stopCallCount()
        #expect(stopCallsAfterInterruption == 0)

        let staleCallbackAccepted = await source.deliver(update, to: 0)
        #expect(!staleCallbackAccepted)
        let appendCallsAfterStaleCallback = await store.appendCallCount()
        #expect(appendCallsAfterStaleCallback == appendCallsAfterUpdate)

        let resumedEpoch = try await lifecycle.resume()
        await source.waitForStreamCount(2)
        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > firstEpoch.revision)
        let oldCallbackAcceptedAfterResume = await source.deliver(update, to: 0)
        #expect(!oldCallbackAcceptedAfterResume)
        let appendCallsAfterResume = await store.appendCallCount()
        #expect(appendCallsAfterResume == appendCallsAfterUpdate)

        _ = try await lifecycle.stop()
        await source.waitForCollectionEnd(stream: 1)
        #expect(lifecycle.state == .stopped(controlRevision: resumedEpoch.revision + 1))
    }

    @Test(
        .timeLimit(.minutes(1)),
        arguments: [
            LocalCaptureLifecycleCapabilityRaceCase(
                capabilities: LocationCapabilities(servicesEnabled: true, authorization: .denied, fullAccuracy: false),
                currentServicesEnabled: true,
                expectedInterruption: .authorizationLost
            ),
            LocalCaptureLifecycleCapabilityRaceCase(
                capabilities: LocationCapabilities(servicesEnabled: false, authorization: .whileInUse, fullAccuracy: true),
                currentServicesEnabled: false,
                expectedInterruption: .locationServicesDisabled
            ),
            LocalCaptureLifecycleCapabilityRaceCase(
                capabilities: LocationCapabilities(servicesEnabled: true, authorization: .whileInUse, fullAccuracy: true),
                currentServicesEnabled: false,
                expectedInterruption: .locationServicesDisabled
            )
        ]
    )
    func capabilityLossDuringBeginDefersInterruptionUntilOwnerInstallation(
        _ capabilityCase: LocalCaptureLifecycleCapabilityRaceCase
    ) async throws {
        let store = CoordinatorPersistenceFake()
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.whileInUse))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        var currentServicesEnabled = true
        let lifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform,
            isLocationServicesEnabled: { currentServicesEnabled }
        )
        await store.gateNextBegin()

        let recordingID = UUID()
        let begin = Task { try await lifecycle.startNewRecording(recordingID: recordingID) }
        await store.waitForBeginCall()
        guard case .beginning(let pendingRecordingID, let generation) = lifecycle.state else {
            Issue.record("Begin did not enter its pending state")
            return
        }

        authorization.update(capabilityCase.capabilities)
        currentServicesEnabled = capabilityCase.currentServicesEnabled

        #expect(lifecycle.state == .beginning(recordingID: pendingRecordingID, generation: generation))
        #expect(source.streamCount == 0)
        #expect(platform.backgroundActivityHandles.isEmpty)
        #expect(platform.serviceSessionHandles.isEmpty)

        await store.releaseBegin()
        let epoch = try await begin.value
        await waitUntil {
            lifecycle.state == .resumeRequired(epoch: epoch, controlRevision: epoch.revision)
        }

        #expect(lifecycle.lastInterruption == capabilityCase.expectedInterruption)
        #expect(source.streamCount == 0)
        #expect(platform.backgroundActivityHandles.isEmpty)
        #expect(platform.serviceSessionHandles.isEmpty)
        let control = try await store.readControl()
        #expect(control.activeEpoch == epoch)
        let stopCallsAfterInterruption = await store.stopCallCount()
        #expect(stopCallsAfterInterruption == 0)

        currentServicesEnabled = true
        authorization.update(capabilities(.whileInUse))
        #expect(source.streamCount == 0)
        #expect(lifecycle.state == .resumeRequired(epoch: epoch, controlRevision: epoch.revision))

        let resumedEpoch = try await lifecycle.resume()
        await source.waitForStreamCount(1)
        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > epoch.revision)
        _ = try await lifecycle.stop()
        await source.waitForCollectionEnd(stream: 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func stopDuringServicesProbeCannotCreateLateRuntimeResources() async throws {
        let store = CoordinatorPersistenceFake()
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.always))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        let probe = LocalCaptureLifecycleServicesProbeFake()
        let lifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform,
            isLocationServicesEnabled: { await probe.read() }
        )
        let epoch = try await lifecycle.startNewRecording(recordingID: UUID())
        await probe.waitForCall()

        _ = try await lifecycle.stop()
        probe.release()
        await probe.waitForReturn()

        #expect(probe.wasCancelledWhenReturning)
        #expect(lifecycle.state == .stopped(controlRevision: epoch.revision + 1))
        #expect(!lifecycle.isAcceptingSamples)
        #expect(source.streamCount == 0)
        #expect(platform.backgroundActivityHandles.isEmpty)
        #expect(platform.serviceSessionHandles.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func permissionInterruptionAndStopCloseRuntimeResourcesBeforeDurableStop() async throws {
        let store = CoordinatorPersistenceFake()
        let recordingID = UUID()
        _ = try await store.beginExternally(recordingID: recordingID)
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.always))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        let lifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )

        let firstEpoch = try await lifecycle.resume()
        await source.waitForStreamCount(1)
        await platform.serviceSessionHandles[0].waitForCollectionStart()

        authorization.update(capabilities(.denied))
        #expect(lifecycle.state == .resumeRequired(
            epoch: firstEpoch,
            controlRevision: firstEpoch.revision
        ))
        #expect(lifecycle.lastInterruption == .authorizationLost)
        await source.waitForCollectionEnd(stream: 0)
        await platform.serviceSessionHandles[0].waitForCollectionEnd()
        #expect(platform.backgroundActivityHandles[0].isInvalidated)
        #expect(platform.serviceSessionHandles[0].isInvalidated)
        let controlAfterPermissionLoss = try await store.readControl()
        #expect(controlAfterPermissionLoss.activeEpoch == firstEpoch)
        let stopCallsAfterPermissionLoss = await store.stopCallCount()
        #expect(stopCallsAfterPermissionLoss == 0)

        authorization.update(capabilities(.always))
        #expect(lifecycle.state == .resumeRequired(
            epoch: firstEpoch,
            controlRevision: firstEpoch.revision
        ))
        #expect(source.streamCount == 1)

        let secondEpoch = try await lifecycle.resume()
        await source.waitForStreamCount(2)
        await platform.serviceSessionHandles[1].waitForCollectionStart()
        await store.gateNextStop()

        let stop = Task { try await lifecycle.stop() }
        await store.waitForStopCall()

        #expect(!lifecycle.isAcceptingSamples)
        #expect(platform.backgroundActivityHandles[1].isInvalidated)
        #expect(platform.serviceSessionHandles[1].isInvalidated)
        await source.waitForCollectionEnd(stream: 1)
        await platform.serviceSessionHandles[1].waitForCollectionEnd()
        let controlBeforeStopCommit = try await store.readControl()
        #expect(controlBeforeStopCommit.activeEpoch == secondEpoch)

        await store.releaseStop()
        guard case .stopped(let receipt) = try await stop.value else {
            Issue.record("Stop did not return its durable receipt")
            return
        }

        #expect(receipt.epoch == secondEpoch)
        #expect(lifecycle.state == .stopped(controlRevision: receipt.controlRevision))
        let stopCalls = await store.stopCallCount()
        #expect(stopCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func facadeStopClosesRuntimeBeforeAdmittedAppendAndPreservesItsReceipt() async throws {
        let store = CoordinatorPersistenceFake()
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.always))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        let lifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )
        let epoch = try await lifecycle.startNewRecording(recordingID: UUID())
        await source.waitForStreamCount(1)
        await platform.serviceSessionHandles[0].waitForCollectionStart()
        await store.gateNextAppend()

        let append = Task { await source.deliver(makeUpdate(seconds: 2_000), to: 0) }
        await store.waitForAppendCall()
        #expect(lifecycle.pendingSampleCount == 1)

        let stop = Task { try await lifecycle.stop() }
        await waitUntil {
            if case .stopping = lifecycle.state { return true }
            return false
        }

        #expect(!lifecycle.isAcceptingSamples)
        #expect(platform.backgroundActivityHandles[0].isInvalidated)
        #expect(platform.serviceSessionHandles[0].isInvalidated)
        await source.waitForCollectionEnd(stream: 0)
        await platform.serviceSessionHandles[0].waitForCollectionEnd()
        #expect(lifecycle.pendingSampleCount == 1)
        let stopCallsBeforeAppendRelease = await store.stopCallCount()
        #expect(stopCallsBeforeAppendRelease == 0)

        await store.releaseAppend()
        let callbackAccepted = await append.value
        let stopResult = try await stop.value
        guard case .stopped(let stopReceipt) = stopResult else {
            Issue.record("Stop did not return its durable receipt")
            return
        }
        let batchReceipts = await store.batchReceipts()
        let appendReceipt = try #require(batchReceipts.first)

        #expect(!callbackAccepted)
        #expect(appendReceipt.epoch == epoch)
        #expect(appendReceipt.items.count == 1)
        #expect(appendReceipt.items[0].disposition == .stored)
        #expect(stopReceipt.epoch == epoch)
        #expect(lifecycle.pendingSampleCount == 0)
        #expect(lifecycle.state == .stopped(controlRevision: stopReceipt.controlRevision))
    }

    @Test(.timeLimit(.minutes(1)))
    func droppingFacadeDuringAppendClosesRuntimeBeforeTheWriteReturns() async throws {
        let store = CoordinatorPersistenceFake()
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.always))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        var lifecycle: LocalCaptureLifecycle? = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )
        let epoch = try await lifecycle!.startNewRecording(recordingID: UUID())
        await source.waitForStreamCount(1)
        await platform.serviceSessionHandles[0].waitForCollectionStart()
        await store.gateNextAppend()

        let append = Task { await source.deliver(makeUpdate(seconds: 3_000), to: 0) }
        await store.waitForAppendCall()
        let weakLifecycle = LocalCaptureLifecycleWeakReference(lifecycle!)
        lifecycle = nil

        #expect(weakLifecycle.value == nil)
        await platform.backgroundActivityHandles[0].waitForInvalidation()
        await source.waitForCollectionEnd(stream: 0)
        await platform.serviceSessionHandles[0].waitForCollectionEnd()
        #expect(platform.serviceSessionHandles[0].isInvalidated)
        let controlBeforeAppendRelease = try await store.readControl()
        #expect(controlBeforeAppendRelease.activeEpoch == epoch)
        let stopCallsBeforeAppendRelease = await store.stopCallCount()
        #expect(stopCallsBeforeAppendRelease == 0)

        await store.releaseAppend()
        #expect(await append.value == false)
        let receipts = await store.batchReceipts()
        let receipt = try #require(receipts.first)
        #expect(receipt.epoch == epoch)
        #expect(receipt.items[0].disposition == .stored)
    }

    @Test(.timeLimit(.minutes(1)))
    func droppingFacadeCancelsCollectorsAndPreservesIntentForNextFacade() async throws {
        let store = CoordinatorPersistenceFake()
        let recordingID = UUID()
        _ = try await store.beginExternally(recordingID: recordingID)
        let source = LocalCaptureLifecycleLocationSourceFake()
        let authorization = LocalCaptureLifecycleAuthorizationFake(capabilities: capabilities(.always))
        let platform = LocalCaptureLifecycleRuntimePlatformFake()
        var lifecycle: LocalCaptureLifecycle? = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )
        let weakLifecycle = LocalCaptureLifecycleWeakReference(lifecycle!)
        let firstEpoch = try await lifecycle!.resume()
        await source.waitForStreamCount(1)
        await platform.serviceSessionHandles[0].waitForCollectionStart()

        lifecycle = nil

        #expect(weakLifecycle.value == nil)
        await source.waitForCollectionEnd(stream: 0)
        await platform.serviceSessionHandles[0].waitForCollectionEnd()
        await platform.backgroundActivityHandles[0].waitForInvalidation()
        #expect(platform.serviceSessionHandles[0].isInvalidated)
        let controlAfterDrop = try await store.readControl()
        #expect(controlAfterDrop.activeEpoch == firstEpoch)
        let stopCallsAfterDrop = await store.stopCallCount()
        #expect(stopCallsAfterDrop == 0)

        let reopenedLifecycle = try await makeLifecycle(
            store: store,
            source: source,
            authorization: authorization,
            platform: platform
        )
        #expect(reopenedLifecycle.state == .resumeRequired(
            epoch: firstEpoch,
            controlRevision: firstEpoch.revision
        ))
        #expect(source.streamCount == 1)

        let resumedEpoch = try await reopenedLifecycle.resume()
        await source.waitForStreamCount(2)
        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > firstEpoch.revision)
        _ = try await reopenedLifecycle.stop()
        await source.waitForCollectionEnd(stream: 1)
    }
}

@MainActor
private func makeLifecycle(
    store: CoordinatorPersistenceFake,
    source: LocalCaptureLifecycleLocationSourceFake,
    authorization: LocalCaptureLifecycleAuthorizationFake,
    platform: LocalCaptureLifecycleRuntimePlatformFake,
    isLocationServicesEnabled: (@MainActor () async -> Bool)? = nil
) async throws -> LocalCaptureLifecycle {
    try await LocalCaptureLifecycle.open(
        persistence: store,
        reopenVerifiedStore: {
            await store.recordReopen()
            return store
        },
        locationUpdateSource: source,
        authorization: authorization,
        runtimePlatform: platform,
        now: { Date(timeIntervalSinceReferenceDate: 10_000) },
        isLocationServicesEnabled: isLocationServicesEnabled ?? { authorization.capabilities.servicesEnabled }
    )
}

private struct LocalCaptureLifecycleCapabilityRaceCase: Sendable {
    let capabilities: LocationCapabilities
    let currentServicesEnabled: Bool
    let expectedInterruption: LocalCaptureLifecycleInterruption
}

@MainActor
private func capabilities(_ authorization: LocationAuthorization) -> LocationCapabilities {
    LocationCapabilities(
        servicesEnabled: true,
        authorization: authorization,
        fullAccuracy: authorization == .whileInUse || authorization == .always
    )
}

@MainActor
private func makeUpdate(seconds: TimeInterval) -> RecorderLocationUpdate {
    RecorderLocationUpdate(
        location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.3317, longitude: -122.0301),
            altitude: 5,
            horizontalAccuracy: 5,
            verticalAccuracy: 5,
            course: 0,
            speed: 0,
            timestamp: Date(timeIntervalSinceReferenceDate: seconds)
        ),
        stationary: false
    )
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0..<10_000 {
        if condition() {
            return
        }
        await Task.yield()
    }
    Issue.record("Timed out waiting for lifecycle state")
}

@MainActor
private func expectLifecycleError<Value>(
    _ expected: LocalCaptureLifecycleError,
    operation: () async throws -> Value
) async {
    do {
        _ = try await operation()
        Issue.record("Expected error \(expected)")
    } catch let error as LocalCaptureLifecycleError {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@MainActor
private final class LocalCaptureLifecycleLocationSourceFake: RecorderLocationUpdateSource {
    private var continuations: [AsyncThrowingStream<RecorderLocationUpdate, Error>.Continuation] = []
    private var receivers: [@MainActor (RecorderLocationUpdate) async -> Bool] = []
    private var endedCollections: Set<Int> = []
    private var streamWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var collectionEndWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    var streamCount: Int {
        continuations.count
    }

    func collect(_ receive: @escaping @MainActor (RecorderLocationUpdate) async -> Bool) async throws {
        let streamIndex = continuations.count
        let (stream, continuation) = AsyncThrowingStream<RecorderLocationUpdate, Error>.makeStream(
            of: RecorderLocationUpdate.self,
            throwing: Error.self
        )
        continuations.append(continuation)
        receivers.append(receive)
        let ready = streamWaiters.filter { $0.0 <= continuations.count }
        streamWaiters.removeAll { $0.0 <= continuations.count }
        for (_, waiter) in ready {
            waiter.resume()
        }

        defer {
            endedCollections.insert(streamIndex)
            let ready = collectionEndWaiters.filter { $0.0 == streamIndex }
            collectionEndWaiters.removeAll { $0.0 == streamIndex }
            for (_, waiter) in ready {
                waiter.resume()
            }
        }

        try await withTaskCancellationHandler {
            for try await update in stream {
                guard await receive(update) else {
                    break
                }
            }
        } onCancel: {
            continuation.finish()
        }
    }

    func deliver(_ update: RecorderLocationUpdate, to stream: Int) async -> Bool {
        await receivers[stream](update)
    }

    func finish(stream: Int) {
        continuations[stream].finish()
    }

    func waitForStreamCount(_ expected: Int) async {
        guard continuations.count < expected else {
            return
        }
        await withCheckedContinuation { streamWaiters.append((expected, $0)) }
    }

    func waitForCollectionEnd(stream: Int) async {
        guard !endedCollections.contains(stream) else {
            return
        }
        await withCheckedContinuation { collectionEndWaiters.append((stream, $0)) }
    }
}

@MainActor
private final class LocalCaptureLifecycleServicesProbeFake {
    private(set) var wasCancelledWhenReturning = false
    private var continuation: CheckedContinuation<Bool, Never>?
    private var called = false
    private var returned = false
    private var callWaiters: [CheckedContinuation<Void, Never>] = []
    private var returnWaiters: [CheckedContinuation<Void, Never>] = []

    func read() async -> Bool {
        called = true
        let ready = callWaiters
        callWaiters.removeAll()
        ready.forEach { $0.resume() }
        let enabled = await withCheckedContinuation { continuation = $0 }
        wasCancelledWhenReturning = Task.isCancelled
        returned = true
        let finished = returnWaiters
        returnWaiters.removeAll()
        finished.forEach { $0.resume() }
        return enabled
    }

    func waitForCall() async {
        guard !called else { return }
        await withCheckedContinuation { callWaiters.append($0) }
    }

    func release() {
        continuation?.resume(returning: true)
        continuation = nil
    }

    func waitForReturn() async {
        guard !returned else { return }
        await withCheckedContinuation { returnWaiters.append($0) }
    }
}

@MainActor
private final class LocalCaptureLifecycleAuthorizationFake: RecorderAuthorizationObservation {
    var capabilities: LocationCapabilities
    var onChange: (() -> Void)?
    private(set) var requestCount = 0

    init(capabilities: LocationCapabilities) {
        self.capabilities = capabilities
    }

    func refreshServicesEnabled() {}

    func requestWhenInUseAuthorization() {
        requestCount += 1
    }

    func update(_ capabilities: LocationCapabilities) {
        self.capabilities = capabilities
        onChange?()
    }
}

@MainActor
private final class LocalCaptureLifecycleRuntimePlatformFake: RecorderRuntimePlatform {
    private(set) var backgroundActivityHandles: [LocalCaptureLifecycleBackgroundActivityFake] = []
    private(set) var serviceSessionHandles: [LocalCaptureLifecycleServiceSessionFake] = []

    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle {
        let handle = LocalCaptureLifecycleBackgroundActivityFake()
        backgroundActivityHandles.append(handle)
        return handle
    }

    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle {
        let handle = LocalCaptureLifecycleServiceSessionFake()
        serviceSessionHandles.append(handle)
        return handle
    }
}

@MainActor
private final class LocalCaptureLifecycleBackgroundActivityFake: RecorderBackgroundActivityHandle {
    private(set) var isInvalidated = false
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        let waiters = invalidationWaiters
        invalidationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }

    func waitForInvalidation() async {
        guard !isInvalidated else {
            return
        }
        await withCheckedContinuation { invalidationWaiters.append($0) }
    }
}

@MainActor
private final class LocalCaptureLifecycleWeakReference {
    weak var value: LocalCaptureLifecycle?

    init(_ value: LocalCaptureLifecycle) {
        self.value = value
    }
}

@MainActor
private final class LocalCaptureLifecycleServiceSessionFake: RecorderServiceSessionHandle {
    private var diagnosticContinuation: AsyncThrowingStream<RecorderServiceDiagnostic, Error>.Continuation?
    private var collectionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionEndWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isCollectionStarted = false
    private(set) var isCollectionEnded = false
    private(set) var isInvalidated = false

    func collectDiagnostics(
        _ receive: @escaping @MainActor (RecorderServiceDiagnostic) async -> Void
    ) async throws {
        let (stream, continuation) = AsyncThrowingStream<RecorderServiceDiagnostic, Error>.makeStream(
            of: RecorderServiceDiagnostic.self,
            throwing: Error.self
        )
        diagnosticContinuation = continuation
        if isInvalidated {
            continuation.finish()
        }
        isCollectionStarted = true
        let ready = collectionStartWaiters
        collectionStartWaiters = []
        for waiter in ready {
            waiter.resume()
        }
        defer {
            isCollectionEnded = true
            let waiters = collectionEndWaiters
            collectionEndWaiters = []
            for waiter in waiters {
                waiter.resume()
            }
        }

        for try await diagnostic in stream {
            await receive(diagnostic)
        }
    }

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        diagnosticContinuation?.finish()
    }

    func waitForCollectionStart() async {
        guard !isCollectionStarted else {
            return
        }
        await withCheckedContinuation { collectionStartWaiters.append($0) }
    }

    func waitForCollectionEnd() async {
        guard !isCollectionEnded else {
            return
        }
        await withCheckedContinuation { collectionEndWaiters.append($0) }
    }
}
