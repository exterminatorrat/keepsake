import Foundation

enum LocalCaptureExperiment {
    #if KEEPSAKE_EXPERIMENTAL_LOCAL_CAPTURE
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif

    static func storeURL(in applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("Keepsake-Isolated-Capture-v2", isDirectory: true)
    }
}

enum LocalCaptureExperimentOpenMode: Sendable {
    case createEmpty
    case openExisting
}

actor LocalCaptureExperimentStore: LocalCapturePersistence, LocalCaptureHistoryReading {
    private let rootURL: URL
    private let seams: RouteStoreSeams
    private var store: RouteStore?
    private var reopeningStore: RouteStore?
    private var isReopening = false
    private var isClosed = false

    private init(rootURL: URL, store: RouteStore, seams: RouteStoreSeams) {
        self.rootURL = rootURL
        self.store = store
        self.seams = seams
    }

    static func open(
        in applicationSupport: URL,
        mode: LocalCaptureExperimentOpenMode,
        seams: RouteStoreSeams = RouteStoreSeams()
    ) async throws -> LocalCaptureExperimentStore {
        let root = LocalCaptureExperiment.storeURL(in: applicationSupport)
        let store = try await Task.detached(priority: .utility) {
            switch mode {
            case .createEmpty:
                try RouteStore.createFoundation(at: root, seams: seams)
            case .openExisting:
                try RouteStore.openFoundation(at: root, seams: seams)
            }
        }.value
        return LocalCaptureExperimentStore(rootURL: root, store: store, seams: seams)
    }

    func reopenVerified() async throws -> any LocalCapturePersistence {
        guard !isClosed, !isReopening else {
            throw CapturePersistenceError.unavailable(.storeClosed)
        }
        isReopening = true
        defer {
            isReopening = false
            reopeningStore = nil
        }
        let previous = store
        store = nil
        reopeningStore = previous
        await previous?.close()
        guard !isClosed else {
            throw CapturePersistenceError.unavailable(.storeClosed)
        }
        store = try RouteStore.openFoundation(at: rootURL, seams: seams)
        return self
    }

    func close() async {
        isClosed = true
        let previous = store ?? reopeningStore
        store = nil
        await previous?.close()
    }

    func readControl() async throws -> CaptureControlSnapshot {
        try await currentStore().readControl()
    }

    func beginRecording(recordingID: UUID, expectedControlRevision: Int64, operationID: UUID) async throws -> CaptureControlReceipt {
        try await currentStore().beginRecording(recordingID: recordingID, expectedControlRevision: expectedControlRevision, operationID: operationID)
    }

    func appendBatch(_ samples: [RouteSample], epoch: CaptureEpoch, operationID: UUID, now: Date) async throws -> CaptureBatchReceipt {
        try await currentStore().appendBatch(samples, epoch: epoch, operationID: operationID, now: now)
    }

    func stopRecording(epoch: CaptureEpoch, expectedControlRevision: Int64, operationID: UUID) async throws -> CaptureControlReceipt {
        try await currentStore().stopRecording(epoch: epoch, expectedControlRevision: expectedControlRevision, operationID: operationID)
    }

    func clearHistory(expectedControlRevision: Int64, operationID: UUID) async throws -> CaptureClearReceipt {
        try await currentStore().clearHistory(expectedControlRevision: expectedControlRevision, operationID: operationID)
    }

    func lookupReceipt(operationID: UUID) async throws -> CaptureReceiptLookup {
        try await currentStore().lookupReceipt(operationID: operationID)
    }

    func reconcileSamples(_ samples: [RouteSample], epoch: CaptureEpoch) async throws -> [CaptureSampleReconciliation] {
        try await currentStore().reconcileSamples(samples, epoch: epoch)
    }

    func readPage(interval: CapturePageInterval, now: Date, limit: Int, cursor: CapturePageCursor?) async throws -> CapturePage {
        try await currentStore().readPage(interval: interval, now: now, limit: limit, cursor: cursor)
    }

    func pruneHistory(now: Date, limit: Int, operationID: UUID) async throws -> CapturePruneReceipt {
        try await currentStore().pruneHistory(now: now, limit: limit, operationID: operationID)
    }

    private func currentStore() throws -> RouteStore {
        guard let store else {
            throw CapturePersistenceError.unavailable(.storeClosed)
        }
        return store
    }
}
