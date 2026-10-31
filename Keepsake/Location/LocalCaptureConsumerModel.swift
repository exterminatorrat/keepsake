import Foundation
import Observation

enum LocalCaptureConsumerError: Error, Equatable {
    case disposed
    case historyMaintenancePending
    case historyMaintenanceRequiresStopped
    case historyMaintenanceRequiresReopen
}

enum LocalCaptureConsumerIntent: Equatable {
    case unknown
    case stopped(controlRevision: Int64)
    case starting(recordingID: UUID)
    case resumeRequired(epoch: CaptureEpoch, controlRevision: Int64)
    case recording(epoch: CaptureEpoch, controlRevision: Int64)
    case stopping(epoch: CaptureEpoch?)
}

struct LocalCaptureHistoryQuery: Equatable, Sendable {
    let interval: CapturePageInterval
    let queryNow: Date
    let pageLimit: Int
}

@MainActor
@Observable
final class LocalCaptureConsumerModel {
    static let defaultHistoryPageLimit = 128

    private(set) var captureState: LocalCaptureCoordinatorState
    private(set) var lastError: String?
    private(set) var lastInterruption: LocalCaptureLifecycleInterruption?
    private(set) var isClearingHistory = false
    private(set) var isMaintainingHistory = false
    private(set) var historyMaintenanceRequiresReopen = false
    private(set) var historyQuery: LocalCaptureHistoryQuery?
    private(set) var historyPage: CapturePage?
    private(set) var isHistoryLoading = false
    private(set) var isHistoryAwaitingExplicitRefresh = false
    private(set) var historyError: String?

    @ObservationIgnored private let lifecycle: LocalCaptureLifecycle
    @ObservationIgnored private let historyReader: any LocalCaptureHistoryReading
    @ObservationIgnored private let historyPageLimit: Int
    @ObservationIgnored private var historyTask: Task<Void, Never>?
    @ObservationIgnored private var historyGeneration = UUID()
    @ObservationIgnored private var isDisposed = false
    @ObservationIgnored nonisolated private let taskLifetime = RecorderTaskLifetime()

    init(
        lifecycle: LocalCaptureLifecycle,
        historyReader: any LocalCaptureHistoryReading,
        historyPageLimit: Int = LocalCaptureConsumerModel.defaultHistoryPageLimit
    ) {
        self.lifecycle = lifecycle
        self.historyReader = historyReader
        self.historyPageLimit = min(
            max(historyPageLimit, 1),
            CapturePersistenceLimits.maximumPageRows
        )
        captureState = lifecycle.state
        lastError = lifecycle.lastError
        lastInterruption = lifecycle.lastInterruption
        lifecycle.onChange = { [weak self] in
            self?.synchronizeCaptureState()
        }
    }

    deinit {
        taskLifetime.cancelAll()
    }

    var currentIntent: LocalCaptureConsumerIntent {
        switch captureState {
        case .unready, .uncertain:
            .unknown
        case .stopped(let revision):
            .stopped(controlRevision: revision)
        case .beginning(let recordingID, _):
            .starting(recordingID: recordingID)
        case .active(let epoch, _, let revision):
            .recording(epoch: epoch, controlRevision: revision)
        case .resumeRequired(let epoch, let revision):
            .resumeRequired(epoch: epoch, controlRevision: revision)
        case .stopping(_, let epoch), .stopUnconfirmed(_, let epoch):
            .stopping(epoch: epoch)
        }
    }

    var hasMoreHistoryPages: Bool {
        historyPage?.nextCursor != nil
    }

    var canLoadNextHistoryPage: Bool {
        !isDisposed && !isClearingHistory && !isMaintainingHistory
            && !historyMaintenanceRequiresReopen && !isHistoryLoading && hasMoreHistoryPages
    }

    func startNewRecording(recordingID: UUID) async throws -> CaptureEpoch {
        try requireHistoryMaintenanceReady()
        return try await performCaptureAction {
            try await lifecycle.startNewRecording(recordingID: recordingID)
        }
    }

    func resume() async throws -> CaptureEpoch {
        try requireHistoryMaintenanceReady()
        return try await performCaptureAction {
            try await lifecycle.resume()
        }
    }

    func stop() async throws -> LocalCaptureStopResult {
        try await performCaptureAction {
            try await lifecycle.stop()
        }
    }

    func retryStop() async throws -> LocalCaptureStopResult {
        try await performCaptureAction {
            try await lifecycle.retryStop()
        }
    }

    func reconcileUncertain() async throws -> LocalCaptureReconciliationResult {
        try await performCaptureAction {
            try await lifecycle.reconcileUncertain()
        }
    }

    func clearHistory(operationID: UUID = UUID()) async throws -> CaptureClearReceipt {
        guard !isDisposed else {
            throw LocalCaptureConsumerError.disposed
        }
        try requireHistoryMaintenanceReady()
        guard !isClearingHistory else {
            throw LocalCaptureCoordinatorError.historyClearPending
        }
        invalidateHistory(clearPage: true)
        historyError = nil
        guard lifecycle.isStorageReady,
              let expectedControlRevision = lifecycle.controlSnapshot?.revision else {
            throw LocalCaptureCoordinatorError.storageNotReady
        }

        isHistoryAwaitingExplicitRefresh = true
        isClearingHistory = true
        defer { isClearingHistory = false }

        do {
            return try await performCaptureAction {
                try await lifecycle.clearHistory(
                    expectedControlRevision: expectedControlRevision,
                    operationID: operationID
                )
            }
        } catch {
            historyError = String(describing: error)
            throw error
        }
    }

