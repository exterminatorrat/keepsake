import CryptoKit
import Foundation
@testable import Keepsake

enum ResourceWorkloadStage: String, CaseIterable, Sendable {
    case b0 = "B0"
    case stationary
    case walk
    case drive
    case h1 = "H1"
    case h2 = "H2"

    var rowCount: Int {
        switch self {
        case .b0, .stationary, .walk, .drive:
            return 60
        case .h1:
            return 1_440
        case .h2:
            return 10_080
        }
    }

    var timeWindowSeconds: TimeInterval {
        isHistory ? 86_400 : 600
    }

    var sampleIntervalSeconds: TimeInterval {
        isHistory ? 60 : 10
    }

    var queryIntervalCount: Int {
        self == .h2 ? 7 : 1
    }

    var pageCountPerInterval: Int {
        isHistory ? 12 : 1
    }

    var isHistory: Bool {
        self == .h1 || self == .h2
    }
}

struct ResourceWorkloadFixture: Sendable {
    static let anchor: Date = Date(timeIntervalSince1970: 1_767_225_600)
    static let repetitionCount = 5
    static let batchRowLimit = 32
    static let pageLimitRows = 128

    let stage: ResourceWorkloadStage
    let repetition: Int
    let recordingID: UUID

    init(stage: ResourceWorkloadStage, repetition: Int) {
        precondition((1...Self.repetitionCount).contains(repetition))
        self.stage = stage
        self.repetition = repetition
        recordingID = Self.stableUUID(stage: stage, repetition: repetition, kind: "recording", index: 0)
    }

    var batchCount: Int {
        (stage.rowCount + Self.batchRowLimit - 1) / Self.batchRowLimit
    }

    var pageIntervalCount: Int {
        stage.queryIntervalCount
    }

    var apiCalls: ResourceWorkloadAPICallOracle {
        ResourceWorkloadAPICallOracle(
            appendBatchCalls: batchCount,
            readPageCalls: stage.queryIntervalCount * stage.pageCountPerInterval
        )
    }

    var stopOracle: ResourceWorkloadStopOracle {
        ResourceWorkloadStopOracle()
    }

    func sample(at index: Int) -> RouteSample {
        precondition((0..<stage.rowCount).contains(index))
        let position = positionXY(at: index)

        return RouteSample(
            id: Self.stableUUID(stage: stage, repetition: repetition, kind: "sample", index: index),
            recordingID: recordingID,
            observedAt: Self.anchor.addingTimeInterval(Double(index) * stage.sampleIntervalSeconds),
            latitude: position.y / 6_378_137 * 180 / .pi,
            longitude: position.x / 6_378_137 * 180 / .pi,
            horizontalAccuracy: 5,
            isStationary: isStationary(at: index)
        )
    }

    func batch(at batchIndex: Int) -> [RouteSample] {
        precondition((0..<batchCount).contains(batchIndex))
        let start = batchIndex * Self.batchRowLimit
        let end = min(start + Self.batchRowLimit, stage.rowCount)
        return (start..<end).map { sample(at: $0) }
    }

    func pageInterval(at intervalIndex: Int) -> ResourceWorkloadPageInterval {
        precondition((0..<pageIntervalCount).contains(intervalIndex))
        let startOffset = stage == .h2 ? Double(intervalIndex * 86_400) : 0
        let endOffset = startOffset + stage.timeWindowSeconds
        let queryNowOffset = stage == .h2 ? 604_800 : stage.timeWindowSeconds

        return ResourceWorkloadPageInterval(
            interval: CapturePageInterval(
                start: Self.anchor.addingTimeInterval(startOffset),
                end: Self.anchor.addingTimeInterval(endOffset)
            ),
            queryNow: Self.anchor.addingTimeInterval(queryNowOffset),
            pageCount: stage.pageCountPerInterval
        )
    }

    private func positionXY(at index: Int) -> (x: Double, y: Double) {
        switch stage {
        case .b0:
            return (x: Double(index), y: 0)
        case .stationary:
            let point = Self.jitterCycle[index % Self.jitterCycle.count]
            return (x: point.0, y: point.1)
        case .walk:
            let movingSteps = index - (index >= 30 ? 1 : 0)
            let distance = 600 * Double(movingSteps) / 58
            return Self.positionOnPolyline(distance, vertices: Self.walkVertices)
        case .drive:
            let movingSteps = index - (index >= 21 ? 1 : 0) - (index >= 41 ? 1 : 0)
            let distance = 5_000 * Double(movingSteps) / 57
            return Self.positionOnPolyline(distance, vertices: Self.driveVertices)
        case .h1, .h2:
            return (x: 0.25 * Double(index % 60), y: 0.25 * Double(index / 60))
        }
    }

