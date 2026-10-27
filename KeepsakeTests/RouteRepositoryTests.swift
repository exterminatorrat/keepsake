import Foundation
import Darwin
import Synchronization
import Testing
@testable import Keepsake

struct RouteRepositoryTests {
    @Test func appendRejectsInvalidDuplicateOutOfOrderAndExpiredSamples() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = makeTestRepository(fileURL: fixture.fileURL)
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
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let repository = makeTestRepository(fileURL: fixture.fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: 900_000, id: UUID())

        #expect(try await repository.append(sample, now: now) == .stored)

        let directoryValues = try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(directoryValues.isExcludedFromBackup == true)
        let fileValues = try fixture.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(fileValues.isExcludedFromBackup == true)
        #if !targetEnvironment(simulator)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: fixture.directory.path)
        #expect(directoryAttributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        let fileAttributes = try FileManager.default.attributesOfItem(atPath: fixture.fileURL.path)
        #expect(fileAttributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif

        let recovered = try await makeTestRepository(fileURL: fixture.fileURL).load(now: now)
        #expect(recovered.samples == [sample])
        #expect(recovered.samples.first?.id == sample.id)
    }

    @Test func appendDoesNotWritePlaintextBeforeProtectionVerification() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileName = fixture.fileURL.lastPathComponent
        let rejectUnavailableFileMetadata: @Sendable (URL, RouteStoreProtectedItem) throws -> Void = { url, item in
            if item == .file && url.lastPathComponent == fileName {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
                    throw RouteStoreError.writeFailed
                }
                try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in nil })
            }
            try protectForRepositoryTest(url, as: item)
        }
        let repository = RouteRepository(fileURL: fixture.fileURL, protectAndVerify: rejectUnavailableFileMetadata)
        let now = Date(timeIntervalSince1970: 1_000_000)

        await expectRouteStorageError(.protectionFailed) {
            _ = try await repository.append(
                makeSample(
                    sessionID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000005")),
                    seconds: 900_000,
                    id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000006"))
                ),
                now: now
            )
        }
        #expect(try Data(contentsOf: fixture.fileURL).isEmpty)
        #expect(try fixture.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    }

    @Test func callerSuppliedSymlinkedDirectoryIsRejected() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let aliasURL = fixture.directory.appendingPathExtension("alias")
        defer { try? FileManager.default.removeItem(at: aliasURL) }
        try FileManager.default.createSymbolicLink(at: aliasURL, withDestinationURL: fixture.directory)
        let fileURL = aliasURL.appendingPathComponent("history.jsonl")
        let repository = makeTestRepository(fileURL: fileURL)

        await expectRouteStorageError(.writeFailed) {
            _ = try await repository.append(
                makeSample(
                    sessionID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000009")),
                    seconds: 900_000,
                    id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000010"))
                ),
                now: Date(timeIntervalSince1970: 1_000_000)
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.fileURL.path))
    }

    @Test func postWriteProtectionFailureReturnsUncertainAndReconcilesOnReopen() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileName = fixture.fileURL.lastPathComponent
        let rejectProtectedArchiveAfterWrite: @Sendable (URL, RouteStoreProtectedItem) throws -> Void = { url, item in
            if item == .file && url.lastPathComponent == fileName {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 {
                    throw RouteStoreError.protectionFailed
                }
            }
            try protectForRepositoryTest(url, as: item)
        }
        let repository = RouteRepository(fileURL: fixture.fileURL, protectAndVerify: rejectProtectedArchiveAfterWrite)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(
            sessionID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000011")),
            seconds: 900_000,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000012"))
        )

        await expectRouteStorageError(.writeOutcomeUncertain) {
            _ = try await repository.append(sample, now: now)
        }
        let reopened = try await makeTestRepository(fileURL: fixture.fileURL).load(now: now)
        #expect(reopened.samples == [sample])
        #expect(reopened.samples.map(\.id) == [sample.id])
    }

    @Test func incompleteTailRewriteProtectsItsTemporaryFileBeforeWriting() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sample = makeSample(
            sessionID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000007")),
            seconds: 900_000,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000008"))
        )
        var original = try JSONEncoder().encode(sample)
        original.append(0x0A)
        original.append(Data("{\"partial\":".utf8))
        try original.write(to: fixture.fileURL)
        let rejectUnprotectedRewrite: @Sendable (URL, RouteStoreProtectedItem) throws -> Void = { url, item in
            if item == .file && url.lastPathComponent.hasPrefix(".route-history-") {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
                    throw RouteStoreError.writeFailed
                }
                try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in nil })
            }
            try protectForRepositoryTest(url, as: item)
        }
        let repository = RouteRepository(fileURL: fixture.fileURL, protectAndVerify: rejectUnprotectedRewrite)

        await expectRouteStorageError(.protectionFailed) {
            _ = try await repository.load(now: Date(timeIntervalSince1970: 1_000_000))
        }
        #expect(try Data(contentsOf: fixture.fileURL) == original)
    }

    @Test func postRenameProtectionFailureReturnsUncertainAndReconcilesOnReopen() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try FileManager.default.createDirectory(
            at: fixture.directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let sample = makeSample(
            sessionID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000013")),
            seconds: 900_000,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000014"))
        )
        var rewrittenArchive = try JSONEncoder().encode(sample)
        rewrittenArchive.append(0x0A)
        let rewrittenSize = rewrittenArchive.count
        let partialTail = Data("{\"partial\":".utf8)
        var original = rewrittenArchive
        original.append(partialTail)
        try original.write(to: fixture.fileURL)
        let fileName = fixture.fileURL.lastPathComponent
        let preparedPayload = Mutex<Data?>(nil)
        let rejectPublishedRewrite: @Sendable (URL, RouteStoreProtectedItem) throws -> Void = { url, item in
            if item == .file,
               url.lastPathComponent.hasPrefix(".route-history-"),
               url.pathExtension == "pending" {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if ((attributes[.size] as? NSNumber)?.intValue ?? 0) > 0 {
                    let data = try Data(contentsOf: url)
                    preparedPayload.withLock { $0 = data }
                }
            }
            if item == .file && url.lastPathComponent == fileName {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                if (attributes[.size] as? NSNumber)?.intValue == rewrittenSize {
                    throw RouteStoreError.protectionFailed
                }
            }
            try protectForRepositoryTest(url, as: item)
        }
        let repository = RouteRepository(fileURL: fixture.fileURL, protectAndVerify: rejectPublishedRewrite)

        await expectRouteStorageError(.writeOutcomeUncertain) {
            _ = try await repository.load(now: Date(timeIntervalSince1970: 1_000_000))
        }
        let prepared = try #require(preparedPayload.withLock { $0 })
        let published = try Data(contentsOf: fixture.fileURL)
        #expect(!prepared.isEmpty)
        #expect(published == prepared)
        #expect(published.last == 0x0A)
        #expect(published.filter { $0 == 0x0A }.count == 1)
        let decoded = try JSONDecoder().decode(RouteSample.self, from: Data(published.dropLast()))
        #expect(RouteStoreFiles.exactSamplesEquality([decoded], [sample]))
        let reopened = try await makeTestRepository(fileURL: fixture.fileURL).load(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(!reopened.recoveredIncompleteTail)
        #expect(reopened.samples == [sample])
        #expect(reopened.samples.map(\.id) == [sample.id])
    }

    @Test func recoveryDropsOnlyAnIncompleteFinalRecord() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileURL = fixture.fileURL
        let repository = makeTestRepository(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: 900_000)

        #expect(try await repository.append(sample, now: now) == .stored)
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial\":".utf8))
        try handle.close()

        let recovered = try await makeTestRepository(fileURL: fileURL).load(now: now)
        #expect(recovered.recoveredIncompleteTail)
        #expect(recovered.samples == [sample])

        let secondRecovery = try await makeTestRepository(fileURL: fileURL).load(now: now)
        #expect(!secondRecovery.recoveredIncompleteTail)
        #expect(secondRecovery.samples == [sample])
    }

    @Test func retentionRemovesSamplesOlderThanNinetyDays() async throws {
        let fixture = try makeRepositoryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fileURL = fixture.fileURL
        let repository = makeTestRepository(fileURL: fileURL)
        let now = Date(timeIntervalSince1970: 1_000_000)
        let sample = makeSample(sessionID: UUID(), seconds: now.timeIntervalSince1970 - 89 * 86_400)

        #expect(try await repository.append(sample, now: now) == .stored)

        let afterRetention = try await makeTestRepository(fileURL: fileURL).load(now: now.addingTimeInterval(2 * 86_400))
        #expect(afterRetention.samples.isEmpty)
    }
}

private func makeRepositoryFixture() throws -> (directory: URL, fileURL: URL) {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw RouteStorageError.writeFailed
    }
    defer { Darwin.free(resolved) }
    let directory = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("RouteRepository-\(UUID().uuidString)", isDirectory: true)
    return (directory, directory.appendingPathComponent("history.jsonl"))
}

private func makeTestRepository(fileURL: URL) -> RouteRepository {
    RouteRepository(fileURL: fileURL, protectAndVerify: protectForRepositoryTest)
}

private func protectForRepositoryTest(_ url: URL, as item: RouteStoreProtectedItem) throws {
    if item == .file {
        try RouteStoreFiles.validateOwnedRegularFile(url, requirePrivate: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    #if targetEnvironment(simulator)
    try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
        .completeUntilFirstUserAuthentication
    })
    #else
    try RouteStoreFiles.protectAndVerify(url, as: item)
    #endif
}

private func expectRouteStorageError(
    _ expected: RouteStorageError,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected a typed RouteStorageError", sourceLocation: sourceLocation)
    } catch let error as RouteStorageError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
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
