import Foundation
@testable import Keepsake

struct LocalCaptureExperimentSyntheticVisualHistoryRequest: Equatable, Sendable {
    let interval: CapturePageInterval
    let now: Date
    let limit: Int
    let cursor: CapturePageCursor?
}

struct LocalCaptureExperimentSyntheticVisualFixtureAudit: Equatable, Sendable {
    let controlSnapshot: CaptureControlSnapshot
    let controlReadCount: Int
    let historyRequests: [LocalCaptureExperimentSyntheticVisualHistoryRequest]
    let forbiddenActionCount: Int
    let unexpectedCallCount: Int
    let unexpectedHistoryRequestCount: Int
    let locationCollectCount: Int
    let authorizationRefreshCount: Int
    let authorizationRequestCount: Int
    let servicesStatusReadCount: Int
    let backgroundActivityHandleCount: Int
    let serviceSessionHandleCount: Int
    let pruneCalls: Int
    let closeCalls: Int
}

@MainActor
final class LocalCaptureExperimentSyntheticVisualFixture {
    let view: LocalCaptureExperimentView
    let model: LocalCaptureConsumerModel
    let interval: CapturePageInterval
    let queryNow: Date
    let firstCursor: CapturePageCursor
    let firstSampleIDs: [UUID]
    let nextSampleIDs: [UUID]

    private let persistence: SyntheticVisualPersistence
    private let locationSource: SyntheticVisualLocationSource
    private let authorization: SyntheticVisualAuthorization
    private let servicesStatus: SyntheticVisualServicesStatus
    private let runtimePlatform: SyntheticVisualRuntimePlatform
    private let maintenanceActions: SyntheticVisualMaintenanceActions

    private init(
        view: LocalCaptureExperimentView,
        model: LocalCaptureConsumerModel,
        scenario: SyntheticVisualHistoryScenario,
        persistence: SyntheticVisualPersistence,
        locationSource: SyntheticVisualLocationSource,
        authorization: SyntheticVisualAuthorization,
        servicesStatus: SyntheticVisualServicesStatus,
        runtimePlatform: SyntheticVisualRuntimePlatform,
        maintenanceActions: SyntheticVisualMaintenanceActions
    ) {
        self.view = view
        self.model = model
        interval = scenario.interval
        queryNow = scenario.queryNow
        firstCursor = scenario.firstCursor
        firstSampleIDs = scenario.firstSampleIDs
        nextSampleIDs = scenario.nextSampleIDs
        self.persistence = persistence
        self.locationSource = locationSource
        self.authorization = authorization
        self.servicesStatus = servicesStatus
        self.runtimePlatform = runtimePlatform
        self.maintenanceActions = maintenanceActions
    }

    static func make() async throws -> LocalCaptureExperimentSyntheticVisualFixture {
        let scenario = SyntheticVisualHistoryScenario()
        let queryNow = scenario.queryNow
        let persistence = SyntheticVisualPersistence(
            interval: scenario.interval,
            queryNow: queryNow,
            stoppedSnapshot: scenario.stoppedSnapshot,
            firstCursor: scenario.firstCursor,
            firstPage: scenario.firstPage,
            nextPage: scenario.nextPage
        )
        let locationSource = SyntheticVisualLocationSource()
        let authorization = SyntheticVisualAuthorization()
        let servicesStatus = SyntheticVisualServicesStatus()
        let runtimePlatform = SyntheticVisualRuntimePlatform()
        let maintenanceActions = SyntheticVisualMaintenanceActions()
        let lifecycle = try await LocalCaptureLifecycle.open(
            persistence: persistence,
            reopenVerifiedStore: { try await persistence.rejectUnexpectedReopen() },
            locationUpdateSource: locationSource,
            authorization: authorization,
            runtimePlatform: runtimePlatform,
            now: { queryNow },
            isLocationServicesEnabled: { await servicesStatus.read() }
        )
        let model = LocalCaptureConsumerModel(lifecycle: lifecycle, historyReader: persistence)
        let view = LocalCaptureExperimentView(
            model: model,
            prune: {
                maintenanceActions.recordPrune()
                throw SyntheticVisualFixtureError.forbiddenAction
            },
            closeFailedMaintenanceSession: {
                maintenanceActions.recordClose()
            },
            calendar: scenario.calendar,
            now: { queryNow }
        )
        return LocalCaptureExperimentSyntheticVisualFixture(
            view: view,
            model: model,
            scenario: scenario,
            persistence: persistence,
            locationSource: locationSource,
            authorization: authorization,
            servicesStatus: servicesStatus,
            runtimePlatform: runtimePlatform,
            maintenanceActions: maintenanceActions
        )
    }

