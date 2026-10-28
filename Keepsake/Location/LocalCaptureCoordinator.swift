import Foundation

@MainActor
protocol LocalCaptureRuntimeHandle: AnyObject {
    func stop()
}

@MainActor
protocol LocalCaptureRuntimeControl {
    func start(epoch: CaptureEpoch, generation: UUID) -> any LocalCaptureRuntimeHandle
}

enum LocalCaptureUncertaintyKind: Equatable {
    case begin
    case append
    case stop
}

enum LocalCaptureUncertaintyReason: Equatable, Sendable {
    case persistenceOutcome
    case receiptMismatch
    case receiptUnavailable
    case controlChanged
    case sampleConflict
    case sampleAbsentOrExpired
    case reopenUnavailable
}

enum LocalCaptureCoordinatorState: Equatable {
    case unready
    case stopped(controlRevision: Int64)
    case resumeRequired(epoch: CaptureEpoch, controlRevision: Int64)
    case beginning(recordingID: UUID, generation: UUID)
    case active(epoch: CaptureEpoch, generation: UUID, controlRevision: Int64)
    case stopping(operationID: UUID, epoch: CaptureEpoch?)
    case stopUnconfirmed(operationID: UUID, epoch: CaptureEpoch?)
    case uncertain(operationID: UUID, kind: LocalCaptureUncertaintyKind, reason: LocalCaptureUncertaintyReason)
}

enum LocalCaptureCoordinatorError: Error, Equatable {
    case storageNotReady
    case stopPending
    case stopUnconfirmed(UUID)
    case unresolvedOperation(UUID)
    case recordingMismatch
    case controlReadPending
    case sampleRecordingMismatch
    case emptyBatch
    case backpressure
    case operationConflict(UUID)
    case supersededByStop
    case noPendingStop
    case invalidControlSnapshot
    case receiptMismatch(UUID)
}

enum LocalCaptureStopResult: Equatable, Sendable {
    case stopped(CaptureControlReceipt)
    case alreadyStopped(CaptureControlSnapshot)
}

enum LocalCaptureReconciliationResult: Equatable, Sendable {
    case beginCommitted(CaptureControlReceipt)
    case appendCommitted(CaptureBatchReceipt)
    case appendSamplesMatched(UUID)
    case stopCommitted(CaptureControlReceipt)
    case knownNotCommitted(UUID)
    case unresolved(UUID, LocalCaptureUncertaintyReason)
    case nothingToReconcile
}

@MainActor
final class LocalCaptureCoordinator {
    private struct RuntimeOwner {
        let epoch: CaptureEpoch
        let generation: UUID
        let handle: any LocalCaptureRuntimeHandle
    }

    private final class ControlRead {
        var waiters: [CheckedContinuation<CaptureControlSnapshot, any Error>] = []
    }

    private final class BeginRequest {
        let operationID: UUID
        let recordingID: UUID
        let expectedControlRevision: Int64
        let controlBefore: CaptureControlSnapshot
        let generation: UUID
        var waiters: [CheckedContinuation<CaptureEpoch, any Error>] = []
        var receipt: CaptureControlReceipt?

        init(
            operationID: UUID,
            recordingID: UUID,
            expectedControlRevision: Int64,
            controlBefore: CaptureControlSnapshot,
            generation: UUID
        ) {
            self.operationID = operationID
            self.recordingID = recordingID
            self.expectedControlRevision = expectedControlRevision
            self.controlBefore = controlBefore
            self.generation = generation
        }
    }

    private final class AppendRequest {
        let operationID: UUID
        let input: CaptureBatchInput
        let now: Date
        let epoch: CaptureEpoch
        let generation: UUID
        let controlBefore: CaptureControlSnapshot
        let digest: String
        var waiters: [CheckedContinuation<CaptureBatchReceipt, any Error>] = []
        var receipt: CaptureBatchReceipt?
        var isReleased = false

        init(
            operationID: UUID,
            input: CaptureBatchInput,
            now: Date,
            epoch: CaptureEpoch,
            generation: UUID,
            controlBefore: CaptureControlSnapshot
        ) {
            self.operationID = operationID
            self.input = input
            self.now = now
            self.epoch = epoch
            self.generation = generation
            self.controlBefore = controlBefore
            digest = CaptureCommandDigest.batch(epoch: epoch, input: input)
        }
    }

    private enum StopRequestStatus: Equatable {
        case queued
        case running
        case failed
        case uncertain
    }

    private final class StopRequest {
        let operationID: UUID
        let generation: UUID
        var controlBefore: CaptureControlSnapshot
        var epoch: CaptureEpoch?
        var expectedControlRevision: Int64?
        var status = StopRequestStatus.queued
        var retryAllowed = false
        var receipt: CaptureControlReceipt?
        var waiters: [CheckedContinuation<LocalCaptureStopResult, any Error>] = []

        init(operationID: UUID, generation: UUID, controlBefore: CaptureControlSnapshot) {
            self.operationID = operationID
            self.generation = generation
            self.controlBefore = controlBefore
        }
    }

