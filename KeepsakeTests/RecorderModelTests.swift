import CoreLocation
import Foundation
import Observation
import Testing
@testable import Keepsake

@MainActor
struct RecorderModelTests {
    @Test(.timeLimit(.minutes(1))) func startWaitsForHistoryReadiness() async {
        let repository = LifecycleTestRepository(blockLoad: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)

        await repository.waitForLoadStarted()
        model.startRecording()

        #expect(!model.isStorageReady)
        #expect(!model.isRecordingRequested)
        #expect(source.streamCount == 0)

        await repository.completeLoad(with: RouteLoadResult(samples: [], recoveredIncompleteTail: false))
        await waitForStorageState(model, ready: true, clearing: false)
        model.startRecording()
        await source.waitForStreamCount(1)

        #expect(model.isRecordingRequested)
        #expect(source.streamCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func clearSerializesBehindLoadAndDiscardsItsStaleResult() async {
        let staleSample = makeSample(seconds: 1)
        let repository = LifecycleTestRepository(blockLoad: true, blockClear: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)

        await repository.waitForLoadStarted()
        model.clearHistory()
        model.startRecording()

        #expect(model.isClearingHistory)
        #expect(!model.isStorageReady)
        #expect(!model.isRecordingRequested)
        #expect(source.streamCount == 0)

        await repository.completeLoad(with: RouteLoadResult(samples: [staleSample], recoveredIncompleteTail: false))
        await repository.waitForClearStarted()
        #expect(model.samples.isEmpty)

        model.startRecording()
        #expect(!model.isRecordingRequested)

        await repository.completeClear(succeeds: true)
        await waitForStorageState(model, ready: true, clearing: false)

        #expect(model.samples.isEmpty)
        model.startRecording()
        await source.waitForStreamCount(1)
        #expect(source.streamCount == 1)
    }

    @Test(.timeLimit(.minutes(1))) func clearFailureKeepsStartBlockedAndStopCallable() async {
        let repository = LifecycleTestRepository(blockClear: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        model.clearHistory()
        await repository.waitForClearStarted()
        model.startRecording()
        #expect(!model.isRecordingRequested)

        await repository.completeClear(succeeds: false)
        await waitForStorageState(model, ready: false, clearing: false)

        #expect(model.storageMessage?.contains("state is unknown") == true)
        model.stopRecording()
        #expect(!model.isRecordingRequested)
        #expect(source.streamCount == 0)
    }

    @Test(.timeLimit(.minutes(1))) func normalStreamEndInterruptsItsRecordingAndAllowsExplicitRestart() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.finish(stream: 0)
        await waitForLocationMessage(model)

        #expect(!model.isRecordingRequested)
        #expect(model.locationMessage == "Location updates ended unexpectedly. Start a new recording to resume.")

        model.startRecording()
        await source.waitForStreamCount(2)
        #expect(model.isRecordingRequested)
        #expect(source.streamCount == 2)
    }

    @Test(.timeLimit(.minutes(1))) func permissionLossRequiresExplicitRestartAndKeepsLogicalRecordingID() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let runtimePlatform = LifecycleTestRuntimePlatform()
        let model = makeModel(
            repository: repository,
            source: source,
            authorization: authorization,
            runtimePlatform: runtimePlatform
        )
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.send(makeLocationUpdate(seconds: 1_000), to: 0)
        await repository.waitForAppendCount(1)
        await waitForSamples(model, count: 1)
        let firstSamples = await repository.appendedSamples()
        #expect(firstSamples.count == 1)
        let firstSample = firstSamples[0]

        source.delayCollectionEnd(stream: 0)
        authorization.update(LocationCapabilities(
            servicesEnabled: true,
            authorization: .denied,
            fullAccuracy: false
        ))
        #expect(!model.isRecordingRequested)
        await source.waitForCollectionPause(stream: 0)

        authorization.update(allowedCapabilities)
        await source.waitForStreamCount(1)
        #expect(source.streamCount == 1)

