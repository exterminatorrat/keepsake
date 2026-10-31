import CryptoKit
import Foundation

struct CaptureEpoch: Codable, Equatable, Sendable {
    let recordingID: UUID
    let revision: Int64
}

enum CaptureControlKind: String, Codable, Equatable, Sendable {
    case begin
    case stop
}

struct CaptureControlReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let kind: CaptureControlKind
    let epoch: CaptureEpoch
    let controlRevision: Int64
    let commandDigest: String
}

struct CaptureControlSnapshot: Codable, Equatable, Sendable {
    let revision: Int64
    let activeEpoch: CaptureEpoch?
    let lastControlReceipt: CaptureControlReceipt?
}

struct CaptureSampleResult: Codable, Equatable, Sendable {
    let sampleID: UUID
    let disposition: SampleIngestResult
}

struct CaptureBatchReceipt: Codable, Equatable, Sendable {
    let operationID: UUID
    let epoch: CaptureEpoch
    let commandDigest: String
    let items: [CaptureSampleResult]
}

enum CaptureReceipt: Codable, Equatable, Sendable {
    case control(CaptureControlReceipt)
    case batch(CaptureBatchReceipt)
}

enum CaptureReceiptLookup: Equatable, Sendable {
    case found(CaptureReceipt)
    case unavailable
}

enum CaptureSampleMatch: Equatable, Sendable {
    case matching
    case conflicting
    case absentOrExpired
}

struct CaptureSampleReconciliation: Equatable, Sendable {
    let sampleID: UUID
    let match: CaptureSampleMatch
}

enum CapturePersistenceError: Error, Equatable, Sendable {
    case notFoundationStore
    case invalidControlState
    case staleControlRevision
    case staleEpoch
    case activeRecordingMismatch
    case revisionExhausted
    case operationConflict
    case batchTooLarge
    case outcomeUncertain(UUID)
    case notCommitted(RouteStoreError)
    case unavailable(RouteStoreError)
}

enum CapturePersistenceLimits {
    static let maximumBatchSamples = 64
    static let maximumPendingPayloadBytes = 256 * 1_024
    static let maximumReceiptCount = 4_096
    static let maximumReceiptBytes = 8 * 1_024 * 1_024
    static let maximumControlPayloadBytes = 4 * 1_024
    static let maximumReceiptPayloadBytes = 16 * 1_024
    static let receiptRetention: TimeInterval = 7 * 24 * 60 * 60
}

struct CaptureBatchInput: Sendable {
    let samples: [RouteSample]
    let encodedPayloadBytes: Int

    init(samples: [RouteSample]) throws {
        guard samples.count <= CapturePersistenceLimits.maximumBatchSamples else {
            throw CapturePersistenceError.batchTooLarge
        }
        var bytes = 0
        for sample in samples where sample.isValid {
            let payload = try JSONEncoder().encode(sample)
            guard payload.count <= CapturePersistenceLimits.maximumPendingPayloadBytes - bytes else {
                throw CapturePersistenceError.batchTooLarge
            }
            bytes += payload.count
        }
        self.samples = samples
        encodedPayloadBytes = bytes
    }
}

enum CaptureCommandDigest {
    static func begin(recordingID: UUID, expectedControlRevision: Int64) -> String {
        digest("capture-v2|begin|\(recordingID.uuidString)|\(expectedControlRevision)")
    }

    static func stop(epoch: CaptureEpoch, expectedControlRevision: Int64) -> String {
        digest("capture-v2|stop|\(epoch.recordingID.uuidString)|\(epoch.revision)|\(expectedControlRevision)")
    }

    static func batch(epoch: CaptureEpoch, input: CaptureBatchInput) -> String {
        var content = "capture-v2|batch|\(epoch.recordingID.uuidString)|\(epoch.revision)"
        for sample in input.samples {
            let fields = [
                sample.id.uuidString,
                sample.recordingID.uuidString,
                String(sample.observedAt.timeIntervalSinceReferenceDate.bitPattern),
                String(sample.latitude.bitPattern),
                String(sample.longitude.bitPattern),
                String(sample.horizontalAccuracy.bitPattern),
                bits(sample.altitude),
                bits(sample.verticalAccuracy),
                bits(sample.speed),
                bits(sample.speedAccuracy),
                bits(sample.course),
                bits(sample.courseAccuracy),
                sample.isStationary ? "1" : "0"
            ]
            content += "|" + fields.joined(separator: ",")
        }
        return digest(content)
    }

    private static func bits(_ value: Double?) -> String {
        value.map { String($0.bitPattern) } ?? "nil"
    }

    private static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

protocol LocalCapturePersistence: Sendable {
    func readControl() async throws -> CaptureControlSnapshot
    func beginRecording(recordingID: UUID, expectedControlRevision: Int64, operationID: UUID) async throws -> CaptureControlReceipt
    func appendBatch(_ samples: [RouteSample], epoch: CaptureEpoch, operationID: UUID, now: Date) async throws -> CaptureBatchReceipt
    func stopRecording(epoch: CaptureEpoch, expectedControlRevision: Int64, operationID: UUID) async throws -> CaptureControlReceipt
    func lookupReceipt(operationID: UUID) async throws -> CaptureReceiptLookup
    func reconcileSamples(_ samples: [RouteSample], epoch: CaptureEpoch) async throws -> [CaptureSampleReconciliation]
}