    private final class ReconciliationRequest {
        var waiters: [CheckedContinuation<LocalCaptureReconciliationResult, any Error>] = []
    }

    private enum UncertainOperation {
        case begin(BeginRequest)
        case append(AppendRequest)
        case stop(StopRequest)

        var operationID: UUID {
            switch self {
            case .begin(let request): request.operationID
            case .append(let request): request.operationID
            case .stop(let request): request.operationID
            }
        }

        var kind: LocalCaptureUncertaintyKind {
            switch self {
            case .begin: .begin
            case .append: .append
            case .stop: .stop
            }
        }
    }

    private enum Work {
        case readControl(ControlRead)
        case begin(BeginRequest)
        case append(AppendRequest)
        case stop(StopRequest)
        case retryStop(StopRequest)
        case reconcile(ReconciliationRequest)
    }

    private var persistence: any LocalCapturePersistence
    private let runtime: any LocalCaptureRuntimeControl
    private let reopenVerifiedStore: @Sendable () async throws -> any LocalCapturePersistence
    private var queue: [Work] = []
    private var worker: Task<Void, Never>?
    private var pendingControlRead: ControlRead?
    private var pendingBegin: BeginRequest?
    private var pendingStop: StopRequest?
    private var pendingReconciliation: ReconciliationRequest?
    private var pendingAppends: [UUID: AppendRequest] = [:]
    private var uncertainty: UncertainOperation?
    private var runtimeOwner: RuntimeOwner?
    private var runtimeGeneration = UUID()
    private var admissionOpen = false

    private(set) var state: LocalCaptureCoordinatorState = .unready
    private(set) var controlSnapshot: CaptureControlSnapshot?
    private(set) var pendingSampleCount = 0
    private(set) var pendingEncodedPayloadBytes = 0

    var isStorageReady: Bool {
        controlSnapshot != nil && uncertainty == nil
    }

    var isAcceptingSamples: Bool {
        admissionOpen && runtimeOwner != nil && uncertainty == nil && pendingStop == nil
    }

    init(
        persistence: any LocalCapturePersistence,
        runtime: any LocalCaptureRuntimeControl,
        reopenVerifiedStore: @escaping @Sendable () async throws -> any LocalCapturePersistence
    ) {
        self.persistence = persistence
        self.runtime = runtime
        self.reopenVerifiedStore = reopenVerifiedStore
    }

