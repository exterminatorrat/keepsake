import Foundation
import Testing
@testable import Keepsake

struct RouteRepositoryTests {
    @Test func appendRejectsInvalidDuplicateOutOfOrderAndExpiredSamples() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = RouteRepository(fileURL: directory.appendingPathComponent("history.jsonl"))
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sessionID = UUID()
        let first = makeSample(sessionID: sessionID, seconds: 900_000)

        #expect(try await repository.append(first, now: now) == .stored)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: 900_000), now: now) == .duplicate)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: 899_999), now: now) == .outOfOrder)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: 900_001, latitude: 91), now: now) == .invalid)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: now.timeIntervalSince1970 + 61), now: now) == .invalid)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: now.timeIntervalSince1970 - 91 * 86_400), now: now) == .expired)
        #expect(try await repository.append(makeSample(sessionID: sessionID, seconds: 900_002, speed: -1), now: now) == .invalid)

        let stored = try await repository.load(now: now)
        #expect(stored.samples.map(\.id) == [first.id])
    }

    @Test func samplesAndStableIDsSurviveRepositoryRecreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.jsonl")
        let repository = RouteRepository(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: 900_000, id: UUID())

        #expect(try await repository.append(sample, now: now) == .stored)

        let directoryValues = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)

        let recovered = try await RouteRepository(fileURL: fileURL).load(now: now)
        #expect(recovered.samples == [sample])
        #expect(recovered.samples.first?.id == sample.id)
    }

    @Test func recoveryDropsOnlyAnIncompleteFinalRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.jsonl")
        let repository = RouteRepository(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: 900_000)

        #expect(try await repository.append(sample, now: now) == .stored)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":".utf8))
        try handle.close()

        let recovered = try await RouteRepository(fileURL: fileURL).load(now: now)
        #expect(recovered.recoveredIncompleteTail)
        #expect(recovered.samples == [sample])

        let secondRecovery = try await RouteRepository(fileURL: fileURL).load(now: now)
        #expect(!secondRecovery.recoveredIncompleteTail)
        #expect(secondRecovery.samples == [sample])
    }

    @Test func retentionRemovesSamplesOlderThanNinetyDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("history.jsonl")
        let repository = RouteRepository(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: now.timeIntervalSince1970 - 89 * 86_400)

        #expect(try await repository.append(sample, now: now) == .stored)

        let afterRetention = try await RouteRepository(fileURL: fileURL).load(now: now.addingTimeInterval(2 * 86_400))
        #expect(afterRetention.samples.isEmpty)
    }
}

private func makeSample(
    sessionID: UUID,
    seconds: TimeInterval,
    latitude: Double = 37.3349,
    longitude: Double = -122.0090,
    accuracy: Double = 8,
    speed: Double = 1.2,
    id: UUID = UUID()
) -> RouteSample {
    RouteSample(
        id: id,
        recordingID: sessionID,
        observedAt: Date(timeIntervalSince1970: seconds),
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracy: accuracy,
        speed: speed,
        course: 90,
        isStationary: false
    )
}
