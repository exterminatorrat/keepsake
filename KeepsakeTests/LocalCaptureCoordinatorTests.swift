import Foundation
import Testing
@testable import Keepsake

@MainActor
struct LocalCaptureCoordinatorTests {
    @Test(.timeLimit(.minutes(1)))
    func historyMaintenanceDuringAppendDoesNotStopTheRecordingOwner() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let input = try makeInput(recordingID: epoch.recordingID, count: 1, startingAt: 1)
        await store.gateNextAppend()

        let append = Task {
            try await coordinator.append(input, now: Date(timeIntervalSinceReferenceDate: 100))
        }
        await store.waitForAppendCall()
        await store.advanceHistoryDeletionRevision()
        await store.releaseAppend()
        let receipt = try await append.value

        #expect(receipt.items.allSatisfy { $0.disposition == .stored })
        #expect(coordinator.controlSnapshot?.deletionRevision == 1)
        #expect(coordinator.controlSnapshot?.activeEpoch == epoch)
        #expect(coordinator.isAcceptingSamples)
        #expect(coordinator.pendingSampleCount == 0)
        #expect(runtime.startedEpochs == [epoch])
        #expect(runtime.stopCallCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func beginReceiptPrecedesRuntimeAndRepeatedStartReusesTheOwner() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        _ = try await coordinator.refreshControl()
        await store.gateNextBegin()

        let recordingID = UUID()
        let begin = Task { try await coordinator.startRecording(recordingID: recordingID) }
        await store.waitForBeginCall()

        #expect(runtime.startedEpochs.isEmpty)
        #expect(!coordinator.isAcceptingSamples)

        await store.releaseBegin()
        let epoch = try await begin.value
        let repeated = try await coordinator.startRecording(recordingID: recordingID)

        #expect(repeated == epoch)
        #expect(runtime.startedEpochs == [epoch])
        let beginCalls = await store.beginCallCount()
        #expect(beginCalls == 1)
        #expect(coordinator.isAcceptingSamples)
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeInterruptionPreservesVerifiedIntentWithoutPersistence() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        guard case .active(_, let generation, _) = coordinator.state else {
            Issue.record("Expected an active runtime owner")
            return
        }
        let controlBefore = try await store.readControl()

        #expect(coordinator.runtimeInterrupted(epoch: epoch, generation: generation))