    func selectHistoryQuery(
        interval: CapturePageInterval,
        queryNow: Date = .now
    ) async {
        guard !isDisposed else {
            return
        }
        historyQuery = LocalCaptureHistoryQuery(
            interval: interval,
            queryNow: queryNow,
            pageLimit: historyPageLimit
        )
        if let task = startHistoryRead(cursor: nil, clearPage: true) {
            await task.value
        }
    }

    func refreshHistory(queryNow: Date = .now) async {
        guard !isDisposed,
              let historyQuery else {
            return
        }
        self.historyQuery = LocalCaptureHistoryQuery(
            interval: historyQuery.interval,
            queryNow: queryNow,
            pageLimit: historyQuery.pageLimit
        )
        if let task = startHistoryRead(cursor: nil, clearPage: true) {
            await task.value
        }
    }

    func loadNextHistoryPage() async {
        guard let cursor = historyPage?.nextCursor,
              !isDisposed,
              !isClearingHistory,
              !isHistoryLoading else {
            return
        }
        if let task = startHistoryRead(cursor: cursor, clearPage: false) {
            await task.value
        }
    }

    func dispose() {
        guard !isDisposed else {
            return
        }
        isDisposed = true
        invalidateHistory(clearPage: true)
        historyQuery = nil
        taskLifetime.cancelAll()
        lifecycle.onChange = nil
    }

    func invalidateHistoryForMaintenance() {
        guard !isDisposed else {
            return
        }
        invalidateHistory(clearPage: true)
        historyError = nil
    }

    func pruneHistory(
        using operation: @MainActor () async throws -> CapturePruneReceipt
    ) async throws -> CapturePruneReceipt {
        guard !isDisposed else {
            throw LocalCaptureConsumerError.disposed
        }
        try requireHistoryMaintenanceReady()
        guard !isClearingHistory, case .stopped = lifecycle.state else {
            throw LocalCaptureConsumerError.historyMaintenanceRequiresStopped
        }
        invalidateHistoryForMaintenance()
        isMaintainingHistory = true
        defer { isMaintainingHistory = false }
        do {
            return try await operation()
        } catch {
            historyMaintenanceRequiresReopen = true
            historyError = String(describing: error)
            throw error
        }
    }

    private func requireHistoryMaintenanceReady() throws {
        guard !isMaintainingHistory else {
            throw LocalCaptureConsumerError.historyMaintenancePending
        }
        guard !historyMaintenanceRequiresReopen else {
            throw LocalCaptureConsumerError.historyMaintenanceRequiresReopen
        }
    }

    private func startHistoryRead(
        cursor: CapturePageCursor?,
        clearPage: Bool
    ) -> Task<Void, Never>? {
        historyTask?.cancel()
        taskLifetime.finish(historyGeneration)
        historyTask = nil
        historyGeneration = UUID()
        let generation = historyGeneration
        if clearPage {
            historyPage = nil
            isHistoryAwaitingExplicitRefresh = true
        }
        historyError = nil
        guard !isDisposed else {
            isHistoryLoading = false
            return nil
        }
        guard !isClearingHistory, !isMaintainingHistory, !historyMaintenanceRequiresReopen else {
            historyPage = nil
            historyError = isClearingHistory
                ? String(describing: LocalCaptureCoordinatorError.historyClearPending)
                : String(describing: historyMaintenanceRequiresReopen
                    ? LocalCaptureConsumerError.historyMaintenanceRequiresReopen
                    : LocalCaptureConsumerError.historyMaintenancePending)
            isHistoryAwaitingExplicitRefresh = true
            isHistoryLoading = false
            return nil
        }
        guard lifecycle.isStorageReady else {
            historyPage = nil
            historyError = String(describing: LocalCaptureCoordinatorError.storageNotReady)
            isHistoryAwaitingExplicitRefresh = true
            isHistoryLoading = false
            return nil
        }
        guard let historyQuery else {
            isHistoryLoading = false
            return nil
        }

        let query = historyQuery
        let reader = historyReader
        let taskLifetime = taskLifetime
        let task = Task { @MainActor [weak self, reader, taskLifetime, query] in
            defer { taskLifetime.finish(generation) }
            do {
                let page = try await reader.readPage(
                    interval: query.interval,
                    now: query.queryNow,
                    limit: query.pageLimit,
                    cursor: cursor
                )
                guard !Task.isCancelled,
                      let self,
                      !self.isDisposed,
                      self.historyGeneration == generation else {
                    return
                }
                self.historyPage = page
                self.historyError = nil
                self.isHistoryAwaitingExplicitRefresh = false
            } catch {
                guard !Task.isCancelled,
                      let self,
                      !self.isDisposed,
                      self.historyGeneration == generation else {
                    return
                }
                self.historyPage = nil
                self.historyError = String(describing: error)
                self.isHistoryAwaitingExplicitRefresh = true
            }

            guard let self,
                  !self.isDisposed,
                  self.historyGeneration == generation else {
                return
            }
            self.isHistoryLoading = false
            self.historyTask = nil
        }
        historyTask = task
        isHistoryLoading = true
        taskLifetime.retain(task, for: generation)
        return task
    }

    private func invalidateHistory(clearPage: Bool) {
        historyTask?.cancel()
        taskLifetime.finish(historyGeneration)
        historyTask = nil
        historyGeneration = UUID()
        isHistoryLoading = false
        if clearPage {
            historyPage = nil
            isHistoryAwaitingExplicitRefresh = true
        }
    }

    private func synchronizeCaptureState() {
        captureState = lifecycle.state
        lastError = lifecycle.lastError
        lastInterruption = lifecycle.lastInterruption
    }

    private func performCaptureAction<Value>(
        _ operation: @MainActor () async throws -> Value
    ) async throws -> Value {
        guard !isDisposed else {
            throw LocalCaptureConsumerError.disposed
        }
        defer { synchronizeCaptureState() }
        return try await operation()
    }
}