        model.startRecording()
        await source.waitForStreamCount(2)
        #expect(source.streamCount == 2)
        source.resolveCollectionEnd(stream: 0, fails: true)
        await source.waitForCollectionEnd(stream: 0)
        await runtimePlatform.backgroundActivityHandles[0].waitForInvalidationCallCount(2)
        #expect(model.isRecordingRequested)

        source.send(makeLocationUpdate(seconds: 1_001), to: 1)
        await repository.waitForAppendCount(2)
        await waitForSamples(model, count: 2)
        let samples = await repository.appendedSamples()

        #expect(samples[0].recordingID == firstSample.recordingID)
        #expect(samples[1].recordingID == firstSample.recordingID)
        #expect(model.isRecordingRequested)
    }

    @Test(.timeLimit(.minutes(1))) func deallocationCancelsCollectorsAndInvalidatesOwnedSessions() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: LocationCapabilities(
            servicesEnabled: true,
            authorization: .always,
            fullAccuracy: true
        ))
        let runtimePlatform = LifecycleTestRuntimePlatform()
        var model: RecorderModel? = makeModel(
            repository: repository,
            source: source,
            authorization: authorization,
            runtimePlatform: runtimePlatform
        )
        weak var weakModel = model
        await waitForStorageState(model!, ready: true, clearing: false)

        model?.startRecording()
        await source.waitForStreamCount(1)
        let backgroundSession = runtimePlatform.backgroundActivityHandles[0]
        let serviceSession = runtimePlatform.serviceSessionHandles[0]
        await serviceSession.waitForCollectionStart()

        model = nil
        while weakModel != nil {
            await Task.yield()
        }

        #expect(weakModel == nil)
        await source.waitForCollectionEnd(stream: 0)
        await backgroundSession.waitForInvalidation()
        await serviceSession.waitForCollectionEnd()
        await serviceSession.waitForInvalidation()
        #expect(backgroundSession.isInvalidated)
        #expect(serviceSession.isInvalidated)
    }

    @Test(.timeLimit(.minutes(1))) func alwaysAccessDiagnosticsUseTheInjectedSession() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: LocationCapabilities(
            servicesEnabled: true,
            authorization: .always,
            fullAccuracy: true
        ))
        let runtimePlatform = LifecycleTestRuntimePlatform()
        let model = makeModel(
            repository: repository,
            source: source,
            authorization: authorization,
            runtimePlatform: runtimePlatform
        )
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        let serviceSession = runtimePlatform.serviceSessionHandles[0]
        await serviceSession.waitForCollectionStart()
        serviceSession.send(RecorderServiceDiagnostic(
            alwaysAuthorizationDenied: true,
            authorizationRequestInProgress: false
        ))
        await waitForAlwaysAuthorizationDenied(model)
        await serviceSession.waitForCollectionEnd()
        await serviceSession.waitForInvalidation()

        #expect(model.alwaysAuthorizationDenied)
        #expect(!model.isRequestingAlwaysAccess)
        #expect(serviceSession.isInvalidated)
        model.stopRecording()
        await source.waitForCollectionEnd(stream: 0)
    }

    @Test(.timeLimit(.minutes(1))) func lateNormalCompletionCannotInterruptANewerRuntime() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let runtimePlatform = LifecycleTestRuntimePlatform()
        let model = makeModel(
            repository: repository,
            source: source,
            authorization: authorization,
            runtimePlatform: runtimePlatform
        )
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.delayCollectionEnd(stream: 0)
        model.stopRecording()
        await source.waitForCollectionPause(stream: 0)

        model.startRecording()
        await source.waitForStreamCount(2)
        source.resolveCollectionEnd(stream: 0, fails: false)
        await source.waitForCollectionEnd(stream: 0)
        await runtimePlatform.backgroundActivityHandles[0].waitForInvalidationCallCount(2)
        #expect(model.isRecordingRequested)
        #expect(model.locationMessage == nil)

        model.stopRecording()
        await source.waitForCollectionEnd(stream: 1)
    }

    @Test(.timeLimit(.minutes(1))) func stopKeepsRestartBlockedUntilTheSuspendedAppendCompletes() async {
        let repository = LifecycleTestRepository(blockAppend: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.send(makeLocationUpdate(seconds: 1_005), to: 0)
        await repository.waitForAppendCount(1)
        #expect(!model.isStorageReady)

        model.stopRecording()
        model.startRecording()
        #expect(!model.isRecordingRequested)
        #expect(source.streamCount == 1)

        await repository.completeAppend(succeeds: true)
        await waitForStorageState(model, ready: true, clearing: false)
        await source.waitForCollectionEnd(stream: 0)
        model.startRecording()
        await source.waitForStreamCount(2)
        #expect(model.isRecordingRequested)
        model.stopRecording()
        await source.waitForCollectionEnd(stream: 1)
    }

    @Test(.timeLimit(.minutes(1))) func stopBlocksRestartUntilAnInFlightAppendAndClearFinish() async {
        let repository = LifecycleTestRepository(blockAppend: true, blockClear: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.send(makeLocationUpdate(seconds: 1_010), to: 0)
        await repository.waitForAppendCount(1)

        model.stopRecording()
        model.startRecording()
        #expect(!model.isRecordingRequested)
        #expect(source.streamCount == 1)

        model.clearHistory()
        #expect(model.isClearingHistory)
        #expect(await repository.clearCallCount() == 0)

        await repository.completeAppend(succeeds: true)
        await repository.waitForClearStarted()
        model.startRecording()
        #expect(!model.isRecordingRequested)
        #expect(await repository.clearCallCount() == 1)
        #expect(model.samples.isEmpty)

        await repository.completeClear(succeeds: true)
        await waitForStorageState(model, ready: true, clearing: false)
        await source.waitForCollectionEnd(stream: 0)
        model.startRecording()
        await source.waitForStreamCount(2)
        #expect(model.isRecordingRequested)
    }

    @Test(.timeLimit(.minutes(1))) func failedAppendWhileClearingDoesNotPoisonTheNextRuntime() async {
        let repository = LifecycleTestRepository(blockAppend: true)
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: allowedCapabilities)
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        model.startRecording()
        await source.waitForStreamCount(1)
        source.send(makeLocationUpdate(seconds: 1_020), to: 0)
        await repository.waitForAppendCount(1)
        model.stopRecording()
        model.clearHistory()

        await repository.completeAppend(succeeds: false)
        await repository.waitForClearStarted()
        await waitForStorageState(model, ready: true, clearing: false)
        await source.waitForCollectionEnd(stream: 0)

        #expect(model.storageMessage == nil)
        model.startRecording()
        await source.waitForStreamCount(2)
        #expect(model.isRecordingRequested)
    }

    @Test(.timeLimit(.minutes(1))) func permissionPromptStartsOnlyAfterAnExplicitStart() async {
        let repository = LifecycleTestRepository()
        let source = LifecycleTestLocationSource()
        let authorization = LifecycleTestAuthorizationObserver(capabilities: LocationCapabilities(
            servicesEnabled: true,
            authorization: .notDetermined,
            fullAccuracy: true
        ))
        let model = makeModel(repository: repository, source: source, authorization: authorization)
        await waitForStorageState(model, ready: true, clearing: false)

        #expect(authorization.requestCount == 0)
        model.startRecording()
        #expect(authorization.requestCount == 1)
        #expect(source.streamCount == 0)

        authorization.update(allowedCapabilities)
        await source.waitForStreamCount(1)
        #expect(source.streamCount == 1)
    }
}