    private func isStationary(at index: Int) -> Bool {
        switch stage {
        case .stationary:
            return true
        case .walk:
            return index == 29 || index == 30
        case .drive:
            return index == 20 || index == 21 || index == 40 || index == 41
        case .b0, .h1, .h2:
            return false
        }
    }

    private static func stableUUID(
        stage: ResourceWorkloadStage,
        repetition: Int,
        kind: String,
        index: Int
    ) -> UUID {
        let seed = "KEEP8-RW-v1/\(stage.rawValue)/\(repetition)/\(kind)/\(index)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private static func positionOnPolyline(
        _ distance: Double,
        vertices: [(Double, Double)]
    ) -> (x: Double, y: Double) {
        var remaining = distance

        for (start, end) in zip(vertices, vertices.dropFirst()) {
            let deltaX = end.0 - start.0
            let deltaY = end.1 - start.1
            let length = hypot(deltaX, deltaY)
            if remaining <= length {
                let fraction = remaining / length
                return (x: start.0 + deltaX * fraction, y: start.1 + deltaY * fraction)
            }
            remaining -= length
        }

        let lastVertex = vertices[vertices.count - 1]
        return (x: lastVertex.0, y: lastVertex.1)
    }

    private static let jitterCycle: [(Double, Double)] = [
        (0, 0), (0.5, 0), (0.5, 0.5), (0, 0.5), (-0.5, 0.5),
        (-0.5, 0), (-0.5, -0.5), (0, -0.5), (0.5, -0.5), (0, 0)
    ]

    private static let walkVertices: [(Double, Double)] = [
        (0, 0), (200, 0), (200, 200), (400, 200)
    ]

    private static let driveVertices: [(Double, Double)] = [
        (0, 0), (2_000, 0), (2_000, 1_000), (4_000, 1_000)
    ]
}

struct ResourceWorkloadPageInterval: Equatable, Sendable {
    let interval: CapturePageInterval
    let queryNow: Date
    let pageCount: Int

    func rowCount(at pageIndex: Int) -> Int {
        precondition((0..<pageCount).contains(pageIndex))
        return pageCount == 1 ? 60 : (pageIndex == pageCount - 1 ? 32 : 128)
    }
}

struct ResourceWorkloadAPICallOracle: Equatable, Sendable {
    let openCreateEmpty: Int
    let readControl: Int
    let beginRecording: Int
    let appendBatchCalls: Int
    let stopRecording: Int
    let reopenVerified: Int
    let lookupStopReceipt: Int
    let readPageCalls: Int
    let finalClose: Int
    let closeTotalIncludingReopenVerified: Int
    let clearHistory: Int
    let pruneHistory: Int
    let reconcileSamples: Int
    let runtimeStartOrCoreLocationCalls: Int
    let runtimeStopCalls: Int

    init(appendBatchCalls: Int, readPageCalls: Int) {
        openCreateEmpty = 1
        readControl = 2
        beginRecording = 1
        self.appendBatchCalls = appendBatchCalls
        stopRecording = 1
        reopenVerified = 1
        lookupStopReceipt = 1
        self.readPageCalls = readPageCalls
        finalClose = 1
        closeTotalIncludingReopenVerified = 2
        clearHistory = 0
        pruneHistory = 0
        reconcileSamples = 0
        runtimeStartOrCoreLocationCalls = 0
        runtimeStopCalls = 0
    }
}

struct ResourceWorkloadStopOracle: Equatable, Sendable {
    let beginExpectedControlRevision: Int64
    let stopOperationCount: Int
    let receiptKind: CaptureControlKind
    let stopUsesBeginReceiptControlRevision: Bool
    let receiptUsesBeginEpoch: Bool
    let receiptControlRevisionIncrement: Int64
    let activeEpochAfterStopIsNil: Bool
    let snapshotMatchesReceiptAfterReopen: Bool
    let lookupReturnsSameReceiptAfterReopen: Bool
    let retryOrReconcileOnUncertainOutcome: Bool

    init() {
        beginExpectedControlRevision = 0
        stopOperationCount = 1
        receiptKind = .stop
        stopUsesBeginReceiptControlRevision = true
        receiptUsesBeginEpoch = true
        receiptControlRevisionIncrement = 1
        activeEpochAfterStopIsNil = true
        snapshotMatchesReceiptAfterReopen = true
        lookupReturnsSameReceiptAfterReopen = true
        retryOrReconcileOnUncertainOutcome = false
    }
}