        #expect(coordinator.state == .resumeRequired(epoch: epoch, controlRevision: controlBefore.revision))
        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.stopCallCount == 1)
        let controlAfter = try await store.readControl()
        let persistedStopCalls = await store.stopCallCount()
        #expect(controlAfter == controlBefore)
        #expect(persistedStopCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeInterruptionPreservesAdmittedAppendAndItsReceipt() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        guard case .active(_, let generation, _) = coordinator.state else {
            Issue.record("Expected an active runtime owner")
            return
        }
        let input = try makeInput(recordingID: epoch.recordingID, count: 1, startingAt: 1)
        let operationID = UUID()
        await store.gateNextAppend()

        let append = Task {
            try await coordinator.append(
                input,
                now: Date(timeIntervalSinceReferenceDate: 100),
                operationID: operationID
            )
        }
        await store.waitForAppendCall()
        #expect(coordinator.pendingSampleCount == 1)
        #expect(coordinator.runtimeInterrupted(epoch: epoch, generation: generation))
        #expect(coordinator.pendingSampleCount == 1)
        #expect(coordinator.state == .resumeRequired(epoch: epoch, controlRevision: epoch.revision))

        await store.releaseAppend()
        let receipt = try await append.value
        let lookup = try await store.lookupReceipt(operationID: operationID)
        guard case .found(.batch(let storedReceipt)) = lookup else {
            Issue.record("Runtime interruption discarded the admitted append receipt")
            return
        }

        #expect(receipt == storedReceipt)
        #expect(receipt.items.allSatisfy { $0.disposition == .stored })
        #expect(coordinator.pendingSampleCount == 0)
        #expect(coordinator.state == .resumeRequired(epoch: epoch, controlRevision: epoch.revision))
        #expect(runtime.stopCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleRuntimeInterruptionCannotCloseExplicitlyResumedGeneration() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let oldEpoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        guard case .active(_, let oldGeneration, _) = coordinator.state else {
            Issue.record("Expected an active runtime owner")
            return
        }
        #expect(coordinator.runtimeInterrupted(epoch: oldEpoch, generation: oldGeneration))

        let resumedEpoch = try await coordinator.startRecording(recordingID: oldEpoch.recordingID)
        guard case .active(_, let resumedGeneration, _) = coordinator.state else {
            Issue.record("Explicit resume did not install a runtime owner")
            return
        }

        #expect(resumedEpoch.revision > oldEpoch.revision)
        #expect(!coordinator.runtimeInterrupted(epoch: oldEpoch, generation: oldGeneration))
        #expect(coordinator.state == .active(
            epoch: resumedEpoch,
            generation: resumedGeneration,
            controlRevision: resumedEpoch.revision
        ))
        #expect(coordinator.isAcceptingSamples)
        #expect(runtime.startedEpochs == [oldEpoch, resumedEpoch])
        #expect(runtime.stopCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func runtimeInterruptionCannotOverridePendingStop() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        guard case .active(_, let generation, _) = coordinator.state else {
            Issue.record("Expected an active runtime owner")
            return
        }
        await store.gateNextStop()

        let stop = Task { try await coordinator.stopRecording() }
        await store.waitForStopCall()

        let stopIDs = await store.stopIDs()
        let operationID = try #require(stopIDs.last)
        #expect(coordinator.state == .stopping(operationID: operationID, epoch: epoch))
        #expect(!coordinator.runtimeInterrupted(epoch: epoch, generation: generation))
        #expect(runtime.stopCallCount == 1)

        await store.releaseStop()
        guard case .stopped(let receipt) = try await stop.value else {
            Issue.record("Pending Stop did not complete")
            return
        }
        #expect(receipt.epoch == epoch)
        #expect(coordinator.state == .stopped(controlRevision: receipt.controlRevision))
    }

    @Test(.timeLimit(.minutes(1)))
    func stopDuringPendingBeginFencesTheEpochThatCommits() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        _ = try await coordinator.refreshControl()
        await store.gateNextBegin()

        let recordingID = UUID()
        let begin = Task { try await coordinator.startRecording(recordingID: recordingID) }
        await store.waitForBeginCall()
        let stop = Task { try await coordinator.stopRecording() }
        await waitUntil {
            if case .stopping = coordinator.state { return true }
            return false
        }

        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.startedEpochs.isEmpty)

        await store.releaseBegin()
        await expectError(LocalCaptureCoordinatorError.supersededByStop) {
            try await begin.value
        }
        let result = try await stop.value
        guard case .stopped(let receipt) = result else {
            Issue.record("Stop did not return its durable receipt")
            return
        }

        #expect(receipt.kind == .stop)
        #expect(receipt.epoch.recordingID == recordingID)
        #expect(receipt.epoch.revision == 1)
        #expect(receipt.controlRevision == 2)
        #expect(runtime.startedEpochs.isEmpty)
        #expect(runtime.stopCallCount == 0)
        let stopCalls = await store.stopCallCount()
        let events = await store.eventLog()
        #expect(stopCalls == 1)
        #expect(events == ["begin.started", "begin.committed", "stop.started", "stop.committed"])
    }

    @Test(.timeLimit(.minutes(1)))
    func admittedAppendFinishesBeforeStopAndClosesAdmissionImmediately() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let recordingID = try #require(coordinator.controlSnapshot?.activeEpoch?.recordingID)
        let input = try makeInput(recordingID: recordingID, count: 2, startingAt: 1)
        await store.clearEventLog()
        await store.gateNextAppend()

        let append = Task {
            try await coordinator.append(input, now: Date(timeIntervalSinceReferenceDate: 100))
        }
        await store.waitForAppendCall()
        let stop = Task { try await coordinator.stopRecording() }
        await waitUntil {
            if case .stopping = coordinator.state { return true }
            return false
        }

        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.stopCallCount == 1)
        #expect(coordinator.pendingSampleCount == input.samples.count)
        let stopCallsBeforeAppendReleased = await store.stopCallCount()
        #expect(stopCallsBeforeAppendReleased == 0)

        await store.releaseAppend()
        let batchReceipt = try await append.value
        let stopResult = try await stop.value
        guard case .stopped(let stopReceipt) = stopResult else {
            Issue.record("Stop did not return its durable receipt")
            return
        }

        #expect(batchReceipt.items.map(\.sampleID) == input.samples.map(\.id))
        #expect(batchReceipt.items.allSatisfy { $0.disposition == .stored })
        #expect(stopReceipt.epoch == batchReceipt.epoch)
        #expect(coordinator.pendingSampleCount == 0)
        let events = await store.eventLog()
        #expect(events == ["append.started", "append.committed", "stop.started", "stop.committed"])
        await expectError(LocalCaptureCoordinatorError.storageNotReady) {
            try await coordinator.append(input, now: Date(timeIntervalSinceReferenceDate: 300))
        }
        let appendCallsAfterStop = await store.appendCallCount()
        #expect(appendCallsAfterStop == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func failedStopNeedsAnExplicitVerifiedReopenAndRetry() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        await store.setNextStopBehavior(.notCommitted)

        let error = await capturedError { try await coordinator.stopRecording() }
        guard let operationID = coordinatorStopOperationID(from: error) else {
            Issue.record("Failed Stop did not retain its operation identity")
            return
        }
        #expect(error as? LocalCaptureCoordinatorError == .stopUnconfirmed(operationID))
        #expect(coordinator.state == .stopUnconfirmed(operationID: operationID, epoch: coordinator.controlSnapshot?.activeEpoch))
        #expect(!coordinator.isAcceptingSamples)
        let stopCallsBeforeRetry = await store.stopCallCount()
        #expect(stopCallsBeforeRetry == 1)
        await expectError(LocalCaptureCoordinatorError.stopPending) {
            try await coordinator.startRecording(recordingID: UUID())
        }

        let retry = try await coordinator.retryStop()
        guard case .stopped(let receipt) = retry else {
            Issue.record("Explicit retry did not return a durable Stop receipt")
            return
        }
        let stopIDs = await store.stopIDs()
        let reopenCount = await store.reopenCount()
        #expect(receipt.operationID == operationID)
        #expect(stopIDs == [operationID, operationID])
        #expect(reopenCount == 1)
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainCommittedStopReconcilesWithoutRestartingRuntime() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        guard case .active(_, let generation, _) = coordinator.state else {
            Issue.record("Expected an active runtime owner")
            return
        }
        await store.setNextStopBehavior(.uncertainAfterCommit)

        let error = await capturedError { try await coordinator.stopRecording() }
        guard let operationID = coordinatorOperationID(from: error) else {
            Issue.record("Uncertain Stop did not retain its operation identity")
            return
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        #expect(!coordinator.runtimeInterrupted(epoch: epoch, generation: generation))

        let result = try await coordinator.reconcileUncertain()
        guard case .stopCommitted(let receipt) = result else {
            Issue.record("Reconciliation did not confirm the committed Stop")
            return
        }

        let stopCalls = await store.stopCallCount()
        let reopenCount = await store.reopenCount()
        #expect(receipt.kind == .stop)
        #expect(stopCalls == 1)
        #expect(reopenCount == 1)
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
        #expect(!coordinator.isAcceptingSamples)
        #expect(coordinator.state == .stopped(controlRevision: receipt.controlRevision))
    }

    @Test(.timeLimit(.minutes(1)))
    func oldStopReceiptReconciliationPreservesNewerActiveIntent() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let stoppedEpoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        await store.setNextStopBehavior(.uncertainAfterCommit)

        let error = await capturedError { try await coordinator.stopRecording() }
        guard let operationID = coordinatorOperationID(from: error) else {
            Issue.record("Uncertain Stop did not retain its operation identity")
            return
        }
        let newBegin = try await store.beginExternally(recordingID: stoppedEpoch.recordingID)

        let result = try await coordinator.reconcileUncertain()
        guard case .stopCommitted(let receipt) = result else {
            Issue.record("Reconciliation did not confirm the committed Stop")
            return
        }

        #expect(receipt.operationID == operationID)
        #expect(receipt.epoch == stoppedEpoch)
        #expect(coordinator.controlSnapshot?.activeEpoch == newBegin.epoch)
        #expect(coordinator.state == .resumeRequired(epoch: newBegin.epoch, controlRevision: newBegin.controlRevision))
        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func unavailableStopReceiptDoesNotTriggerRetryOrRuntimeRestart() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        await store.setNextStopBehavior(.uncertainBeforeCommit)
        await store.setReceiptLookupUnavailable(true)

        let firstError = await capturedError { try await coordinator.stopRecording() }
        guard let operationID = coordinatorOperationID(from: firstError) else {
            Issue.record("Stop did not preserve its uncertain operation identity")
            return
        }
        #expect(firstError as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))

        let result = try await coordinator.reconcileUncertain()
        let stopCalls = await store.stopCallCount()
        let reopenCount = await store.reopenCount()
        #expect(result == .knownNotCommitted(operationID))
        #expect(coordinator.state == .stopUnconfirmed(operationID: operationID, epoch: coordinator.controlSnapshot?.activeEpoch))
        #expect(stopCalls == 1)
        #expect(reopenCount == 1)
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
        await expectError(LocalCaptureCoordinatorError.stopPending) {
            try await coordinator.startRecording(recordingID: UUID())
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func clearPreservesStoppedControlRevisionAndLatestStopReceipt() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let input = try makeInput(recordingID: epoch.recordingID, count: 1, startingAt: 1)
        let batchReceipt = try await coordinator.append(
            input,
            now: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect(batchReceipt.items.first?.disposition == .stored)

        let stopResult = try await coordinator.stopRecording()
        guard case .stopped(let stopReceipt) = stopResult else {
            Issue.record("Stop did not return its durable receipt")
            return
        }
        let before = try #require(coordinator.controlSnapshot)
        let clearReceipt = try await coordinator.clearHistory(
            expectedControlRevision: stopReceipt.controlRevision,
            operationID: UUID()
        )
        let after = try #require(coordinator.controlSnapshot)

        #expect(clearReceipt.controlRevision == stopReceipt.controlRevision)
        #expect(clearReceipt.deletionRevision == before.deletionRevision + 1)
        #expect(clearReceipt.clearedThroughSequence > before.clearedThroughSequence)
        #expect(clearReceipt.commandDigest == CaptureCommandDigest.clear(
            expectedControlRevision: stopReceipt.controlRevision
        ))
        #expect(after.revision == stopReceipt.controlRevision)
        #expect(after.activeEpoch == nil)
        #expect(after.lastControlReceipt == stopReceipt)
        #expect(after.lastClearReceipt == clearReceipt)
        #expect(after.deletionRevision == clearReceipt.deletionRevision)
        #expect(after.clearedThroughSequence == clearReceipt.clearedThroughSequence)
        #expect(coordinator.state == .stopped(controlRevision: stopReceipt.controlRevision))
        #expect(runtime.startedEpochs == [epoch])
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingClearVetoesStartUntilClearCompletes() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let operationID = UUID()
        await store.gateNextClear()

        let clear = Task {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        await store.waitForClearCall()
        await expectError(LocalCaptureCoordinatorError.historyClearPending) {
            try await coordinator.startRecording(recordingID: UUID())
        }
        #expect(runtime.startedEpochs.isEmpty)

        await store.releaseClear()
        let receipt = try await clear.value
        let epoch = try await coordinator.startRecording(recordingID: UUID())

        #expect(receipt.controlRevision == control.revision)
        #expect(epoch.revision == control.revision + 1)
        #expect(runtime.startedEpochs == [epoch])
        let clearCalls = await store.clearCallCount()
        #expect(clearCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingBeginRejectsClearWithoutCallingPersistence() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        await store.gateNextBegin()

        let begin = Task { try await coordinator.startRecording(recordingID: UUID()) }
        await store.waitForBeginCall()
        await expectError(CapturePersistenceError.recordingActive) {
            try await coordinator.clearHistory(expectedControlRevision: control.revision)
        }
        let clearCalls = await store.clearCallCount()
        #expect(clearCalls == 0)

        await store.releaseBegin()
        _ = try await begin.value
    }

    @Test(.timeLimit(.minutes(1)))
    func activeRecordingRejectsClearWithoutCallingPersistence() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let control = try #require(coordinator.controlSnapshot)

        await expectError(CapturePersistenceError.recordingActive) {
            try await coordinator.clearHistory(expectedControlRevision: control.revision)
        }
        let clearCalls = await store.clearCallCount()
        #expect(clearCalls == 0)
        #expect(runtime.startedEpochs.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func persistedActiveIntentRejectsClearWithoutStartingRuntime() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let activeReceipt = try await store.beginExternally(recordingID: UUID())
        let control = try await coordinator.refreshControl()

        await expectError(CapturePersistenceError.recordingActive) {
            try await coordinator.clearHistory(expectedControlRevision: control.revision)
        }
        let clearCalls = await store.clearCallCount()

        #expect(control.activeEpoch == activeReceipt.epoch)
        #expect(coordinator.state == .resumeRequired(
            epoch: activeReceipt.epoch,
            controlRevision: activeReceipt.controlRevision
        ))
        #expect(clearCalls == 0)
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func admittedAppendStopAndClearCommitInOrder() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let input = try makeInput(recordingID: epoch.recordingID, count: 2, startingAt: 1)
        await store.clearEventLog()
        await store.gateNextAppend()
        await store.gateNextStop()

        let append = Task {
            try await coordinator.append(
                input,
                now: Date(timeIntervalSinceReferenceDate: 100)
            )
        }
        await store.waitForAppendCall()

        let (stopStarted, stopStartSignal) = AsyncStream<Void>.makeStream()
        let stop = Task {
            stopStartSignal.yield(())
            return try await coordinator.stopRecording()
        }
        var stopStartedIterator = stopStarted.makeAsyncIterator()
        _ = await stopStartedIterator.next()

        let (clearStarted, clearStartSignal) = AsyncStream<Void>.makeStream()
        let clear = Task {
            clearStartSignal.yield(())
            return try await coordinator.clearHistory(
                expectedControlRevision: epoch.revision + 1,
                operationID: UUID()
            )
        }
        var clearStartedIterator = clearStarted.makeAsyncIterator()
        _ = await clearStartedIterator.next()
        await expectError(LocalCaptureCoordinatorError.historyClearPending) {
            try await coordinator.startRecording(recordingID: UUID())
        }

        await store.releaseAppend()
        await store.waitForStopCall()
        let eventsBeforeStopCommit = await store.eventLog()
        let clearCallsBeforeStopCommit = await store.clearCallCount()
        #expect(eventsBeforeStopCommit == ["append.started", "append.committed", "stop.started"])
        #expect(clearCallsBeforeStopCommit == 0)

        await store.releaseStop()
        let batchReceipt = try await append.value
        let stopResult = try await stop.value
        guard case .stopped(let stopReceipt) = stopResult else {
            Issue.record("Stop did not return its durable receipt")
            return
        }
        let clearReceipt = try await clear.value
        let events = await store.eventLog()

        #expect(batchReceipt.items.map(\.sampleID) == input.samples.map(\.id))
        #expect(clearReceipt.controlRevision == stopReceipt.controlRevision)
        #expect(clearReceipt.clearedThroughSequence > 0)
        #expect(events == [
            "append.started",
            "append.committed",
            "stop.started",
            "stop.committed",
            "clear.started",
            "clear.committed"
        ])
    }

    @Test(.timeLimit(.minutes(1)))
    func unconfirmedStopCannotBeBypassedByQueuedClear() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        await store.setNextStopBehavior(.notCommitted)
        await store.gateNextStop()

        let (stopStarted, stopStartSignal) = AsyncStream<Void>.makeStream()
        let stop = Task {
            stopStartSignal.yield(())
            return try await coordinator.stopRecording()
        }
        var stopStartedIterator = stopStarted.makeAsyncIterator()
        _ = await stopStartedIterator.next()

        let (clearStarted, clearStartSignal) = AsyncStream<Void>.makeStream()
        let clear = Task {
            clearStartSignal.yield(())
            return try await coordinator.clearHistory(
                expectedControlRevision: epoch.revision + 1,
                operationID: UUID()
            )
        }
        var clearStartedIterator = clearStarted.makeAsyncIterator()
        _ = await clearStartedIterator.next()
        await expectError(LocalCaptureCoordinatorError.historyClearPending) {
            try await coordinator.startRecording(recordingID: UUID())
        }

        await store.releaseStop()
        let stopError = await capturedError { try await stop.value }
        let clearError = await capturedError { try await clear.value }
        guard let stopOperationID = coordinatorStopOperationID(from: stopError) else {
            Issue.record("Unconfirmed Stop did not retain its operation identity")
            return
        }
        let clearCalls = await store.clearCallCount()

        #expect(stopError as? LocalCaptureCoordinatorError == .stopUnconfirmed(stopOperationID))
        #expect(clearError as? LocalCaptureCoordinatorError == .stopUnconfirmed(stopOperationID))
        #expect(coordinator.state == .stopUnconfirmed(operationID: stopOperationID, epoch: epoch))
        #expect(clearCalls == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleClearRevisionRefreshesControlWithoutCallingClearPersistence() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let staleControl = try await coordinator.refreshControl()
        _ = try await store.beginExternally(recordingID: UUID())
        _ = try await store.stopExternally()
        let durableControl = try await store.readControl()

        await expectError(CapturePersistenceError.staleControlRevision) {
            try await coordinator.clearHistory(expectedControlRevision: staleControl.revision)
        }
        let clearCalls = await store.clearCallCount()

        #expect(coordinator.controlSnapshot == durableControl)
        #expect(coordinator.state == .stopped(controlRevision: durableControl.revision))
        #expect(clearCalls == 0)
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func definiteClearNoncommitLeavesStartAvailable() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        await store.setNextClearBehavior(.notCommitted)

        let error = await capturedError {
            try await coordinator.clearHistory(expectedControlRevision: control.revision)
        }
        let clearCalls = await store.clearCallCount()
        #expect(error as? CapturePersistenceError == .notCommitted(.writeFailed))
        #expect(coordinator.state == .stopped(controlRevision: control.revision))
        #expect(coordinator.isStorageReady)
        #expect(clearCalls == 1)

        let epoch = try await coordinator.startRecording(recordingID: UUID())
        #expect(epoch.revision == control.revision + 1)
        #expect(runtime.startedEpochs == [epoch])
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainCommittedClearReconcilesWithoutStartingRuntime() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let operationID = UUID()
        await store.setNextClearBehavior(.uncertainAfterCommit)
        await store.setReceiptLookupUnavailable(true)

        let error = await capturedError {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .clear,
            reason: .persistenceOutcome
        ))
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.startRecording(recordingID: UUID())
        }

        let result = try await coordinator.reconcileUncertain()
        guard case .clearCommitted(let receipt) = result else {
            Issue.record("Reconciliation did not confirm the committed Clear")
            return
        }
        let durableControl = try await store.readControl()
        let clearCalls = await store.clearCallCount()
        let reopenCount = await store.reopenCount()

        #expect(receipt.operationID == operationID)
        #expect(receipt.controlRevision == control.revision)
        #expect(durableControl.revision == control.revision)
        #expect(durableControl.lastControlReceipt == control.lastControlReceipt)
        #expect(durableControl.lastClearReceipt == receipt)
        #expect(coordinator.controlSnapshot == durableControl)
        #expect(coordinator.state == .stopped(controlRevision: control.revision))
        #expect(clearCalls == 1)
        #expect(reopenCount == 1)
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearReconciliationRejectsReceiptsWithStaleHistoryBounds() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let epoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let input = try makeInput(recordingID: epoch.recordingID, count: 2, startingAt: 1)
        let batchReceipt = try await coordinator.append(
            input,
            now: Date(timeIntervalSinceReferenceDate: 100)
        )
        #expect(batchReceipt.items.allSatisfy { $0.disposition == .stored })

        let stopResult = try await coordinator.stopRecording()
        guard case .stopped(let stopReceipt) = stopResult else {
            Issue.record("Stop did not return its durable receipt")
            return
        }
        let operationID = UUID()
        await store.setNextClearBehavior(.uncertainAfterCommit)
        let error = await capturedError {
            try await coordinator.clearHistory(
                expectedControlRevision: stopReceipt.controlRevision,
                operationID: operationID
            )
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))

        let durableControl = try await store.readControl()
        let durableReceipt = try #require(durableControl.lastClearReceipt)
        #expect(durableReceipt.operationID == operationID)
        #expect(durableReceipt.controlRevision == stopReceipt.controlRevision)
        #expect(durableReceipt.clearedThroughSequence == 2)
        #expect(durableReceipt.deletionRevision == 1)

        await store.overrideReceiptLookup(
            operationID: operationID,
            with: .clear(CaptureClearReceipt(
                operationID: durableReceipt.operationID,
                controlRevision: durableReceipt.controlRevision,
                deletionRevision: 0,
                clearedThroughSequence: 1,
                commandDigest: durableReceipt.commandDigest
            ))
        )
        let invalidBoundsResult = try await coordinator.reconcileUncertain()
        #expect(invalidBoundsResult == .unresolved(operationID, .receiptMismatch))
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .clear,
            reason: .receiptMismatch
        ))

        await store.overrideReceiptLookup(
            operationID: operationID,
            with: .clear(CaptureClearReceipt(
                operationID: durableReceipt.operationID,
                controlRevision: durableReceipt.controlRevision,
                deletionRevision: durableReceipt.deletionRevision,
                clearedThroughSequence: 1,
                commandDigest: durableReceipt.commandDigest
            ))
        )
        let conflictingReceiptResult = try await coordinator.reconcileUncertain()
        #expect(conflictingReceiptResult == .unresolved(operationID, .controlChanged))
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .clear,
            reason: .controlChanged
        ))
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.startRecording(recordingID: UUID())
        }
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.clearHistory(
                expectedControlRevision: stopReceipt.controlRevision,
                operationID: operationID
            )
        }

        let clearCalls = await store.clearCallCount()
        #expect(clearCalls == 1)
        #expect(runtime.startedEpochs == [epoch])
    }

    @Test(.timeLimit(.minutes(1)))
    func unavailableClearReceiptRemainsUnresolvedAndDoesNotRetry() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let operationID = UUID()
        await store.setNextClearBehavior(.uncertainBeforeCommit)
        await store.setReceiptLookupUnavailable(true)

        let error = await capturedError {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        let result = try await coordinator.reconcileUncertain()
        let clearCalls = await store.clearCallCount()

        #expect(result == .unresolved(operationID, .receiptUnavailable))
        #expect(coordinator.controlSnapshot?.revision == control.revision)
        #expect(coordinator.controlSnapshot?.lastControlReceipt == control.lastControlReceipt)
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .clear,
            reason: .receiptUnavailable
        ))
        #expect(clearCalls == 1)
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.startRecording(recordingID: UUID())
        }
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func mismatchedClearReceiptRemainsUnresolved() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let operationID = UUID()
        await store.setNextClearBehavior(.mismatchedReceipt)

        let error = await capturedError {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        let result = try await coordinator.reconcileUncertain()
        let clearCalls = await store.clearCallCount()

        #expect(result == .unresolved(operationID, .receiptMismatch))
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .clear,
            reason: .receiptMismatch
        ))
        #expect(coordinator.controlSnapshot?.lastClearReceipt == nil)
        #expect(clearCalls == 1)
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func clearReconciliationPreservesNewerControlIntentAndReceipt() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let clearOperationID = UUID()
        await store.setNextClearBehavior(.uncertainAfterCommit)

        let error = await capturedError {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: clearOperationID
            )
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(clearOperationID))
        let newerBegin = try await store.beginExternally(recordingID: UUID())

        let result = try await coordinator.reconcileUncertain()
        guard case .clearCommitted(let clearReceipt) = result else {
            Issue.record("Reconciliation did not confirm the committed Clear")
            return
        }
        let durableControl = try await store.readControl()

        #expect(durableControl.activeEpoch == newerBegin.epoch)
        #expect(durableControl.lastControlReceipt == newerBegin)
        #expect(durableControl.lastClearReceipt == clearReceipt)
        #expect(coordinator.controlSnapshot == durableControl)
        #expect(coordinator.state == .resumeRequired(
            epoch: newerBegin.epoch,
            controlRevision: newerBegin.controlRevision
        ))
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func samePendingClearCoalescesAndConflictingRequestsFail() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        let control = try await coordinator.refreshControl()
        let operationID = UUID()
        await store.gateNextClear()

        let (firstStarted, firstStartSignal) = AsyncStream<Void>.makeStream()
        let first = Task {
            firstStartSignal.yield(())
            return try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        var firstStartedIterator = firstStarted.makeAsyncIterator()
        _ = await firstStartedIterator.next()
        await store.waitForClearCall()

        let (secondStarted, secondStartSignal) = AsyncStream<Void>.makeStream()
        let second = Task {
            secondStartSignal.yield(())
            return try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: operationID
            )
        }
        var secondStartedIterator = secondStarted.makeAsyncIterator()
        _ = await secondStartedIterator.next()

        await expectError(LocalCaptureCoordinatorError.operationConflict(operationID)) {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision + 1,
                operationID: operationID
            )
        }
        await expectError(LocalCaptureCoordinatorError.historyClearPending) {
            try await coordinator.clearHistory(
                expectedControlRevision: control.revision,
                operationID: UUID()
            )
        }
        let callsBeforeRelease = await store.clearCallCount()
        #expect(callsBeforeRelease == 1)

        await store.releaseClear()
        let firstReceipt = try await first.value
        let secondReceipt = try await second.value
        let clearCalls = await store.clearCallCount()
        let clearIDs = await store.clearIDs()

        #expect(firstReceipt == secondReceipt)
        #expect(clearCalls == 1)
        #expect(clearIDs == [operationID])
        #expect(runtime.startedEpochs.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func pendingLaneBoundsSamplesAndPreservesBatchOrder() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let recordingID = try #require(coordinator.controlSnapshot?.activeEpoch?.recordingID)
        let first = try makeInput(recordingID: recordingID, count: 40, startingAt: 1)
        let overflow = try makeInput(recordingID: recordingID, count: 25, startingAt: 100)
        await store.gateNextAppend()

        let append = Task {
            try await coordinator.append(first, now: Date(timeIntervalSinceReferenceDate: 200))
        }
        await store.waitForAppendCall()

        #expect(coordinator.pendingSampleCount == 40)
        #expect(coordinator.pendingEncodedPayloadBytes == first.encodedPayloadBytes)
        await expectError(LocalCaptureCoordinatorError.backpressure) {
            try await coordinator.append(overflow, now: Date(timeIntervalSinceReferenceDate: 200))
        }
        let appendCalls = await store.appendCallCount()
        #expect(appendCalls == 1)

        await store.releaseAppend()
        let receipt = try await append.value
        #expect(receipt.items.map(\.sampleID) == first.samples.map(\.id))
        #expect(coordinator.pendingSampleCount == 0)
        #expect(coordinator.pendingEncodedPayloadBytes == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainAppendUsesExactSampleReconciliationWithoutRestart() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let recordingID = try #require(coordinator.controlSnapshot?.activeEpoch?.recordingID)
        let input = try makeInput(recordingID: recordingID, count: 2, startingAt: 1)
        await store.setNextAppendUncertainAfterCommit()
        await store.setReceiptLookupUnavailable(true)

        let error = await capturedError {
            try await coordinator.append(input, now: Date(timeIntervalSinceReferenceDate: 100))
        }
        guard let operationID = coordinatorOperationID(from: error) else {
            Issue.record("Append did not preserve its uncertain operation identity")
            return
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.stopCallCount == 1)
        #expect(coordinator.pendingSampleCount == input.samples.count)

        let result = try await coordinator.reconcileUncertain()
        #expect(result == .appendSamplesMatched(operationID))
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
        #expect(coordinator.pendingSampleCount == 0)
        if case .resumeRequired(let epoch, _) = coordinator.state {
            #expect(epoch.recordingID == recordingID)
        } else {
            Issue.record("Resolved append must leave runtime recovery explicit")
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainBeginUsesDurableControlReceiptAndRequiresExplicitResume() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = makeCoordinator(store: store, runtime: runtime)
        _ = try await coordinator.refreshControl()
        let recordingID = UUID()
        await store.setNextBeginUncertainAfterCommit()
        await store.setReceiptLookupUnavailable(true)

        let error = await capturedError {
            try await coordinator.startRecording(recordingID: recordingID)
        }
        guard let operationID = coordinatorOperationID(from: error) else {
            Issue.record("Begin did not preserve its uncertain operation identity")
            return
        }
        #expect(error as? LocalCaptureCoordinatorError == .unresolvedOperation(operationID))
        #expect(runtime.startedEpochs.isEmpty)
        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.stopRecording()
        }
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .begin,
            reason: .persistenceOutcome
        ))
        let stopCallsBeforeReconciliation = await store.stopCallCount()
        #expect(stopCallsBeforeReconciliation == 0)

        let result = try await coordinator.reconcileUncertain()
        guard case .beginCommitted(let receipt) = result else {
            Issue.record("Reconciliation did not confirm the committed Begin")
            return
        }
        #expect(receipt.operationID == operationID)
        #expect(receipt.epoch.recordingID == recordingID)
        #expect(runtime.startedEpochs.isEmpty)
        if case .resumeRequired(let epoch, _) = coordinator.state {
            #expect(epoch == receipt.epoch)
        } else {
            Issue.record("Resolved Begin must leave runtime recovery explicit")
        }

        let resumedEpoch = try await coordinator.startRecording(recordingID: recordingID)
        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > receipt.epoch.revision)
        #expect(runtime.startedEpochs == [resumedEpoch])
    }

    @Test(.timeLimit(.minutes(1)))
    func staleEpochRejectionClosesRuntimeAndRefreshesControl() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let oldEpoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let externalStop = try await store.stopExternally()
        let input = try makeInput(recordingID: oldEpoch.recordingID, count: 1, startingAt: 1)
        let operationID = UUID()

        let error = await capturedError {
            try await coordinator.append(
                input,
                now: Date(timeIntervalSinceReferenceDate: 100),
                operationID: operationID
            )
        }

        #expect(error as? CapturePersistenceError == .staleEpoch)
        #expect(coordinator.controlSnapshot?.lastControlReceipt == externalStop)
        #expect(coordinator.state == .stopped(controlRevision: externalStop.controlRevision))
        #expect(!coordinator.isAcceptingSamples)
        #expect(runtime.stopCallCount == 1)
        #expect(coordinator.pendingSampleCount == 0)
        let appendCalls = await store.appendCallCount()
        #expect(appendCalls == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleStopCannotFenceANewerEpoch() async throws {
        let store = CoordinatorPersistenceFake()
        let runtime = CoordinatorRuntimeFake()
        let coordinator = try await activeCoordinator(store: store, runtime: runtime)
        let oldEpoch = try #require(coordinator.controlSnapshot?.activeEpoch)
        let newBegin = try await store.beginExternally(recordingID: oldEpoch.recordingID)

        let error = await capturedError { try await coordinator.stopRecording() }
        guard let operationID = coordinatorStopOperationID(from: error) else {
            Issue.record("Stale Stop did not remain unconfirmed")
            return
        }
        #expect(error as? LocalCaptureCoordinatorError == .stopUnconfirmed(operationID))

        await expectError(LocalCaptureCoordinatorError.unresolvedOperation(operationID)) {
            try await coordinator.retryStop()
        }
        let snapshot = try await store.readControl()
        let stopCalls = await store.stopCallCount()
        let reopenCount = await store.reopenCount()
        #expect(snapshot.activeEpoch == newBegin.epoch)
        #expect(stopCalls == 1)
        #expect(reopenCount == 1)
        #expect(runtime.startedEpochs.count == 1)
        #expect(runtime.stopCallCount == 1)
        #expect(coordinator.state == .uncertain(
            operationID: operationID,
            kind: .stop,
            reason: .controlChanged
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func newCoordinatorWithActiveIntentWaitsForExplicitResume() async throws {
        let store = CoordinatorPersistenceFake()
        let firstRuntime = CoordinatorRuntimeFake()
        let firstCoordinator = try await activeCoordinator(store: store, runtime: firstRuntime)
        let originalEpoch = try #require(firstCoordinator.controlSnapshot?.activeEpoch)
        let recordingID = originalEpoch.recordingID

        let resumedRuntime = CoordinatorRuntimeFake()
        let resumedCoordinator = makeCoordinator(store: store, runtime: resumedRuntime)
        let snapshot = try await resumedCoordinator.refreshControl()

        #expect(snapshot.activeEpoch == originalEpoch)
        #expect(resumedRuntime.startedEpochs.isEmpty)
        #expect(!resumedCoordinator.isAcceptingSamples)

        let resumedEpoch = try await resumedCoordinator.startRecording(recordingID: recordingID)
        #expect(resumedEpoch.recordingID == recordingID)
        #expect(resumedEpoch.revision > originalEpoch.revision)
        #expect(resumedRuntime.startedEpochs == [resumedEpoch])
    }
}