    func refreshControl() async throws -> CaptureControlSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            guard uncertainty == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.unresolvedOperation(uncertainty!.operationID))
                return
            }
            guard pendingStop == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.stopPending)
                return
            }
            if let pendingControlRead {
                pendingControlRead.waiters.append(continuation)
                return
            }

            let read = ControlRead()
            read.waiters.append(continuation)
            pendingControlRead = read
            queue.append(.readControl(read))
            startWorkerIfNeeded()
        }
    }

    func startRecording(recordingID: UUID) async throws -> CaptureEpoch {
        try await withCheckedThrowingContinuation { continuation in
            guard let controlSnapshot else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.storageNotReady)
                return
            }
            guard uncertainty == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.unresolvedOperation(uncertainty!.operationID))
                return
            }
            guard pendingStop == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.stopPending)
                return
            }
            guard pendingControlRead == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.controlReadPending)
                return
            }

            if let runtimeOwner {
                guard runtimeOwner.epoch.recordingID == recordingID else {
                    continuation.resume(throwing: LocalCaptureCoordinatorError.recordingMismatch)
                    return
                }
                continuation.resume(returning: runtimeOwner.epoch)
                return
            }

            if let pendingBegin {
                guard pendingBegin.recordingID == recordingID else {
                    continuation.resume(throwing: LocalCaptureCoordinatorError.operationConflict(pendingBegin.operationID))
                    return
                }
                pendingBegin.waiters.append(continuation)
                return
            }

            if let activeEpoch = controlSnapshot.activeEpoch,
               activeEpoch.recordingID != recordingID {
                continuation.resume(throwing: LocalCaptureCoordinatorError.recordingMismatch)
                return
            }

            let generation = UUID()
            runtimeGeneration = generation
            admissionOpen = false
            state = .beginning(recordingID: recordingID, generation: generation)
            let request = BeginRequest(
                operationID: UUID(),
                recordingID: recordingID,
                expectedControlRevision: controlSnapshot.revision,
                controlBefore: controlSnapshot,
                generation: generation
            )
            request.waiters.append(continuation)
            pendingBegin = request
            queue.append(.begin(request))
            startWorkerIfNeeded()
        }
    }

    func append(
        _ input: CaptureBatchInput,
        now: Date = .now,
        operationID: UUID = UUID()
    ) async throws -> CaptureBatchReceipt {
        try await withCheckedThrowingContinuation { continuation in
            guard let owner = runtimeOwner,
                  let controlSnapshot,
                  isAcceptingSamples else {
                continuation.resume(throwing: uncertainty.map {
                    LocalCaptureCoordinatorError.unresolvedOperation($0.operationID)
                } ?? (pendingStop == nil
                    ? LocalCaptureCoordinatorError.storageNotReady
                    : LocalCaptureCoordinatorError.stopPending))
                return
            }
            guard !input.samples.isEmpty else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.emptyBatch)
                return
            }
            guard input.samples.allSatisfy({ $0.recordingID == owner.epoch.recordingID }) else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.sampleRecordingMismatch)
                return
            }

            let digest = CaptureCommandDigest.batch(epoch: owner.epoch, input: input)
            if let pending = pendingAppends[operationID] {
                guard pending.digest == digest else {
                    continuation.resume(throwing: LocalCaptureCoordinatorError.operationConflict(operationID))
                    return
                }
                pending.waiters.append(continuation)
                return
            }

            let maximumSamples = CapturePersistenceLimits.maximumBatchSamples
            let maximumBytes = CapturePersistenceLimits.maximumPendingPayloadBytes
            guard input.samples.count <= maximumSamples - pendingSampleCount,
                  input.encodedPayloadBytes >= 0,
                  input.encodedPayloadBytes <= maximumBytes - pendingEncodedPayloadBytes else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.backpressure)
                return
            }

            let request = AppendRequest(
                operationID: operationID,
                input: input,
                now: now,
                epoch: owner.epoch,
                generation: owner.generation,
                controlBefore: controlSnapshot
            )
            request.waiters.append(continuation)
            pendingAppends[operationID] = request
            pendingSampleCount += input.samples.count
            pendingEncodedPayloadBytes += input.encodedPayloadBytes
            queue.append(.append(request))
            startWorkerIfNeeded()
        }
    }

    func stopRecording() async throws -> LocalCaptureStopResult {
        try await withCheckedThrowingContinuation { continuation in
            if let pendingStop {
                guard pendingStop.status == .queued || pendingStop.status == .running else {
                    continuation.resume(throwing: LocalCaptureCoordinatorError.stopUnconfirmed(pendingStop.operationID))
                    return
                }
                pendingStop.waiters.append(continuation)
                return
            }
            guard uncertainty == nil else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.unresolvedOperation(uncertainty!.operationID))
                return
            }
            guard let controlSnapshot else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.storageNotReady)
                return
            }

            closeRuntimeAndAdvanceGeneration()
            if controlSnapshot.activeEpoch == nil, pendingBegin == nil, uncertainty == nil {
                state = .stopped(controlRevision: controlSnapshot.revision)
                continuation.resume(returning: .alreadyStopped(controlSnapshot))
                return
            }

            let request = StopRequest(
                operationID: UUID(),
                generation: runtimeGeneration,
                controlBefore: controlSnapshot
            )
            request.epoch = controlSnapshot.activeEpoch
            request.waiters.append(continuation)
            pendingStop = request
            state = .stopping(operationID: request.operationID, epoch: controlSnapshot.activeEpoch)
            queue.append(.stop(request))
            startWorkerIfNeeded()
        }
    }

    @discardableResult
    func runtimeInterrupted(epoch: CaptureEpoch, generation: UUID) -> Bool {
        guard uncertainty == nil,
              pendingStop == nil,
              let runtimeOwner,
              runtimeOwner.epoch == epoch,
              runtimeOwner.generation == generation,
              let controlSnapshot,
              controlSnapshot.activeEpoch == epoch else {
            return false
        }

        closeRuntimeAndAdvanceGeneration()
        stateFromSnapshotWithoutRuntime(controlSnapshot)
        return true
    }

    func retryStop() async throws -> LocalCaptureStopResult {
        try await withCheckedThrowingContinuation { continuation in
            guard let pendingStop,
                  pendingStop.status == .failed,
                  pendingStop.retryAllowed else {
                continuation.resume(throwing: LocalCaptureCoordinatorError.noPendingStop)
                return
            }
            pendingStop.status = .queued
            pendingStop.waiters.append(continuation)
            queue.append(.retryStop(pendingStop))
            startWorkerIfNeeded()
        }
    }

    func reconcileUncertain() async throws -> LocalCaptureReconciliationResult {
        try await withCheckedThrowingContinuation { continuation in
            guard uncertainty != nil else {
                continuation.resume(returning: .nothingToReconcile)
                return
            }
            if let pendingReconciliation {
                pendingReconciliation.waiters.append(continuation)
                return
            }

            let request = ReconciliationRequest()
            request.waiters.append(continuation)
            pendingReconciliation = request
            queue.insert(.reconcile(request), at: 0)
            startWorkerIfNeeded()
        }
    }

    private func startWorkerIfNeeded() {
        guard worker == nil else {
            return
        }
        worker = Task { [weak self] in
            await self?.drainQueue()
        }
    }

    private func drainQueue() async {
        while !queue.isEmpty {
            if uncertainty != nil {
                guard case .reconcile = queue[0] else {
                    break
                }
            }
            let work = queue.removeFirst()
            await process(work)
        }
        worker = nil
        if uncertainty == nil, !queue.isEmpty {
            startWorkerIfNeeded()
        }
    }

    private func process(_ work: Work) async {
        switch work {
        case .readControl(let request):
            await processControlRead(request)
        case .begin(let request):
            await processBegin(request)
        case .append(let request):
            await processAppend(request)
        case .stop(let request):
            await processStop(request)
        case .retryStop(let request):
            await processStopRetry(request)
        case .reconcile(let request):
            await processReconciliation(request)
        }
    }

    private func processControlRead(_ request: ControlRead) async {
        do {
            let snapshot = try await persistence.readControl()
            guard isValid(snapshot) else {
                throw LocalCaptureCoordinatorError.invalidControlSnapshot
            }
            controlSnapshot = snapshot
            adopt(snapshot)
            pendingControlRead = nil
            resume(&request.waiters, returning: snapshot)
        } catch {
            pendingControlRead = nil
            resume(&request.waiters, throwing: error)
        }
    }

    private func processBegin(_ request: BeginRequest) async {
        var returnedReceipt: CaptureControlReceipt?
        do {
            let receipt = try await persistence.beginRecording(
                recordingID: request.recordingID,
                expectedControlRevision: request.expectedControlRevision,
                operationID: request.operationID
            )
            returnedReceipt = receipt
            request.receipt = receipt
            guard validBeginReceipt(receipt, request: request) else {
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }

            let snapshot = try await persistence.readControl()
            guard isValid(snapshot), isCurrentBegin(receipt, in: snapshot) else {
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }
            controlSnapshot = snapshot
            pendingBegin = nil

            pendingStop?.epoch = receipt.epoch
            guard pendingStop == nil, runtimeGeneration == request.generation else {
                admissionOpen = false
                state = .stopping(operationID: pendingStop?.operationID ?? request.operationID, epoch: receipt.epoch)
                resume(&request.waiters, throwing: LocalCaptureCoordinatorError.supersededByStop)
                return
            }

            let handle = runtime.start(epoch: receipt.epoch, generation: request.generation)
            runtimeOwner = RuntimeOwner(epoch: receipt.epoch, generation: request.generation, handle: handle)
            admissionOpen = true
            state = .active(epoch: receipt.epoch, generation: request.generation, controlRevision: snapshot.revision)
            resume(&request.waiters, returning: receipt.epoch)
        } catch {
            if isDefinitelyNotCommitted(error) {
                if isStaleFence(error) {
                    await refreshAfterStaleFence()
                    pendingBegin = nil
                    if let controlSnapshot {
                        stateFromSnapshotWithoutRuntime(controlSnapshot)
                    } else if let pendingStop {
                        state = .stopping(operationID: pendingStop.operationID, epoch: pendingStop.epoch)
                    } else {
                        state = .unready
                    }
                } else {
                    pendingBegin = nil
                    restoreStateAfterFailedBegin(request)
                }
                resume(&request.waiters, throwing: error)
                return
            }

            pendingBegin = nil
            setUncertainty(
                .begin(request),
                reason: uncertaintyReason(for: error, receiptWasReturned: returnedReceipt != nil)
            )
            resume(&request.waiters, throwing: LocalCaptureCoordinatorError.unresolvedOperation(request.operationID))
        }
    }

    private func processAppend(_ request: AppendRequest) async {
        guard controlSnapshot?.activeEpoch == request.epoch else {
            release(request)
            resume(&request.waiters, throwing: CapturePersistenceError.staleEpoch)
            return
        }

        var returnedReceipt: CaptureBatchReceipt?
        do {
            let receipt = try await persistence.appendBatch(
                request.input.samples,
                epoch: request.epoch,
                operationID: request.operationID,
                now: request.now
            )
            returnedReceipt = receipt
            request.receipt = receipt
            guard validBatchReceipt(receipt, request: request) else {
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }

            let snapshot = try await persistence.readControl()
            guard isValid(snapshot) else {
                throw LocalCaptureCoordinatorError.invalidControlSnapshot
            }
            if snapshot.hasSameRecordingIntent(as: request.controlBefore) {
                controlSnapshot = snapshot
                release(request)
                resume(&request.waiters, returning: receipt)
                return
            }

            controlSnapshot = snapshot
            closeRuntimeAndAdvanceGeneration()
            stateFromSnapshotWithoutRuntime(snapshot)
            release(request)
            resume(&request.waiters, returning: receipt)
        } catch {
            if isDefinitelyNotCommitted(error) {
                release(request)
                if isStaleFence(error) {
                    await refreshAfterStaleFence()
                }
                resume(&request.waiters, throwing: error)
                return
            }

            setUncertainty(
                .append(request),
                reason: uncertaintyReason(for: error, receiptWasReturned: returnedReceipt != nil)
            )
            resume(&request.waiters, throwing: LocalCaptureCoordinatorError.unresolvedOperation(request.operationID))
        }
    }

    private func processStop(_ request: StopRequest) async {
        guard let snapshot = controlSnapshot else {
            request.status = .failed
            request.retryAllowed = true
            state = .stopUnconfirmed(operationID: request.operationID, epoch: request.epoch)
            failStop(request, with: LocalCaptureCoordinatorError.stopUnconfirmed(request.operationID))
            return
        }
        guard let epoch = snapshot.activeEpoch else {
            controlSnapshot = snapshot
            pendingStop = nil
            state = .stopped(controlRevision: snapshot.revision)
            resume(&request.waiters, returning: .alreadyStopped(snapshot))
            return
        }
        guard request.epoch == epoch else {
            setUncertainty(.stop(request), reason: .controlChanged)
            failStop(request, with: LocalCaptureCoordinatorError.unresolvedOperation(request.operationID))
            return
        }

        request.expectedControlRevision = snapshot.revision
        request.controlBefore = snapshot
        request.status = .running
        let digest = CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: snapshot.revision)
        var returnedReceipt: CaptureControlReceipt?
        do {
            let receipt = try await persistence.stopRecording(
                epoch: epoch,
                expectedControlRevision: snapshot.revision,
                operationID: request.operationID
            )
            returnedReceipt = receipt
            request.receipt = receipt
            guard validStopReceipt(receipt, operationID: request.operationID, epoch: epoch, expectedControlRevision: snapshot.revision, digest: digest) else {
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }

            let current = try await persistence.readControl()
            guard isValid(current), isCurrentStop(receipt, in: current) else {
                if isValid(current) {
                    controlSnapshot = current
                }
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }
            guard runtimeGeneration == request.generation, pendingStop === request else {
                throw LocalCaptureCoordinatorError.receiptMismatch(request.operationID)
            }

            controlSnapshot = current
            pendingStop = nil
            request.status = .running
            state = .stopped(controlRevision: current.revision)
            admissionOpen = false
            resume(&request.waiters, returning: .stopped(receipt))
        } catch {
            if isDefinitelyNotCommitted(error) {
                request.status = .failed
                request.retryAllowed = true
                state = .stopUnconfirmed(operationID: request.operationID, epoch: request.epoch)
                failStop(request, with: LocalCaptureCoordinatorError.stopUnconfirmed(request.operationID))
                return
            }

            request.status = .uncertain
            setUncertainty(
                .stop(request),
                reason: uncertaintyReason(for: error, receiptWasReturned: returnedReceipt != nil)
            )
            failStop(request, with: LocalCaptureCoordinatorError.unresolvedOperation(request.operationID))
        }
    }

    private func processStopRetry(_ request: StopRequest) async {
        do {
            let reopened = try await reopenVerifiedStore()
            let snapshot = try await reopened.readControl()
            guard isValid(snapshot) else {
                throw LocalCaptureCoordinatorError.invalidControlSnapshot
            }
            persistence = reopened

            if let receipt = snapshot.lastControlReceipt,
               receipt.operationID == request.operationID,
               let epoch = request.epoch,
               let expectedRevision = request.expectedControlRevision,
               validStopReceipt(
                    receipt,
                    operationID: request.operationID,
                    epoch: epoch,
                    expectedControlRevision: expectedRevision,
                    digest: CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: expectedRevision)
               ),
               isCurrentStop(receipt, in: snapshot) {
                controlSnapshot = snapshot
                pendingStop = nil
                state = .stopped(controlRevision: snapshot.revision)
                resume(&request.waiters, returning: .stopped(receipt))
                return
            }

            guard snapshot.hasSameRecordingIntent(as: request.controlBefore),
                  snapshot.activeEpoch == request.epoch else {
                controlSnapshot = snapshot
                request.status = .uncertain
                setUncertainty(.stop(request), reason: .controlChanged)
                failStop(request, with: LocalCaptureCoordinatorError.unresolvedOperation(request.operationID))
                return
            }

            controlSnapshot = snapshot
            request.retryAllowed = false
            request.status = .queued
            await processStop(request)
        } catch {
            request.status = .failed
            request.retryAllowed = true
            state = .stopUnconfirmed(operationID: request.operationID, epoch: request.epoch)
            failStop(request, with: LocalCaptureCoordinatorError.stopUnconfirmed(request.operationID))
        }
    }

    private func processReconciliation(_ request: ReconciliationRequest) async {
        guard let uncertain = uncertainty else {
            pendingReconciliation = nil
            resume(&request.waiters, returning: .nothingToReconcile)
            return
        }

        let reopened: any LocalCapturePersistence
        let snapshot: CaptureControlSnapshot
        do {
            reopened = try await reopenVerifiedStore()
            snapshot = try await reopened.readControl()
        } catch {
            finishReconciliation(request, with: .unresolved(uncertain.operationID, .reopenUnavailable))
            return
        }
        guard isValid(snapshot) else {
            finishReconciliation(request, with: .unresolved(uncertain.operationID, .controlChanged))
            return
        }
        persistence = reopened
        controlSnapshot = snapshot

        let lookup: CaptureReceiptLookup
        do {
            lookup = try await reopened.lookupReceipt(operationID: uncertain.operationID)
        } catch {
            finishReconciliation(request, with: .unresolved(uncertain.operationID, .receiptUnavailable))
            return
        }
        let result = await reconcile(uncertain, lookup: lookup, snapshot: snapshot, persistence: reopened)
        finishReconciliation(request, with: result)
    }

    private func finishReconciliation(
        _ request: ReconciliationRequest,
        with result: LocalCaptureReconciliationResult
    ) {
        pendingReconciliation = nil
        if case let .unresolved(operationID, reason) = result,
           let uncertainty,
           uncertainty.operationID == operationID {
            state = .uncertain(operationID: operationID, kind: uncertainty.kind, reason: reason)
        }
        resume(&request.waiters, returning: result)
        if uncertainty == nil {
            startWorkerIfNeeded()
        }
    }

    private func reconcile(
        _ uncertain: UncertainOperation,
        lookup: CaptureReceiptLookup,
        snapshot: CaptureControlSnapshot,
        persistence: any LocalCapturePersistence
    ) async -> LocalCaptureReconciliationResult {
        switch uncertain {
        case .begin(let request):
            return reconcileBegin(request, lookup: lookup, snapshot: snapshot)
        case .stop(let request):
            return reconcileStop(request, lookup: lookup, snapshot: snapshot)
        case .append(let request):
            return await reconcileAppend(request, lookup: lookup, snapshot: snapshot, persistence: persistence)
        }
    }

    private func reconcileBegin(
        _ request: BeginRequest,
        lookup: CaptureReceiptLookup,
        snapshot: CaptureControlSnapshot
    ) -> LocalCaptureReconciliationResult {
        let matched: CaptureControlReceipt?
        switch lookup {
        case .found(.control(let receipt)) where validBeginReceipt(receipt, request: request):
            matched = receipt
        case .found:
            return unresolved(request.operationID, kind: .begin, reason: .receiptMismatch)
        case .unavailable:
            if let returnedReceipt = request.receipt,
               validBeginReceipt(returnedReceipt, request: request) {
                matched = returnedReceipt
            } else if let durableReceipt = snapshot.lastControlReceipt,
                      validBeginReceipt(durableReceipt, request: request),
                      isCurrentBegin(durableReceipt, in: snapshot) {
                matched = durableReceipt
            } else {
                matched = request.receipt
            }
        }

        if let matched, validBeginReceipt(matched, request: request) {
            uncertainty = nil
            pendingBegin = nil
            if let pendingStop {
                pendingStop.epoch = matched.epoch
                state = .stopping(operationID: pendingStop.operationID, epoch: snapshot.activeEpoch)
            } else {
                stateFromSnapshotWithoutRuntime(snapshot)
            }
            return .beginCommitted(matched)
        }
        guard matched == nil, snapshot.hasSameRecordingIntent(as: request.controlBefore) else {
            return unresolved(request.operationID, kind: .begin, reason: .controlChanged)
        }

        uncertainty = nil
        pendingBegin = nil
        if pendingStop != nil {
            state = .stopping(operationID: pendingStop!.operationID, epoch: snapshot.activeEpoch)
        } else {
            stateFromSnapshotWithoutRuntime(snapshot)
        }
        return .knownNotCommitted(request.operationID)
    }

    private func reconcileStop(
        _ request: StopRequest,
        lookup: CaptureReceiptLookup,
        snapshot: CaptureControlSnapshot
    ) -> LocalCaptureReconciliationResult {
        guard let epoch = request.epoch,
              let expectedRevision = request.expectedControlRevision else {
            return unresolved(request.operationID, kind: .stop, reason: .controlChanged)
        }
        let digest = CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: expectedRevision)
        let matched: CaptureControlReceipt?
        switch lookup {
        case .found(.control(let receipt)) where validStopReceipt(
            receipt,
            operationID: request.operationID,
            epoch: epoch,
            expectedControlRevision: expectedRevision,
            digest: digest
        ):
            matched = receipt
        case .found:
            return unresolved(request.operationID, kind: .stop, reason: .receiptMismatch)
        case .unavailable:
            if let receipt = request.receipt,
               validStopReceipt(
                    receipt,
                    operationID: request.operationID,
                    epoch: epoch,
                    expectedControlRevision: expectedRevision,
                    digest: digest
               ) {
                matched = receipt
            } else if let receipt = snapshot.lastControlReceipt,
               validStopReceipt(
                    receipt,
                    operationID: request.operationID,
                    epoch: epoch,
                    expectedControlRevision: expectedRevision,
                    digest: digest
               ), isCurrentStop(receipt, in: snapshot) {
                matched = receipt
            } else {
                matched = nil
            }
        }

        if let matched {
            guard runtimeGeneration == request.generation, pendingStop === request else {
                return unresolved(request.operationID, kind: .stop, reason: .controlChanged)
            }
            uncertainty = nil
            pendingStop = nil
            stateFromSnapshotWithoutRuntime(snapshot)
            resume(&request.waiters, returning: .stopped(matched))
            return .stopCommitted(matched)
        }

        guard matched == nil, snapshot.hasSameRecordingIntent(as: request.controlBefore) else {
            return unresolved(request.operationID, kind: .stop, reason: .controlChanged)
        }

        uncertainty = nil
        request.status = .failed
        request.retryAllowed = true
        state = .stopUnconfirmed(operationID: request.operationID, epoch: request.epoch)
        return .knownNotCommitted(request.operationID)
    }

    private func reconcileAppend(
        _ request: AppendRequest,
        lookup: CaptureReceiptLookup,
        snapshot: CaptureControlSnapshot,
        persistence: any LocalCapturePersistence
    ) async -> LocalCaptureReconciliationResult {
        if case .found(.batch(let receipt)) = lookup {
            guard validBatchReceipt(receipt, request: request) else {
                return unresolved(request.operationID, kind: .append, reason: .receiptMismatch)
            }
            uncertainty = nil
            release(request)
            stateFromSnapshotWithoutRuntime(snapshot)
            return .appendCommitted(receipt)
        }
        if case .found = lookup {
            return unresolved(request.operationID, kind: .append, reason: .receiptMismatch)
        }
        if let receipt = request.receipt {
            guard validBatchReceipt(receipt, request: request) else {
                return unresolved(request.operationID, kind: .append, reason: .receiptMismatch)
            }
            uncertainty = nil
            release(request)
            stateFromSnapshotWithoutRuntime(snapshot)
            return .appendCommitted(receipt)
        }

        do {
            let matches = try await persistence.reconcileSamples(request.input.samples, epoch: request.epoch)
            guard matches.map(\.sampleID) == request.input.samples.map(\.id) else {
                return unresolved(request.operationID, kind: .append, reason: .receiptMismatch)
            }
            if matches.contains(where: { $0.match == .conflicting }) {
                return unresolved(request.operationID, kind: .append, reason: .sampleConflict)
            }
            guard matches.allSatisfy({ $0.match == .matching }) else {
                return unresolved(request.operationID, kind: .append, reason: .sampleAbsentOrExpired)
            }
            uncertainty = nil
            release(request)
            stateFromSnapshotWithoutRuntime(snapshot)
            return .appendSamplesMatched(request.operationID)
        } catch {
            return unresolved(request.operationID, kind: .append, reason: .receiptUnavailable)
        }
    }

    private func failStop(_ request: StopRequest, with error: any Error) {
        let waiters = request.waiters
        request.waiters = []
        for waiter in waiters {
            waiter.resume(throwing: error)
        }
    }

    private func setUncertainty(_ operation: UncertainOperation, reason: LocalCaptureUncertaintyReason) {
        uncertainty = operation
        if runtimeOwner != nil {
            closeRuntimeAndAdvanceGeneration()
        } else {
            admissionOpen = false
        }
        state = .uncertain(operationID: operation.operationID, kind: operation.kind, reason: reason)
        if case .stop(let request) = operation {
            request.status = .uncertain
        }
    }

    private func unresolved(
        _ operationID: UUID,
        kind: LocalCaptureUncertaintyKind,
        reason: LocalCaptureUncertaintyReason
    ) -> LocalCaptureReconciliationResult {
        state = .uncertain(operationID: operationID, kind: kind, reason: reason)
        return .unresolved(operationID, reason)
    }

    private func adopt(_ snapshot: CaptureControlSnapshot) {
        if pendingStop != nil || pendingBegin != nil {
            return
        }
        if let owner = runtimeOwner, snapshot.activeEpoch == owner.epoch {
            admissionOpen = true
            state = .active(epoch: owner.epoch, generation: owner.generation, controlRevision: snapshot.revision)
            return
        }
        if runtimeOwner != nil {
            closeRuntimeAndAdvanceGeneration()
        }
        stateFromSnapshotWithoutRuntime(snapshot)
    }

    private func stateFromSnapshotWithoutRuntime(_ snapshot: CaptureControlSnapshot) {
        admissionOpen = false
        if let pendingStop {
            state = .stopping(operationID: pendingStop.operationID, epoch: snapshot.activeEpoch)
            return
        }
        if let epoch = snapshot.activeEpoch {
            state = .resumeRequired(epoch: epoch, controlRevision: snapshot.revision)
        } else {
            state = .stopped(controlRevision: snapshot.revision)
        }
    }

    private func restoreStateAfterFailedBegin(_ request: BeginRequest) {
        guard pendingStop == nil, runtimeGeneration == request.generation else {
            if let pendingStop {
                state = .stopping(operationID: pendingStop.operationID, epoch: controlSnapshot?.activeEpoch)
            }
            admissionOpen = false
            return
        }
        stateFromSnapshotWithoutRuntime(request.controlBefore)
    }

    private func closeRuntimeAndAdvanceGeneration() {
        runtimeGeneration = UUID()
        admissionOpen = false
        runtimeOwner?.handle.stop()
        runtimeOwner = nil
    }

    private func refreshAfterStaleFence() async {
        closeRuntimeAndAdvanceGeneration()
        do {
            let snapshot = try await persistence.readControl()
            guard isValid(snapshot) else {
                throw LocalCaptureCoordinatorError.invalidControlSnapshot
            }
            controlSnapshot = snapshot
            if let pendingStop {
                state = .stopping(operationID: pendingStop.operationID, epoch: snapshot.activeEpoch)
            } else if let pendingBegin {
                state = .beginning(recordingID: pendingBegin.recordingID, generation: pendingBegin.generation)
            } else {
                stateFromSnapshotWithoutRuntime(snapshot)
            }
        } catch {
            controlSnapshot = nil
            if let pendingStop {
                state = .stopping(operationID: pendingStop.operationID, epoch: pendingStop.epoch)
            } else if let pendingBegin {
                state = .beginning(recordingID: pendingBegin.recordingID, generation: pendingBegin.generation)
            } else {
                state = .unready
            }
        }
    }

    private func release(_ request: AppendRequest) {
        guard !request.isReleased else {
            return
        }
        request.isReleased = true
        pendingSampleCount -= request.input.samples.count
        pendingEncodedPayloadBytes -= request.input.encodedPayloadBytes
        pendingAppends.removeValue(forKey: request.operationID)
    }

    private func validBeginReceipt(_ receipt: CaptureControlReceipt, request: BeginRequest) -> Bool {
        request.expectedControlRevision < Int64.max
            && receipt.operationID == request.operationID
            && receipt.kind == .begin
            && receipt.epoch.recordingID == request.recordingID
            && receipt.epoch.revision == receipt.controlRevision
            && receipt.controlRevision == request.expectedControlRevision + 1
            && receipt.commandDigest == CaptureCommandDigest.begin(
                recordingID: request.recordingID,
                expectedControlRevision: request.expectedControlRevision
            )
    }

    private func validStopReceipt(
        _ receipt: CaptureControlReceipt,
        operationID: UUID,
        epoch: CaptureEpoch,
        expectedControlRevision: Int64,
        digest: String
    ) -> Bool {
        expectedControlRevision < Int64.max
            && receipt.operationID == operationID
            && receipt.kind == .stop
            && receipt.epoch == epoch
            && receipt.controlRevision == expectedControlRevision + 1
            && receipt.commandDigest == digest
    }

    private func validBatchReceipt(_ receipt: CaptureBatchReceipt, request: AppendRequest) -> Bool {
        receipt.operationID == request.operationID
            && receipt.epoch == request.epoch
            && receipt.commandDigest == request.digest
            && receipt.items.map(\.sampleID) == request.input.samples.map(\.id)
    }

    private func isCurrentBegin(_ receipt: CaptureControlReceipt, in snapshot: CaptureControlSnapshot) -> Bool {
        snapshot.revision == receipt.controlRevision
            && snapshot.activeEpoch == receipt.epoch
            && snapshot.lastControlReceipt == receipt
    }

    private func isCurrentStop(_ receipt: CaptureControlReceipt, in snapshot: CaptureControlSnapshot) -> Bool {
        snapshot.revision == receipt.controlRevision
            && snapshot.activeEpoch == nil
            && snapshot.lastControlReceipt == receipt
    }

    private func isValid(_ snapshot: CaptureControlSnapshot) -> Bool {
        guard snapshot.revision >= 0, snapshot.hasValidHistoryState else {
            return false
        }
        if let epoch = snapshot.activeEpoch, epoch.revision <= 0 {
            return false
        }
        guard let receipt = snapshot.lastControlReceipt else {
            return snapshot.revision == 0 && snapshot.activeEpoch == nil
        }
        guard receipt.controlRevision == snapshot.revision,
              receipt.epoch.revision > 0,
              receipt.epoch.revision <= snapshot.revision else {
            return false
        }
        switch receipt.kind {
        case .begin:
            return snapshot.activeEpoch == receipt.epoch && receipt.epoch.revision == snapshot.revision
        case .stop:
            return snapshot.activeEpoch == nil && receipt.epoch.revision < snapshot.revision
        }
    }

    private func isDefinitelyNotCommitted(_ error: any Error) -> Bool {
        guard let error = error as? CapturePersistenceError else {
            return false
        }
        switch error {
        case .outcomeUncertain, .unavailable:
            return false
        case .notFoundationStore, .invalidControlState, .staleControlRevision, .staleEpoch,
             .activeRecordingMismatch, .revisionExhausted, .operationConflict, .batchTooLarge,
             .invalidHistoryRequest, .invalidCursor, .cursorInvalidated, .oversizedRecord, .recordingActive,
             .notCommitted:
            return true
        }
    }

    private func isStaleFence(_ error: any Error) -> Bool {
        guard let error = error as? CapturePersistenceError else {
            return false
        }
        switch error {
        case .staleControlRevision, .staleEpoch:
            return true
        default:
            return false
        }
    }

    private func uncertaintyReason(for error: any Error, receiptWasReturned: Bool) -> LocalCaptureUncertaintyReason {
        if let persistenceError = error as? CapturePersistenceError,
           case .outcomeUncertain = persistenceError {
            return .persistenceOutcome
        }
        return receiptWasReturned ? .receiptMismatch : .persistenceOutcome
    }

    private func resume<Value: Sendable>(
        _ waiters: inout [CheckedContinuation<Value, any Error>],
        returning value: Value
    ) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume(returning: value)
        }
    }

    private func resume<Value>(
        _ waiters: inout [CheckedContinuation<Value, any Error>],
        throwing error: any Error
    ) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume(throwing: error)
        }
    }
}