private let allowedCapabilities = LocationCapabilities(
    servicesEnabled: true,
    authorization: .whileInUse,
    fullAccuracy: true
)

@MainActor
private func makeModel(
    repository: LifecycleTestRepository,
    source: LifecycleTestLocationSource,
    authorization: LifecycleTestAuthorizationObserver,
    runtimePlatform: LifecycleTestRuntimePlatform = LifecycleTestRuntimePlatform()
) -> RecorderModel {
    RecorderModel(
        recorderRepository: repository,
        locationUpdateSource: source,
        authorizationObserver: authorization,
        runtimePlatform: runtimePlatform,
        clock: { Date(timeIntervalSince1970: 10_000) }
    )
}

@MainActor
private func waitForStorageState(_ model: RecorderModel, ready: Bool, clearing: Bool) async {
    while model.isStorageReady != ready || model.isClearingHistory != clearing {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = model.isStorageReady
                _ = model.isClearingHistory
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func waitForLocationMessage(_ model: RecorderModel) async {
    while model.locationMessage == nil {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = model.locationMessage
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func waitForAlwaysAuthorizationDenied(_ model: RecorderModel) async {
    while !model.alwaysAuthorizationDenied {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = model.alwaysAuthorizationDenied
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
private func waitForSamples(_ model: RecorderModel, count: Int) async {
    while model.samples.count < count {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            withObservationTracking {
                _ = model.samples
            } onChange: {
                continuation.resume()
            }
        }
    }
}

@MainActor
private final class LifecycleTestLocationSource: RecorderLocationUpdateSource {
    private var continuations: [AsyncThrowingStream<RecorderLocationUpdate, Error>.Continuation] = []
    private var streamWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var delayedCollectionEnds = Set<Int>()
    private var pausedCollectionEnds = Set<Int>()
    private var collectionEndContinuations: [Int: CheckedContinuation<Bool, Never>] = [:]
    private var collectionPauseWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var collectionEndWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var endedCollections = Set<Int>()

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
        let ready = streamWaiters.filter { $0.0 <= continuations.count }
        streamWaiters.removeAll { $0.0 <= continuations.count }
        for (_, waiter) in ready {
            waiter.resume()
        }

        do {
            for try await update in stream {
                guard await receive(update) else {
                    break
                }
            }
        } catch {
            if delayedCollectionEnds.contains(streamIndex) {
                let fails = await waitForCollectionEndResolution(streamIndex)
                markCollectionEnded(streamIndex)
                if fails {
                    throw LifecycleTestLocationError.failed
                }
            }
            markCollectionEnded(streamIndex)
            throw error
        }

        if delayedCollectionEnds.contains(streamIndex) {
            let fails = await waitForCollectionEndResolution(streamIndex)
            markCollectionEnded(streamIndex)
            if fails {
                throw LifecycleTestLocationError.failed
            }
        }
        markCollectionEnded(streamIndex)
    }

    func waitForStreamCount(_ expected: Int) async {
        guard continuations.count < expected else {
            return
        }
        await withCheckedContinuation { streamWaiters.append((expected, $0)) }
    }

    func send(_ update: RecorderLocationUpdate, to stream: Int) {
        continuations[stream].yield(update)
    }

    func finish(stream: Int) {
        continuations[stream].finish()
    }

    func delayCollectionEnd(stream: Int) {
        delayedCollectionEnds.insert(stream)
    }

    func waitForCollectionPause(stream: Int) async {
        guard !pausedCollectionEnds.contains(stream) else {
            return
        }
        await withCheckedContinuation { collectionPauseWaiters.append((stream, $0)) }
    }

    func resolveCollectionEnd(stream: Int, fails: Bool) {
        collectionEndContinuations.removeValue(forKey: stream)?.resume(returning: fails)
    }

    func waitForCollectionEnd(stream: Int) async {
        guard !endedCollections.contains(stream) else {
            return
        }
        await withCheckedContinuation { collectionEndWaiters.append((stream, $0)) }
    }

    private func waitForCollectionEndResolution(_ stream: Int) async -> Bool {
        await withCheckedContinuation { continuation in
            collectionEndContinuations[stream] = continuation
            pausedCollectionEnds.insert(stream)
            let ready = collectionPauseWaiters.filter { $0.0 == stream }
            collectionPauseWaiters.removeAll { $0.0 == stream }
            for (_, waiter) in ready {
                waiter.resume()
            }
        }
    }

    private func markCollectionEnded(_ stream: Int) {
        endedCollections.insert(stream)
        let ready = collectionEndWaiters.filter { $0.0 == stream }
        collectionEndWaiters.removeAll { $0.0 == stream }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }
}

@MainActor
private final class LifecycleTestRuntimePlatform: RecorderRuntimePlatform {
    private(set) var backgroundActivityHandles: [LifecycleTestBackgroundActivityHandle] = []
    private(set) var serviceSessionHandles: [LifecycleTestServiceSessionHandle] = []

    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle {
        let handle = LifecycleTestBackgroundActivityHandle()
        backgroundActivityHandles.append(handle)
        return handle
    }

    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle {
        let handle = LifecycleTestServiceSessionHandle()
        serviceSessionHandles.append(handle)
        return handle
    }
}

@MainActor
private final class LifecycleTestBackgroundActivityHandle: RecorderBackgroundActivityHandle {
    private(set) var isInvalidated = false
    private(set) var invalidationCallCount = 0
    private var invalidationWaiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func invalidate() {
        isInvalidated = true
        invalidationCallCount += 1
        let ready = invalidationWaiters.filter { $0.0 <= invalidationCallCount }
        invalidationWaiters.removeAll { $0.0 <= invalidationCallCount }
        for (_, waiter) in ready {
            waiter.resume()
        }
    }

    func waitForInvalidation() async {
        guard !isInvalidated else {
            return
        }
        await withCheckedContinuation { invalidationWaiters.append((1, $0)) }
    }

    func waitForInvalidationCallCount(_ expected: Int) async {
        guard invalidationCallCount < expected else {
            return
        }
        await withCheckedContinuation { invalidationWaiters.append((expected, $0)) }
    }
}

@MainActor
private final class LifecycleTestServiceSessionHandle: RecorderServiceSessionHandle {
    private var diagnosticContinuation: AsyncThrowingStream<RecorderServiceDiagnostic, Error>.Continuation?
    private var collectionStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var collectionEndWaiters: [CheckedContinuation<Void, Never>] = []
    private var invalidationWaiters: [CheckedContinuation<Void, Never>] = []
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
        let startWaiters = collectionStartWaiters
        collectionStartWaiters = []
        for waiter in startWaiters {
            waiter.resume()
        }
        defer {
            isCollectionEnded = true
            let endWaiters = collectionEndWaiters
            collectionEndWaiters = []
            for waiter in endWaiters {
                waiter.resume()
            }
        }

        for try await diagnostic in stream {
            await receive(diagnostic)
        }
    }

    func send(_ diagnostic: RecorderServiceDiagnostic) {
        diagnosticContinuation?.yield(diagnostic)
    }

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        diagnosticContinuation?.finish()
        let waiters = invalidationWaiters
        invalidationWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
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

    func waitForInvalidation() async {
        guard !isInvalidated else {
            return
        }
        await withCheckedContinuation { invalidationWaiters.append($0) }
    }
}

@MainActor
private final class LifecycleTestAuthorizationObserver: RecorderAuthorizationObservation {
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

private actor LifecycleTestRepository: RecorderRepository {
    private var loadedSamples: [RouteSample]
    private let blockLoad: Bool
    private let blockAppend: Bool
    private let blockClear: Bool
    private var loadCalls = 0
    private var appendCalls = 0
    private var clearCalls = 0
    private var loadContinuation: CheckedContinuation<RouteLoadResult, any Error>?
    private var appendContinuation: CheckedContinuation<SampleIngestResult, any Error>?
    private var clearContinuation: CheckedContinuation<Void, any Error>?
    private var pendingAppend: RouteSample?
    private var loadWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendWaiters: [(Int, CheckedContinuation<Void, Never>)] = []
    private var clearWaiters: [CheckedContinuation<Void, Never>] = []
    private var appended: [RouteSample] = []

    init(
        loadedSamples: [RouteSample] = [],
        blockLoad: Bool = false,
        blockAppend: Bool = false,
        blockClear: Bool = false
    ) {
        self.loadedSamples = loadedSamples
        self.blockLoad = blockLoad
        self.blockAppend = blockAppend
        self.blockClear = blockClear
    }

    func load() async throws -> RouteLoadResult {
        loadCalls += 1
        let waiters = loadWaiters
        loadWaiters = []
        for waiter in waiters {
            waiter.resume()
        }

        if blockLoad {
            return try await withCheckedThrowingContinuation { loadContinuation = $0 }
        }
        return RouteLoadResult(samples: loadedSamples + appended, recoveredIncompleteTail: false)
    }

    func append(_ sample: RouteSample, now: Date) async throws -> SampleIngestResult {
        appendCalls += 1
        let ready = appendWaiters.filter { $0.0 <= appendCalls }
        appendWaiters.removeAll { $0.0 <= appendCalls }
        for (_, waiter) in ready {
            waiter.resume()
        }
        if blockAppend {
            pendingAppend = sample
            return try await withCheckedThrowingContinuation { appendContinuation = $0 }
        }
        appended.append(sample)
        return .stored
    }

    func clear() async throws {
        clearCalls += 1
        let waiters = clearWaiters
        clearWaiters = []
        for waiter in waiters {
            waiter.resume()
        }

        if blockClear {
            try await withCheckedThrowingContinuation { clearContinuation = $0 }
        }
        loadedSamples = []
        appended = []
    }

    func waitForLoadStarted() async {
        guard loadCalls == 0 else {
            return
        }
        await withCheckedContinuation { loadWaiters.append($0) }
    }

    func waitForAppendCount(_ expected: Int) async {
        guard appendCalls < expected else {
            return
        }
        await withCheckedContinuation { appendWaiters.append((expected, $0)) }
    }

    func waitForClearStarted() async {
        guard clearCalls == 0 else {
            return
        }
        await withCheckedContinuation { clearWaiters.append($0) }
    }

    func clearCallCount() -> Int {
        clearCalls
    }

    func completeLoad(with result: RouteLoadResult) {
        loadContinuation?.resume(returning: result)
        loadContinuation = nil
    }

    func completeClear(succeeds: Bool) {
        if succeeds {
            clearContinuation?.resume(returning: ())
        } else {
            clearContinuation?.resume(throwing: LifecycleTestRepositoryError.clear)
        }
        clearContinuation = nil
    }

    func completeAppend(succeeds: Bool) {
        if succeeds {
            if let pendingAppend {
                appended.append(pendingAppend)
            }
            appendContinuation?.resume(returning: .stored)
        } else {
            appendContinuation?.resume(throwing: LifecycleTestRepositoryError.append)
        }
        pendingAppend = nil
        appendContinuation = nil
    }

    func appendedSamples() -> [RouteSample] {
        appended
    }
}

private enum LifecycleTestRepositoryError: Error {
    case append
    case clear
}

private enum LifecycleTestLocationError: Error {
    case failed
}

private func makeLocationUpdate(seconds: TimeInterval) -> RecorderLocationUpdate {
    RecorderLocationUpdate(
        location: CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 37.3349, longitude: -122.0090),
            altitude: 4,
            horizontalAccuracy: 8,
            verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: seconds)
        ),
        stationary: false
    )
}

private func makeSample(seconds: TimeInterval) -> RouteSample {
    RouteSample(
        recordingID: UUID(),
        observedAt: Date(timeIntervalSince1970: seconds),
        latitude: 37.3349,
        longitude: -122.0090,
        horizontalAccuracy: 8,
        isStationary: false
    )
}