private enum FakeStopBehavior: Equatable {
    case success
    case notCommitted
    case uncertainBeforeCommit
    case uncertainAfterCommit
}

private enum FakeClearBehavior: Equatable, Sendable {
    case success
    case notCommitted
    case uncertainBeforeCommit
    case uncertainAfterCommit
    case mismatchedReceipt
}

actor CoordinatorPersistenceFake: LocalCapturePersistence {
    private var control = CaptureControlSnapshot(revision: 0, activeEpoch: nil, lastControlReceipt: nil)
    private var receipts: [UUID: CaptureReceipt] = [:]
    private var samples: [UUID: RouteSample] = [:]
    private var sampleEpochs: [UUID: Int64] = [:]
    private var insertionHighWaterSequence: Int64 = 0
    private var beginCalls = 0
    private var appendCalls = 0
    private var stopCalls = 0
    private var clearCalls = 0
    private var reopens = 0
    private var stopOperationIDs: [UUID] = []
    private var clearOperationIDs: [UUID] = []
    private var stopGated = false
    private var clearGated = false
    private var stopBarrier: CheckedContinuation<Void, Never>?
    private var clearBarrier: CheckedContinuation<Void, Never>?
    private var stopCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var clearCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var events: [String] = []
    private var lookupUnavailable = false
    private var receiptLookupReplacements: [UUID: CaptureReceipt] = [:]
    private var beginGated = false
    private var appendGated = false
    private var beginUncertainAfterCommit = false
    private var appendUncertainAfterCommit = false
    private var nextStopBehavior = FakeStopBehavior.success
    private var nextClearBehavior = FakeClearBehavior.success
    private var beginBarrier: CheckedContinuation<Void, Never>?
    private var appendBarrier: CheckedContinuation<Void, Never>?
    private var beginCallWaiters: [CheckedContinuation<Void, Never>] = []
    private var appendCallWaiters: [CheckedContinuation<Void, Never>] = []

    func readControl() async throws -> CaptureControlSnapshot {
        control
    }

    func beginRecording(
        recordingID: UUID,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        beginCalls += 1
        events.append("begin.started")
        resume(&beginCallWaiters)
        if beginGated {
            await withCheckedContinuation { beginBarrier = $0 }
            beginGated = false
        }

        let digest = CaptureCommandDigest.begin(
            recordingID: recordingID,
            expectedControlRevision: expectedControlRevision
        )
        if let known = receipts[operationID] {
            guard case .control(let receipt) = known, receipt.commandDigest == digest else {
                throw CapturePersistenceError.operationConflict
            }
            return receipt
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        if let activeEpoch = control.activeEpoch, activeEpoch.recordingID != recordingID {
            throw CapturePersistenceError.activeRecordingMismatch
        }
        guard control.revision < Int64.max else {
            throw CapturePersistenceError.revisionExhausted
        }

        let revision = control.revision + 1
        let epoch = CaptureEpoch(recordingID: recordingID, revision: revision)
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .begin,
            epoch: epoch,
            controlRevision: revision,
            commandDigest: digest
        )
        control = CaptureControlSnapshot(
            revision: revision, activeEpoch: epoch, lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        events.append("begin.committed")
        if beginUncertainAfterCommit {
            beginUncertainAfterCommit = false
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }
        return receipt
    }

    func appendBatch(
        _ batch: [RouteSample],
        epoch: CaptureEpoch,
        operationID: UUID,
        now _: Date
    ) async throws -> CaptureBatchReceipt {
        appendCalls += 1
        events.append("append.started")
        resume(&appendCallWaiters)
        if appendGated {
            await withCheckedContinuation { appendBarrier = $0 }
            appendGated = false
        }
        let input = try CaptureBatchInput(samples: batch)
        let digest = CaptureCommandDigest.batch(epoch: epoch, input: input)
        if let known = receipts[operationID] {
            guard case .batch(let receipt) = known, receipt.commandDigest == digest else {
                throw CapturePersistenceError.operationConflict
            }
            return receipt
        }
        guard control.activeEpoch == epoch else {
            throw CapturePersistenceError.staleEpoch
        }

        let items = batch.map { sample -> CaptureSampleResult in
            let disposition: SampleIngestResult
            if !sample.isValid || sample.recordingID != epoch.recordingID {
                disposition = .invalid
            } else if samples[sample.id] != nil {
                disposition = .duplicate
            } else {
                insertionHighWaterSequence += 1
                samples[sample.id] = sample
                sampleEpochs[sample.id] = epoch.revision
                disposition = .stored
            }
            return CaptureSampleResult(sampleID: sample.id, disposition: disposition)
        }
        let receipt = CaptureBatchReceipt(
            operationID: operationID,
            epoch: epoch,
            commandDigest: digest,
            items: items
        )
        receipts[operationID] = .batch(receipt)
        events.append("append.committed")
        if appendUncertainAfterCommit {
            appendUncertainAfterCommit = false
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }
        return receipt
    }

    func stopRecording(
        epoch: CaptureEpoch,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        stopCalls += 1
        stopOperationIDs.append(operationID)
        events.append("stop.started")
        resume(&stopCallWaiters)
        if stopGated {
            await withCheckedContinuation { stopBarrier = $0 }
            stopGated = false
        }

        let behavior = nextStopBehavior
        nextStopBehavior = .success
        if behavior == .notCommitted {
            throw CapturePersistenceError.notCommitted(.writeFailed)
        }
        if behavior == .uncertainBeforeCommit {
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }

        let digest = CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: expectedControlRevision)
        if let known = receipts[operationID] {
            guard case .control(let receipt) = known, receipt.commandDigest == digest else {
                throw CapturePersistenceError.operationConflict
            }
            return receipt
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        guard control.activeEpoch == epoch else {
            throw CapturePersistenceError.staleEpoch
        }
        guard control.revision < Int64.max else {
            throw CapturePersistenceError.revisionExhausted
        }

        let revision = control.revision + 1
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .stop,
            epoch: epoch,
            controlRevision: revision,
            commandDigest: digest
        )
        control = CaptureControlSnapshot(
            revision: revision, activeEpoch: nil, lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        events.append("stop.committed")
        if behavior == .uncertainAfterCommit {
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }
        return receipt
    }

    func clearHistory(
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureClearReceipt {
        clearCalls += 1
        clearOperationIDs.append(operationID)
        events.append("clear.started")
        resume(&clearCallWaiters)
        if clearGated {
            await withCheckedContinuation { clearBarrier = $0 }
            clearGated = false
        }

        let digest = CaptureCommandDigest.clear(expectedControlRevision: expectedControlRevision)
        if let known = receipts[operationID] {
            guard case .clear(let receipt) = known, receipt.commandDigest == digest else {
                throw CapturePersistenceError.operationConflict
            }
            return receipt
        }
        guard control.revision == expectedControlRevision else {
            throw CapturePersistenceError.staleControlRevision
        }
        guard control.activeEpoch == nil else {
            throw CapturePersistenceError.recordingActive
        }

        let behavior = nextClearBehavior
        nextClearBehavior = .success
        if behavior == .notCommitted {
            throw CapturePersistenceError.notCommitted(.writeFailed)
        }
        if behavior == .uncertainBeforeCommit {
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }

        guard control.clearedThroughSequence <= insertionHighWaterSequence else {
            throw CapturePersistenceError.invalidControlState
        }
        let advancesFloor = insertionHighWaterSequence > control.clearedThroughSequence
        let deletionRevision: Int64
        if advancesFloor {
            guard control.deletionRevision < Int64.max else {
                throw CapturePersistenceError.revisionExhausted
            }
            deletionRevision = control.deletionRevision + 1
        } else {
            deletionRevision = control.deletionRevision
        }
        let clearedThroughSequence = max(control.clearedThroughSequence, insertionHighWaterSequence)
        let receipt = CaptureClearReceipt(
            operationID: operationID,
            controlRevision: control.revision,
            deletionRevision: deletionRevision,
            clearedThroughSequence: clearedThroughSequence,
            commandDigest: digest
        )
        if behavior == .mismatchedReceipt {
            let mismatchedReceipt = CaptureClearReceipt(
                operationID: UUID(),
                controlRevision: receipt.controlRevision,
                deletionRevision: receipt.deletionRevision,
                clearedThroughSequence: receipt.clearedThroughSequence,
                commandDigest: receipt.commandDigest
            )
            receipts[operationID] = .clear(mismatchedReceipt)
            events.append("clear.receiptMismatch")
            return mismatchedReceipt
        }

        control = CaptureControlSnapshot(
            revision: control.revision,
            activeEpoch: nil,
            lastControlReceipt: control.lastControlReceipt,
            deletionRevision: deletionRevision,
            clearedThroughSequence: clearedThroughSequence,
            lastClearReceipt: receipt
        )
        receipts[operationID] = .clear(receipt)
        samples.removeAll()
        sampleEpochs.removeAll()
        events.append("clear.committed")
        if behavior == .uncertainAfterCommit {
            throw CapturePersistenceError.outcomeUncertain(operationID)
        }
        return receipt
    }

    func lookupReceipt(operationID: UUID) async throws -> CaptureReceiptLookup {
        guard !lookupUnavailable else {
            return .unavailable
        }
        if let replacement = receiptLookupReplacements[operationID] {
            return .found(replacement)
        }
        return receipts[operationID].map(CaptureReceiptLookup.found) ?? .unavailable
    }

    func batchReceipts() -> [CaptureBatchReceipt] {
        receipts.values.compactMap { receipt in
            guard case .batch(let batchReceipt) = receipt else {
                return nil
            }
            return batchReceipt
        }
    }

    func reconcileSamples(
        _ samplesToReconcile: [RouteSample],
        epoch: CaptureEpoch
    ) async throws -> [CaptureSampleReconciliation] {
        samplesToReconcile.map { sample in
            let match: CaptureSampleMatch
            if let stored = samples[sample.id] {
                match = stored == sample && sampleEpochs[sample.id] == epoch.revision
                    ? .matching
                    : .conflicting
            } else {
                match = .absentOrExpired
            }
            return CaptureSampleReconciliation(sampleID: sample.id, match: match)
        }
    }

    func gateNextBegin() { beginGated = true }
    func gateNextAppend() { appendGated = true }
    func gateNextStop() { stopGated = true }
    func gateNextClear() { clearGated = true }
    func overrideReceiptLookup(operationID: UUID, with receipt: CaptureReceipt) {
        receiptLookupReplacements[operationID] = receipt
    }
    func advanceHistoryDeletionRevision() {
        control = CaptureControlSnapshot(
            revision: control.revision, activeEpoch: control.activeEpoch, lastControlReceipt: control.lastControlReceipt,
            deletionRevision: control.deletionRevision + 1,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
    }
    func setNextBeginUncertainAfterCommit() { beginUncertainAfterCommit = true }
    func setReceiptLookupUnavailable(_ unavailable: Bool) { lookupUnavailable = unavailable }
    fileprivate func setNextStopBehavior(_ behavior: FakeStopBehavior) { nextStopBehavior = behavior }
    fileprivate func setNextClearBehavior(_ behavior: FakeClearBehavior) { nextClearBehavior = behavior }
    func setNextAppendUncertainAfterCommit() { appendUncertainAfterCommit = true }
    func recordReopen() { reopens += 1 }
    func clearEventLog() { events = [] }

    func waitForBeginCall() async {
        guard beginCalls == 0 else { return }
        await withCheckedContinuation { beginCallWaiters.append($0) }
    }

    func waitForAppendCall() async {
        guard appendCalls == 0 else { return }
        await withCheckedContinuation { appendCallWaiters.append($0) }
    }

    func waitForStopCall() async {
        guard stopCalls == 0 else { return }
        await withCheckedContinuation { stopCallWaiters.append($0) }
    }

    func waitForClearCall() async {
        guard clearCalls == 0 else { return }
        await withCheckedContinuation { clearCallWaiters.append($0) }
    }

    func releaseBegin() { beginBarrier?.resume(); beginBarrier = nil }
    func releaseAppend() { appendBarrier?.resume(); appendBarrier = nil }
    func releaseStop() { stopBarrier?.resume(); stopBarrier = nil }
    func releaseClear() { clearBarrier?.resume(); clearBarrier = nil }

    func beginCallCount() -> Int { beginCalls }
    func appendCallCount() -> Int { appendCalls }
    func stopCallCount() -> Int { stopCalls }
    func clearCallCount() -> Int { clearCalls }
    func reopenCount() -> Int { reopens }
    func eventLog() -> [String] { events }
    func stopIDs() -> [UUID] { stopOperationIDs }
    func clearIDs() -> [UUID] { clearOperationIDs }

    func stopExternally() throws -> CaptureControlReceipt {
        guard let epoch = control.activeEpoch, control.revision < Int64.max else {
            throw CapturePersistenceError.invalidControlState
        }
        let revision = control.revision + 1
        let operationID = UUID()
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .stop,
            epoch: epoch,
            controlRevision: revision,
            commandDigest: CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: control.revision)
        )
        control = CaptureControlSnapshot(
            revision: revision, activeEpoch: nil, lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        return receipt
    }

    func beginExternally(recordingID: UUID) throws -> CaptureControlReceipt {
        guard control.revision < Int64.max else {
            throw CapturePersistenceError.revisionExhausted
        }
        let revision = control.revision + 1
        let epoch = CaptureEpoch(recordingID: recordingID, revision: revision)
        let operationID = UUID()
        let receipt = CaptureControlReceipt(
            operationID: operationID,
            kind: .begin,
            epoch: epoch,
            controlRevision: revision,
            commandDigest: CaptureCommandDigest.begin(
                recordingID: recordingID,
                expectedControlRevision: control.revision
            )
        )
        control = CaptureControlSnapshot(
            revision: revision, activeEpoch: epoch, lastControlReceipt: receipt,
            deletionRevision: control.deletionRevision,
            clearedThroughSequence: control.clearedThroughSequence,
            lastClearReceipt: control.lastClearReceipt
        )
        receipts[operationID] = .control(receipt)
        return receipt
    }

    private func resume(_ waiters: inout [CheckedContinuation<Void, Never>]) {
        let waiting = waiters
        waiters = []
        for waiter in waiting {
            waiter.resume()
        }
    }
}

@MainActor
private final class CoordinatorRuntimeFake: LocalCaptureRuntimeControl {
    private(set) var startedEpochs: [CaptureEpoch] = []
    private(set) var startedGenerations: [UUID] = []
    private(set) var handles: [CoordinatorRuntimeHandleFake] = []

    var stopCallCount: Int {
        handles.reduce(0) { $0 + $1.stopCallCount }
    }

    func start(epoch: CaptureEpoch, generation: UUID) -> any LocalCaptureRuntimeHandle {
        startedEpochs.append(epoch)
        startedGenerations.append(generation)
        let handle = CoordinatorRuntimeHandleFake()
        handles.append(handle)
        return handle
    }
}

@MainActor
private final class CoordinatorRuntimeHandleFake: LocalCaptureRuntimeHandle {
    private(set) var stopCallCount = 0

    func stop() {
        stopCallCount += 1
    }
}

@MainActor
private func makeCoordinator(
    store: CoordinatorPersistenceFake,
    runtime: CoordinatorRuntimeFake
) -> LocalCaptureCoordinator {
    LocalCaptureCoordinator(persistence: store, runtime: runtime) {
        await store.recordReopen()
        return store
    }
}

@MainActor
private func activeCoordinator(
    store: CoordinatorPersistenceFake,
    runtime: CoordinatorRuntimeFake
) async throws -> LocalCaptureCoordinator {
    let coordinator = makeCoordinator(store: store, runtime: runtime)
    _ = try await coordinator.refreshControl()
    _ = try await coordinator.startRecording(recordingID: UUID())
    return coordinator
}

@MainActor
private func makeInput(recordingID: UUID, count: Int, startingAt: Int) throws -> CaptureBatchInput {
    try CaptureBatchInput(samples: (0..<count).map { offset in
        RouteSample(
            recordingID: recordingID,
            observedAt: Date(timeIntervalSinceReferenceDate: Double(startingAt + offset)),
            latitude: 10 + Double(offset) / 100,
            longitude: 20,
            horizontalAccuracy: 5,
            isStationary: false
        )
    })
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    while !condition() {
        await Task.yield()
    }
}

@MainActor
private func expectError<Output, Failure: Error & Equatable>(
    _ expected: Failure,
    operation: () async throws -> Output
) async {
    do {
        _ = try await operation()
        Issue.record("Expected error \(String(describing: expected))")
    } catch let error as Failure {
        #expect(error == expected)
    } catch {
        Issue.record("Unexpected error \(error)")
    }
}

@MainActor
private func capturedError<Output>(_ operation: () async throws -> Output) async -> (any Error)? {
    do {
        _ = try await operation()
        return nil
    } catch {
        return error
    }
}

private func coordinatorOperationID(from error: (any Error)?) -> UUID? {
    guard let error = error as? LocalCaptureCoordinatorError,
          case .unresolvedOperation(let operationID) = error else {
        return nil
    }
    return operationID
}

private func coordinatorStopOperationID(from error: (any Error)?) -> UUID? {
    guard let error = error as? LocalCaptureCoordinatorError,
          case .stopUnconfirmed(let operationID) = error else {
        return nil
    }
    return operationID
}