    func audit() async -> LocalCaptureExperimentSyntheticVisualFixtureAudit {
        let persistenceAudit = await persistence.audit()
        return LocalCaptureExperimentSyntheticVisualFixtureAudit(
            controlSnapshot: persistenceAudit.controlSnapshot,
            controlReadCount: persistenceAudit.controlReadCount,
            historyRequests: persistenceAudit.historyRequests,
            forbiddenActionCount: persistenceAudit.forbiddenActionCount,
            unexpectedCallCount: persistenceAudit.unexpectedCallCount,
            unexpectedHistoryRequestCount: persistenceAudit.unexpectedHistoryRequestCount,
            locationCollectCount: locationSource.collectCount,
            authorizationRefreshCount: authorization.refreshCount,
            authorizationRequestCount: authorization.requestCount,
            servicesStatusReadCount: servicesStatus.readCount,
            backgroundActivityHandleCount: runtimePlatform.backgroundActivityHandleCount,
            serviceSessionHandleCount: runtimePlatform.serviceSessionHandleCount,
            pruneCalls: maintenanceActions.pruneCalls,
            closeCalls: maintenanceActions.closeCalls
        )
    }

    func dispose() {
        model.dispose()
    }
}

private struct SyntheticVisualHistoryScenario {
    let calendar: Calendar
    let queryNow: Date
    let interval: CapturePageInterval
    let epoch: CaptureEpoch
    let stoppedSnapshot: CaptureControlSnapshot
    let firstCursor: CapturePageCursor
    let firstPage: CapturePage
    let nextPage: CapturePage
    let firstSampleIDs: [UUID]
    let nextSampleIDs: [UUID]

    init() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar

        let dayStart = calendar.startOfDay(for: Date(timeIntervalSinceReferenceDate: 1_000_000_000))
        let queryNow = dayStart.addingTimeInterval(12 * 60 * 60)
        self.queryNow = queryNow
        let interval = CapturePageInterval(start: dayStart, end: dayStart.addingTimeInterval(86_400))
        self.interval = interval

        let recordingID = UUID(uuidString: "00000000-0000-0000-0000-000000000099")!
        let epoch = CaptureEpoch(recordingID: recordingID, revision: 1)
        self.epoch = epoch
        let stopReceipt = CaptureControlReceipt(
            operationID: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
            kind: .stop,
            epoch: epoch,
            controlRevision: 2,
            commandDigest: CaptureCommandDigest.stop(epoch: epoch, expectedControlRevision: 1)
        )
        stoppedSnapshot = CaptureControlSnapshot(
            revision: 2,
            activeEpoch: nil,
            lastControlReceipt: stopReceipt
        )

        let firstSamples = [
            Self.sample("00000000-0000-0000-0000-000000000001", sequence: 1, interval: interval, recordingID: recordingID),
            Self.sample("00000000-0000-0000-0000-000000000002", sequence: 2, interval: interval, recordingID: recordingID),
            Self.sample("00000000-0000-0000-0000-000000000003", sequence: 3, interval: interval, recordingID: recordingID)
        ]
        let nextSamples = [
            Self.sample("00000000-0000-0000-0000-000000000004", sequence: 4, interval: interval, recordingID: recordingID),
            Self.sample("00000000-0000-0000-0000-000000000005", sequence: 5, interval: interval, recordingID: recordingID)
        ]
        firstSampleIDs = firstSamples.map(\.id)
        nextSampleIDs = nextSamples.map(\.id)

        let firstCursor = CapturePageCursor(
            storeOpenID: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!,
            interval: interval,
            queryNow: queryNow,
            highWaterSequence: 5,
            deletionRevision: 0,
            lastObservedAt: firstSamples[2].observedAt,
            lastSequence: 3
        )
        self.firstCursor = firstCursor
        firstPage = CapturePage(
            items: firstSamples.enumerated().map { index, sample in
                CaptureSampleEnvelope(sample: sample, epoch: epoch, sequence: Int64(index + 1))
            },
            encodedPayloadBytes: 0,
            nextCursor: firstCursor
        )
        nextPage = CapturePage(
            items: nextSamples.enumerated().map { index, sample in
                CaptureSampleEnvelope(sample: sample, epoch: epoch, sequence: Int64(index + 4))
            },
            encodedPayloadBytes: 0,
            nextCursor: nil
        )
    }

    private static func sample(
        _ id: String,
        sequence: Int,
        interval: CapturePageInterval,
        recordingID: UUID
    ) -> RouteSample {
        RouteSample(
            id: UUID(uuidString: id)!,
            recordingID: recordingID,
            observedAt: interval.start.addingTimeInterval(TimeInterval(sequence * 60)),
            latitude: Double(sequence) / 100,
            longitude: Double(sequence) / 100,
            horizontalAccuracy: 5,
            isStationary: false
        )
    }
}

private actor SyntheticVisualPersistence: LocalCapturePersistence, LocalCaptureHistoryReading {
    private let expectedInterval: CapturePageInterval
    private let expectedQueryNow: Date
    private let stoppedSnapshot: CaptureControlSnapshot
    private let firstCursor: CapturePageCursor
    private let firstPage: CapturePage
    private let nextPage: CapturePage
    private var controlReadCount = 0
    private var historyRequests: [LocalCaptureExperimentSyntheticVisualHistoryRequest] = []
    private var forbiddenActionCount = 0
    private var unexpectedCallCount = 0
    private var unexpectedHistoryRequestCount = 0

    init(
        interval: CapturePageInterval,
        queryNow: Date,
        stoppedSnapshot: CaptureControlSnapshot,
        firstCursor: CapturePageCursor,
        firstPage: CapturePage,
        nextPage: CapturePage
    ) {
        expectedInterval = interval
        expectedQueryNow = queryNow
        self.stoppedSnapshot = stoppedSnapshot
        self.firstCursor = firstCursor
        self.firstPage = firstPage
        self.nextPage = nextPage
    }

    func readControl() async throws -> CaptureControlSnapshot {
        controlReadCount += 1
        guard controlReadCount == 1 else {
            throw rejectUnexpectedCall()
        }
        return stoppedSnapshot
    }

    func beginRecording(
        recordingID: UUID,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        throw rejectForbiddenAction()
    }

    func appendBatch(
        _ samples: [RouteSample],
        epoch: CaptureEpoch,
        operationID: UUID,
        now: Date
    ) async throws -> CaptureBatchReceipt {
        throw rejectForbiddenAction()
    }

    func stopRecording(
        epoch: CaptureEpoch,
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureControlReceipt {
        throw rejectForbiddenAction()
    }

    func clearHistory(
        expectedControlRevision: Int64,
        operationID: UUID
    ) async throws -> CaptureClearReceipt {
        throw rejectForbiddenAction()
    }

    func lookupReceipt(operationID: UUID) async throws -> CaptureReceiptLookup {
        throw rejectUnexpectedCall()
    }

    func reconcileSamples(
        _ samples: [RouteSample],
        epoch: CaptureEpoch
    ) async throws -> [CaptureSampleReconciliation] {
        throw rejectUnexpectedCall()
    }

    func readPage(
        interval: CapturePageInterval,
        now: Date,
        limit: Int,
        cursor: CapturePageCursor?
    ) async throws -> CapturePage {
        historyRequests.append(LocalCaptureExperimentSyntheticVisualHistoryRequest(
            interval: interval,
            now: now,
            limit: limit,
            cursor: cursor
        ))
        guard interval == expectedInterval,
              now == expectedQueryNow,
              limit == LocalCaptureConsumerModel.defaultHistoryPageLimit else {
            throw rejectUnexpectedHistoryRequest()
        }
        switch historyRequests.count {
        case 1 where cursor == nil:
            return firstPage
        case 2 where cursor == firstCursor:
            return nextPage
        default:
            throw rejectUnexpectedHistoryRequest()
        }
    }

    func rejectUnexpectedReopen() async throws -> any LocalCapturePersistence {
        throw rejectUnexpectedCall()
    }

    func audit() -> SyntheticVisualPersistenceAudit {
        SyntheticVisualPersistenceAudit(
            controlSnapshot: stoppedSnapshot,
            controlReadCount: controlReadCount,
            historyRequests: historyRequests,
            forbiddenActionCount: forbiddenActionCount,
            unexpectedCallCount: unexpectedCallCount,
            unexpectedHistoryRequestCount: unexpectedHistoryRequestCount
        )
    }

    private func rejectForbiddenAction() -> SyntheticVisualFixtureError {
        forbiddenActionCount += 1
        return .forbiddenAction
    }

    private func rejectUnexpectedCall() -> SyntheticVisualFixtureError {
        unexpectedCallCount += 1
        return .unexpectedStoreCall
    }

    private func rejectUnexpectedHistoryRequest() -> SyntheticVisualFixtureError {
        unexpectedHistoryRequestCount += 1
        return .unexpectedHistoryRequest
    }
}

private struct SyntheticVisualPersistenceAudit: Sendable {
    let controlSnapshot: CaptureControlSnapshot
    let controlReadCount: Int
    let historyRequests: [LocalCaptureExperimentSyntheticVisualHistoryRequest]
    let forbiddenActionCount: Int
    let unexpectedCallCount: Int
    let unexpectedHistoryRequestCount: Int
}

private enum SyntheticVisualFixtureError: Error, Sendable {
    case forbiddenAction
    case unexpectedStoreCall
    case unexpectedHistoryRequest
    case locationSourceStarted
}

@MainActor
private final class SyntheticVisualLocationSource: RecorderLocationUpdateSource {
    private(set) var collectCount = 0

    func collect(_ receive: @escaping @MainActor (RecorderLocationUpdate) async -> Bool) async throws {
        collectCount += 1
        throw SyntheticVisualFixtureError.locationSourceStarted
    }
}

@MainActor
private final class SyntheticVisualAuthorization: RecorderAuthorizationObservation {
    let capabilities = LocationCapabilities(
        servicesEnabled: false,
        authorization: .denied,
        fullAccuracy: false
    )
    var onChange: (() -> Void)?
    private(set) var refreshCount = 0
    private(set) var requestCount = 0

    func refreshServicesEnabled() {
        refreshCount += 1
    }

    func requestWhenInUseAuthorization() {
        requestCount += 1
    }
}

@MainActor
private final class SyntheticVisualServicesStatus {
    private(set) var readCount = 0

    func read() async -> Bool {
        readCount += 1
        return false
    }
}

@MainActor
private final class SyntheticVisualRuntimePlatform: RecorderRuntimePlatform {
    private(set) var backgroundActivityHandleCount = 0
    private(set) var serviceSessionHandleCount = 0

    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle {
        backgroundActivityHandleCount += 1
        return SyntheticVisualRuntimeHandle()
    }

    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle {
        serviceSessionHandleCount += 1
        return SyntheticVisualRuntimeHandle()
    }
}

@MainActor
private final class SyntheticVisualRuntimeHandle: RecorderBackgroundActivityHandle, RecorderServiceSessionHandle {
    func collectDiagnostics(
        _ receive: @escaping @MainActor (RecorderServiceDiagnostic) async -> Void
    ) async throws {
        throw SyntheticVisualFixtureError.forbiddenAction
    }

    func invalidate() {}
}

@MainActor
private final class SyntheticVisualMaintenanceActions {
    private(set) var pruneCalls = 0
    private(set) var closeCalls = 0

    func recordPrune() {
        pruneCalls += 1
    }

    func recordClose() {
        closeCalls += 1
    }
}
