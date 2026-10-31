import Foundation
import Darwin
import SQLite3
import Testing
@testable import Keepsake

struct RouteStoreTests {
    @Test(.enabled(if: !modelsSimulatorProtection, "File-protection metadata requires iOS hardware"))
    func fileProtectionMetadataReportsConfiguredClass() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let file = fixture.container.appendingPathComponent("synthetic-protection-probe")
        try Data().write(to: file)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: file.path
        )
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        let raw = attributes[.protectionKey]
        let typed = raw as? FileProtectionType
        let string = raw as? String
        print("StorageProtectionProbe present=\(raw != nil) typed=\(typed?.rawValue ?? "none") string=\(string ?? "none")")
        #expect(typed == .completeUntilFirstUserAuthentication
            || string == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
    }

    @Test func strictProtectionVerifierRejectsMissingOrWrongMetadata() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let file = fixture.container.appendingPathComponent("synthetic-protection-verification")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let unacceptable: [FileProtectionType?] = [nil, .some(.none), .some(.complete)]
        for value in unacceptable {
            expectStoreError(.protectionFailed) {
                try RouteStoreFiles.protectAndVerify(file, as: .file, readProtection: { _ in value })
            }
        }
    }

    @Test func protectionVerificationReopensReadOnlyBackupExcludedFiles() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let file = fixture.container.appendingPathComponent("synthetic-read-only-metadata")
        try Data().write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try protectForStorageTest(file, as: .file)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: file.path)
        // Recreate URL so this assertion cannot pass from the setter's URL cache.
        let reopened = URL(fileURLWithPath: file.path)
        #expect(try reopened.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        try protectForStorageTest(reopened, as: .file)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        #expect((((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222) == 0)
    }

    @Test func posixCanonicalOwnedPathsPassButSymlinkAncestorsRemainRejected() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        print("StoragePathProbe foundationAgreesWithPOSIX=\(fixture.container.standardizedFileURL.path == fixture.container.path)")
        try RouteStoreFiles.validateOwnedDirectory(fixture.container, requirePrivate: true)
        let realDirectory = fixture.container.appendingPathComponent("owned-target", isDirectory: true)
        try FileManager.default.createDirectory(at: realDirectory, withIntermediateDirectories: false,
                                              attributes: [.posixPermissions: 0o700])
        let alias = fixture.container.appendingPathComponent("synthetic-alias", isDirectory: true)
        try FileManager.default.createSymbolicLink(atPath: alias.path, withDestinationPath: realDirectory.path)
        expectStoreError(.unsafePath) {
            try RouteStoreFiles.validateOwnedDirectory(alias, requirePrivate: true)
        }
        expectStoreError(.unsafePath) {
            try RouteStoreFiles.validateNewRoot(alias.appendingPathComponent("new-store", isDirectory: true))
        }
    }

    @Test(arguments: ["https", "file"])
    func ownedDirectoriesRejectNonFileSchemesAndRemoteFileAuthorities(_ scheme: String) throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        var components = URLComponents()
        components.scheme = scheme
        // Each case isolates one guard: non-file scheme with a local authority,
        // or file scheme with a remote authority, both naming an owned path.
        components.host = scheme == "file" ? "untrusted.invalid" : "localhost"
        components.path = fixture.container.path
        let unsupported = try #require(components.url)
        try #require(unsupported.path == fixture.container.path)
        // Rejection must come from URL validation, not a broken local fixture.
        try RouteStoreFiles.validateOwnedDirectory(fixture.container, requirePrivate: true)
        expectStoreError(.unsafePath) {
            try RouteStoreFiles.validateOwnedDirectory(unsupported, requirePrivate: true)
        }
        expectStoreError(.unsafePath) {
            try RouteStoreFiles.validateNewRoot(unsupported.appendingPathComponent("new-store", isDirectory: true))
        }
    }

    @Test(arguments: ["https", "file"])
    func storeFactoriesRejectUnsupportedRootURLsBeforeNormalization(_ scheme: String) throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let source = fixture.container.appendingPathComponent("synthetic-empty-legacy.jsonl")
        try Data().write(to: source)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: source.path)
        // A valid local path reaches these seams. An unsupported URL must fail
        // earlier, without creating a store or changing existing metadata.
        let noWrites = storageTestSeams(
            protectAndVerify: { _, _ in throw RouteStoreError.writeFailed },
            requireCapacity: { _, _, _ in throw RouteStoreError.writeFailed }
        )
        expectStoreError(.writeFailed) {
            _ = try StorageTestFactory.createNew(at: fixture.store, seams: noWrites)
        }
        expectStoreError(.writeFailed) {
            _ = try StorageTestFactory.openExisting(at: fixture.container, seams: noWrites)
        }
        expectStoreError(.writeFailed) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: source, to: fixture.store, authorization: .stopped, seams: noWrites
            )
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = scheme == "file" ? "untrusted.invalid" : "localhost"
        components.path = fixture.container.path
        let unsupportedExisting = try #require(components.url)
        components.path = fixture.store.path
        let unsupportedNew = try #require(components.url)
        try #require(unsupportedExisting.path == fixture.container.path)
        try #require(unsupportedNew.path == fixture.store.path)
        expectStoreError(.unsafePath) {
            _ = try StorageTestFactory.createNew(at: unsupportedNew, seams: noWrites)
        }
        expectStoreError(.unsafePath) {
            _ = try StorageTestFactory.openExisting(at: unsupportedExisting, seams: noWrites)
        }
        expectStoreError(.unsafePath) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: source, to: unsupportedNew, authorization: .stopped, seams: noWrites
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.path))
        #expect(try Data(contentsOf: source).isEmpty)
    }

    @Test func createAppendCloseAndReopenPreservesExactDatesOptionalsAndIdentities() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let first = makeSample(
            at: 1_999_999_000.1234567,
            recordingID: UUID(),
            includeOptionalMeasurements: true,
            stationary: true
        )
        let second = makeSample(
            at: 1_999_999_060.875,
            recordingID: UUID(),
            includeOptionalMeasurements: false
        )
        let store = try StorageTestFactory.createNew(at: fixture.store)

        #expect(try await store.append(first, now: now) == .stored)
        #expect(try await store.append(second, now: now) == .stored)
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        let loaded = try await reopened.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [first, second]))
        try #require(loaded.samples.count == 2)
        #expect(loaded.samples[0].observedAt.timeIntervalSinceReferenceDate.bitPattern == first.observedAt.timeIntervalSinceReferenceDate.bitPattern)
        #expect(loaded.samples[0].altitude == first.altitude)
        #expect(loaded.samples[0].verticalAccuracy == first.verticalAccuracy)
        #expect(loaded.samples[0].speed == first.speed)
        #expect(loaded.samples[0].speedAccuracy == first.speedAccuracy)
        #expect(loaded.samples[0].course == first.course)
        #expect(loaded.samples[0].courseAccuracy == first.courseAccuracy)
        #expect(loaded.samples[0].isStationary)
        #expect(loaded.samples[1].altitude == nil)
        #expect(loaded.samples[1].verticalAccuracy == nil)
        #expect(loaded.samples[1].speed == nil)
        #expect(loaded.samples[1].speedAccuracy == nil)
        #expect(loaded.samples[1].course == nil)
        #expect(loaded.samples[1].courseAccuracy == nil)
        await reopened.close()
    }

    @Test func indexedSignedZeroValuesSurviveSQLiteRoundTrip() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 1_000)
        let sample = makeSample(
            at: -0.0,
            latitude: -0.0,
            longitude: -0.0
        )
        let store = try StorageTestFactory.createNew(at: fixture.store)

        #expect(try await store.append(sample, now: now) == .stored)
        let loaded = try await store.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [sample]))
        try #require(loaded.samples.count == 1)
        #expect(loaded.samples[0].observedAt.timeIntervalSinceReferenceDate.bitPattern == Double(-0.0).bitPattern)
        #expect(loaded.samples[0].latitude.bitPattern == Double(-0.0).bitPattern)
        #expect(loaded.samples[0].longitude.bitPattern == Double(-0.0).bitPattern)
        await store.close()
    }

    @Test func appendRetainsExistingValidityDeduplicationAndStrictOrderPolicies() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let first = makeSample(at: now.timeIntervalSinceReferenceDate - 1_000)
        let store = try StorageTestFactory.createNew(at: fixture.store)

        #expect(try await store.append(first, now: now) == .stored)
        #expect(try await store.append(first, now: now) == .duplicate)
        #expect(try await store.append(
            makeSample(at: first.observedAt.timeIntervalSinceReferenceDate, id: UUID(), recordingID: UUID()),
            now: now
        ) == .duplicate)
        #expect(try await store.append(makeSample(at: first.observedAt.timeIntervalSinceReferenceDate - 1), now: now) == .outOfOrder)
        #expect(try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate + 61), now: now) == .invalid)
        #expect(try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate - 90 * 86_400 - 1), now: now) == .expired)
        #expect(try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate, latitude: 91), now: now) == .invalid)

        let loaded = try await store.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [first]))
        await store.close()
    }

    @Test func retentionKeepsTheExactNinetyDayBoundaryThenPrunesAtomically() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let boundary = makeSample(at: now.timeIntervalSinceReferenceDate - 90 * 86_400)
        let store = try StorageTestFactory.createNew(at: fixture.store)

        #expect(try await store.append(boundary, now: now) == .stored)
        #expect(RouteStoreFiles.exactSamplesEquality(try await store.load(now: now).samples, [boundary]))
        #expect(try await store.append(
            makeSample(at: boundary.observedAt.timeIntervalSinceReferenceDate - 0.5),
            now: now
        ) == .expired)
        #expect(try await store.load(now: now.addingTimeInterval(1)).samples.isEmpty)
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now.addingTimeInterval(1)).samples.isEmpty)
        await reopened.close()
    }

    @Test func mapSegmentationRemainsEquivalentForStoredSyntheticSamples() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let session = UUID()
        let base = 1_999_000_000.0
        let samples = [
            makeSample(at: base, recordingID: session),
            makeSample(at: base + 60, recordingID: session),
            makeSample(at: base + 400, recordingID: session),
            makeSample(at: base + 420, recordingID: session),
            makeSample(at: base + 450, recordingID: session, accuracy: 150),
            makeSample(at: base + 480, recordingID: session)
        ]
        let expected = RouteHistory.segments(from: samples)
        let store = try StorageTestFactory.createNew(at: fixture.store)

        for sample in samples {
            #expect(try await store.append(sample, now: Date(timeIntervalSinceReferenceDate: base + 1_000)) == .stored)
        }
        let loaded = try await store.load(now: Date(timeIntervalSinceReferenceDate: base + 1_000))
        #expect(RouteHistory.segments(from: loaded.samples) == expected)
        await store.close()
    }

    @Test func stoppedMigrationPreservesSnapshotAndExportsPostImportAppends() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let first = makeSample(at: now.timeIntervalSinceReferenceDate - 600)
        let second = makeSample(at: now.timeIntervalSinceReferenceDate - 540)
        var sourceBytes = try legacyArchive([first, second])
        sourceBytes.append(Data("{\"partial\":".utf8))
        let sourceURL = fixture.container.appendingPathComponent("synthetic-route-history.jsonl")
        try sourceBytes.write(to: sourceURL)

        let store = try StorageTestFactory.migrateStoppedLegacyFile(
            at: sourceURL,
            to: fixture.store,
            authorization: .stopped
        )
        let loaded = try await store.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [first, second]))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)

        let snapshotURL = fixture.store.appendingPathComponent(RouteStoreFiles.snapshotName)
        #expect(try Data(contentsOf: snapshotURL) == sourceBytes)
        let snapshotAttributes = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        #expect((((snapshotAttributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222) == 0)
        #if !targetEnvironment(simulator)
        #expect(snapshotAttributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
        #endif
        #expect(try snapshotURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        // The source deliberately has an incomplete final record. Its exact bytes
        // are preserved above; only the successfully imported records are decoded.

        let appended = makeSample(at: now.timeIntervalSinceReferenceDate - 480)
        #expect(try await store.append(appended, now: now) == .stored)
        let exportURL = fixture.container.appendingPathComponent("synthetic-export.jsonl")
        try await store.exportCompatibleLegacy(to: exportURL, now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(try decodedArchive(Data(contentsOf: exportURL)), [first, second, appended]))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
        await expectStoreError(.destinationExists) {
            try await store.exportCompatibleLegacy(to: exportURL, now: now)
        }
        await store.close()
    }

    @Test func completeRecordWithoutFinalNewlineMigratesWithoutChangingSource() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let sample = makeSample(at: now.timeIntervalSinceReferenceDate - 120)
        var bytes = try legacyArchive([sample])
        bytes.removeLast()
        let sourceURL = fixture.container.appendingPathComponent("synthetic-complete-no-newline.jsonl")
        try bytes.write(to: sourceURL)

        let store = try StorageTestFactory.migrateStoppedLegacyFile(at: sourceURL, to: fixture.store, authorization: .stopped)
        #expect(RouteStoreFiles.exactSamplesEquality(try await store.load(now: now).samples, [sample]))
        #expect(try Data(contentsOf: sourceURL) == bytes)
        await store.close()
    }

    @Test func clearChangesOnlyTheSelectedDatabaseAndKeepsTheSourceSnapshot() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let sample = makeSample(at: now.timeIntervalSinceReferenceDate - 120)
        let bytes = try legacyArchive([sample])
        let sourceURL = fixture.container.appendingPathComponent("synthetic-clear-source.jsonl")
        try bytes.write(to: sourceURL)
        let store = try StorageTestFactory.migrateStoppedLegacyFile(at: sourceURL, to: fixture.store, authorization: .stopped)

        try await store.clear()
        #expect(try await store.load(now: now).samples.isEmpty)
        #expect(try Data(contentsOf: sourceURL) == bytes)
        #expect(try Data(contentsOf: fixture.store.appendingPathComponent(RouteStoreFiles.snapshotName)) == bytes)
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now).samples.isEmpty)
        await reopened.close()
    }

    @Test func migrationRejectsEarlierCorruptionDuplicateAndNonincreasingRecords() throws {
        let cases: [[RouteSample]] = [
            [makeSample(at: 1_999_000_000), makeSample(at: 1_998_000_000)],
            [makeSample(at: 1_999_000_000), makeSample(at: 1_999_000_000, id: UUID(), recordingID: UUID())]
        ]

        for samples in cases {
            let fixture = try makeFixture()
            defer { removeFixture(fixture.container) }
            let sourceURL = fixture.container.appendingPathComponent("synthetic-invalid-source.jsonl")
            try legacyArchive(samples).write(to: sourceURL)
            expectStoreError(.corruptSource) {
                _ = try StorageTestFactory.migrateStoppedLegacyFile(at: sourceURL, to: fixture.store, authorization: .stopped)
            }
        }

        let corruptFixture = try makeFixture()
        defer { removeFixture(corruptFixture.container) }
        let valid = makeSample(at: 1_999_000_000)
        var corruptBytes = try legacyArchive([valid])
        corruptBytes.append(Data("{\"broken\":}\n".utf8))
        corruptBytes.append(Data("{\"partial\":".utf8))
        try corruptBytes.write(to: corruptFixture.container.appendingPathComponent("synthetic-earlier-corruption.jsonl"))
        let sourceURL = corruptFixture.container.appendingPathComponent("synthetic-earlier-corruption.jsonl")
        expectStoreError(.corruptSource) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(at: sourceURL, to: corruptFixture.store, authorization: .stopped)
        }
    }

    @Test func migrationRejectsLegacySourceAboveThe64MiBLimitWithoutChangingIt() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let sourceURL = fixture.container.appendingPathComponent("synthetic-oversized-source.jsonl")
        try Data().write(to: sourceURL)
        let source = try FileHandle(forWritingTo: sourceURL)
        let oversizedLength = UInt64(RouteStoreFiles.maximumLegacySourceBytes + 1)
        try source.truncate(atOffset: oversizedLength)
        try source.close()

        expectStoreError(.sourceTooLarge) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(at: sourceURL, to: fixture.store, authorization: .stopped)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: sourceURL.path)
        #expect((attributes[.size] as? NSNumber)?.int64Value == Int64(oversizedLength))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.path))
    }

    @Test func manifestPublicationIsTheOnlyMigrationCutoverPoint() async throws {
        let beforeFixture = try makeFixture()
        defer { removeFixture(beforeFixture.container) }
        let sourceURL = beforeFixture.container.appendingPathComponent("synthetic-before-cutover.jsonl")
        try legacyArchive([makeSample(at: 1_999_000_000)]).write(to: sourceURL)
        let failBeforePublish = storageTestSeams(fault: { point in
            if point == .beforeManifestPublish {
                throw RouteStoreError.injectedFault(point)
            }
        })

        expectStoreError(.injectedFault(.beforeManifestPublish)) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: sourceURL,
                to: beforeFixture.store,
                authorization: .stopped,
                seams: failBeforePublish
            )
        }
        #expect(!FileManager.default.fileExists(atPath: beforeFixture.store.appendingPathComponent(RouteStoreFiles.manifestName).path))
        expectStoreError(.manifestMissing) {
            _ = try StorageTestFactory.openExisting(at: beforeFixture.store)
        }
        expectStoreError(.destinationExists) {
            _ = try StorageTestFactory.createNew(at: beforeFixture.store)
        }

        let afterFixture = try makeFixture()
        defer { removeFixture(afterFixture.container) }
        let afterSourceURL = afterFixture.container.appendingPathComponent("synthetic-after-cutover.jsonl")
        let sample = makeSample(at: 1_999_000_000)
        try legacyArchive([sample]).write(to: afterSourceURL)
        let failAfterPublish = storageTestSeams(fault: { point in
            if point == .afterManifestPublish {
                throw RouteStoreError.injectedFault(point)
            }
        })

        expectStoreError(.injectedFault(.afterManifestPublish)) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: afterSourceURL,
                to: afterFixture.store,
                authorization: .stopped,
                seams: failAfterPublish
            )
        }
        #expect(FileManager.default.fileExists(atPath: afterFixture.store.appendingPathComponent(RouteStoreFiles.manifestName).path))
        let reopened = try StorageTestFactory.openExisting(at: afterFixture.store)
        #expect(RouteStoreFiles.exactSamplesEquality(try await reopened.load(now: Date(timeIntervalSinceReferenceDate: 2_000_000_000)).samples, [sample]))
        await reopened.close()
    }

    @Test func sourceChangesImmediatelyBeforeManifestPublicationAbortMigration() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let sourceURL = fixture.container.appendingPathComponent("synthetic-changing-source.jsonl")
        try legacyArchive([makeSample(at: 1_999_000_000)]).write(to: sourceURL)
        let replacement = Data("synthetic source changed before cutover".utf8)
        let mutateBeforePublish = storageTestSeams(fault: { point in
            if point == .beforeManifestPublish {
                try replacement.write(to: sourceURL, options: .atomic)
            }
        })

        expectStoreError(.sourceChanged) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: sourceURL,
                to: fixture.store,
                authorization: .stopped,
                seams: mutateBeforePublish
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.store.appendingPathComponent(RouteStoreFiles.manifestName).path))
    }

    @Test func rootInodeReplacementBeforeManifestPublicationFailsClosedAndPreservesOriginals() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let sourceURL = fixture.container.appendingPathComponent("synthetic-root-replacement-source.jsonl")
        let sourceBytes = try legacyArchive([makeSample(at: 1_999_000_000)])
        try sourceBytes.write(to: sourceURL)
        let preservedRoot = fixture.container.appendingPathComponent("preserved-synthetic-store", isDirectory: true)
        let replaceRoot = storageTestSeams(fault: { point in
            guard point == .beforeManifestPublish else {
                return
            }
            try FileManager.default.moveItem(at: fixture.store, to: preservedRoot)
            try FileManager.default.createDirectory(
                at: fixture.store,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        })

        expectStoreError(.unsafePath) {
            _ = try StorageTestFactory.migrateStoppedLegacyFile(
                at: sourceURL,
                to: fixture.store,
                authorization: .stopped,
                seams: replaceRoot
            )
        }
        #expect(FileManager.default.fileExists(atPath: preservedRoot.appendingPathComponent(RouteStoreFiles.databaseName).path))
        #expect(FileManager.default.fileExists(atPath: preservedRoot.appendingPathComponent(RouteStoreFiles.snapshotName).path))
        #expect(!FileManager.default.fileExists(atPath: preservedRoot.appendingPathComponent(RouteStoreFiles.manifestName).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.appendingPathComponent(RouteStoreFiles.manifestName).path))
        #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    }

    @Test func openExistingRejectsTamperedManifestAndSchemaWithoutFallback() async throws {
        let manifestFixture = try makeFixture()
        defer { removeFixture(manifestFixture.container) }
        let manifestStore = try StorageTestFactory.createNew(at: manifestFixture.store)
        await manifestStore.close()

        let manifestURL = manifestFixture.store.appendingPathComponent(RouteStoreFiles.manifestName)
        // Deliberately tamper only this synthetic fixture, then reseal it. Atomic
        // writing/backup metadata cannot assume an existing read-only file is writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        try Data("{".utf8).write(to: manifestURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: manifestURL.path
        )
        var manifestMutableURL = manifestURL
        var backupValues = URLResourceValues()
        backupValues.isExcludedFromBackup = true
        try manifestMutableURL.setResourceValues(backupValues)
        try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: manifestURL.path)
        expectStoreError(.invalidManifest) {
            _ = try StorageTestFactory.openExisting(at: manifestFixture.store)
        }

        let schemaFixture = try makeFixture()
        defer { removeFixture(schemaFixture.container) }
        let schemaStore = try StorageTestFactory.createNew(at: schemaFixture.store)
        await schemaStore.close()
        let databaseURL = schemaFixture.store.appendingPathComponent(RouteStoreFiles.databaseName)
        var database: OpaquePointer?
        let opened = databaseURL.path.withCString { sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil) }
        #expect(opened == SQLITE_OK)
        guard opened == SQLITE_OK, let database else {
            Issue.record("Could not open the synthetic database for schema tampering")
            return
        }
        let dropped = sqlite3_exec(database, "DROP INDEX route_samples_fingerprint", nil, nil, nil)
        #expect(dropped == SQLITE_OK)
        #expect(sqlite3_close_v2(database) == SQLITE_OK)
        expectStoreError(.unsupportedSchema) {
            _ = try StorageTestFactory.openExisting(at: schemaFixture.store)
        }
    }

    @Test func stoppedMigrationAuthorizationIsPersistedAndValidatedAgainstDatabaseMetadata() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let sourceURL = fixture.container.appendingPathComponent("synthetic-migration-authorization.jsonl")
        try legacyArchive([makeSample(at: 1_999_000_000)]).write(to: sourceURL)
        let store = try StorageTestFactory.migrateStoppedLegacyFile(
            at: sourceURL,
            to: fixture.store,
            authorization: .stopped
        )
        let manifestURL = fixture.store.appendingPathComponent(RouteStoreFiles.manifestName)
        let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any]
        #expect(manifest?["migrationAuthorization"] as? String == "stopped")
        await store.close()

        let databaseURL = fixture.store.appendingPathComponent(RouteStoreFiles.databaseName)
        var database: OpaquePointer?
        let opened = databaseURL.path.withCString { sqlite3_open_v2($0, &database, SQLITE_OPEN_READWRITE, nil) }
        #expect(opened == SQLITE_OK)
        guard opened == SQLITE_OK, let database else {
            Issue.record("Could not open the synthetic database for authorization tampering")
            return
        }
        let tampered = sqlite3_exec(
            database,
            "UPDATE route_store_metadata SET value='none' WHERE key='migration_authorization'",
            nil,
            nil,
            nil
        )
        #expect(tampered == SQLITE_OK)
        #expect(sqlite3_close_v2(database) == SQLITE_OK)
        expectStoreError(.invalidManifest) {
            _ = try StorageTestFactory.openExisting(at: fixture.store)
        }
    }

    @Test func failedAppendAndRetentionTransactionRollsBackOnReopen() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let originalNow = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let boundary = makeSample(at: originalNow.timeIntervalSinceReferenceDate - 90 * 86_400)
        let initial = try StorageTestFactory.createNew(at: fixture.store)
        #expect(try await initial.append(boundary, now: originalNow) == .stored)
        await initial.close()

        let failCommit = storageTestSeams(fault: { point in
            if point == .beforeTransactionCommit {
                throw RouteStoreError.injectedFault(point)
            }
        })
        let writer = try StorageTestFactory.openExisting(at: fixture.store, seams: failCommit)
        let advancedNow = originalNow.addingTimeInterval(2 * 86_400)
        await expectStoreError(.injectedFault(.beforeTransactionCommit)) {
            _ = try await writer.append(
                makeSample(at: advancedNow.timeIntervalSinceReferenceDate - 1),
                now: advancedNow
            )
        }
        await writer.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(RouteStoreFiles.exactSamplesEquality(try await reopened.load(now: originalNow).samples, [boundary]))
        await reopened.close()
    }

    @Test(arguments: [
        RouteStoreFaultPoint.afterTransactionCommit,
        .beforeTransactionFileSync,
        .beforeTransactionDirectorySync
    ])
    func postCommitFaultRequiresReopenReconciliation(_ point: RouteStoreFaultPoint) async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let initial = try StorageTestFactory.createNew(at: fixture.store)
        await initial.close()
        let failPostCommit = storageTestSeams(fault: { faultPoint in
            if faultPoint == point {
                throw RouteStoreError.injectedFault(faultPoint)
            }
        })
        let writer = try StorageTestFactory.openExisting(at: fixture.store, seams: failPostCommit)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let sample = makeSample(
            at: now.timeIntervalSinceReferenceDate - 60,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")),
            recordingID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        )

        await expectStoreError(.commitOutcomeUncertain) {
            _ = try await writer.append(sample, now: now)
        }
        await expectStoreError(.storeClosed) {
            _ = try await writer.load(now: now)
        }
        await writer.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        let loaded = try await reopened.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [sample]))
        #expect(loaded.samples.map(\.id) == [sample.id])
        await reopened.close()
    }

    @Test func postCommitIdentityFailureIsUncertainAndReconcilesOnReopen() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let initial = try StorageTestFactory.createNew(at: fixture.store)
        await initial.close()
        let lockURL = fixture.store.appendingPathComponent(RouteStoreFiles.lockName)
        let preservedLockURL = fixture.container.appendingPathComponent("preserved-synthetic-post-commit-lock")
        let replaceLockAfterCommit = storageTestSeams(fault: { point in
            guard point == .afterTransactionCommit else {
                return
            }
            try FileManager.default.moveItem(at: lockURL, to: preservedLockURL)
            guard FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data("synthetic replacement lock".utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw RouteStoreError.unsafePath
            }
        })
        let writer = try StorageTestFactory.openExisting(at: fixture.store, seams: replaceLockAfterCommit)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let sample = makeSample(
            at: now.timeIntervalSinceReferenceDate - 60,
            id: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")),
            recordingID: try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000004"))
        )

        await expectStoreError(.commitOutcomeUncertain) {
            _ = try await writer.append(sample, now: now)
        }
        await writer.close()
        try FileManager.default.removeItem(at: lockURL)
        try FileManager.default.moveItem(at: preservedLockURL, to: lockURL)

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        let loaded = try await reopened.load(now: now)
        #expect(RouteStoreFiles.exactSamplesEquality(loaded.samples, [sample]))
        #expect(loaded.samples.map(\.id) == [sample.id])
        await reopened.close()
    }

    @Test func replacedLockIdentityRollsBackAppendAndPreservesTheOriginalLock() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let initial = try StorageTestFactory.createNew(at: fixture.store)
        await initial.close()

        let lockURL = fixture.store.appendingPathComponent(RouteStoreFiles.lockName)
        let preservedLockURL = fixture.container.appendingPathComponent("preserved-synthetic-lock")
        let replaceLockBeforeCommit = storageTestSeams(fault: { point in
            guard point == .beforeTransactionCommit else {
                return
            }
            try FileManager.default.moveItem(at: lockURL, to: preservedLockURL)
            guard FileManager.default.createFile(
                atPath: lockURL.path,
                contents: Data("synthetic replacement lock".utf8),
                attributes: [.posixPermissions: 0o600]
            ) else {
                throw RouteStoreError.unsafePath
            }
        })
        let writer = try StorageTestFactory.openExisting(at: fixture.store, seams: replaceLockBeforeCommit)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)

        await expectStoreError(.unsafePath) {
            _ = try await writer.append(makeSample(at: now.timeIntervalSinceReferenceDate - 60), now: now)
        }
        await writer.close()
        #expect(FileManager.default.fileExists(atPath: preservedLockURL.path))
        #expect(FileManager.default.fileExists(atPath: lockURL.path))

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now).samples.isEmpty)
        await reopened.close()
    }

    @Test func injectedTransactionWriteFailureLeavesNoPartialAppend() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let store = try StorageTestFactory.createNew(at: fixture.store)
        await store.close()
        let failWrite = storageTestSeams(fault: { point in
            if point == .beforeTransactionWrite {
                throw RouteStoreError.injectedFault(point)
            }
        })
        let writer = try StorageTestFactory.openExisting(at: fixture.store, seams: failWrite)
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)

        await expectStoreError(.injectedFault(.beforeTransactionWrite)) {
            _ = try await writer.append(makeSample(at: now.timeIntervalSinceReferenceDate - 60), now: now)
        }
        await writer.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now).samples.isEmpty)
        await reopened.close()
    }

    @Test func diskFullAndProtectionFailuresAreFatalAndDoNotCreatePartialRows() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let seams = storageTestSeams(requireCapacity: { url, bytes, check in
            if check == .append {
                throw RouteStoreError.insufficientSpace
            }
            try RouteStoreFiles.requireCapacity(at: url, requiredBytes: bytes)
        })
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let store = try StorageTestFactory.createNew(at: fixture.store, seams: seams)
        await expectStoreError(.insufficientSpace) {
            _ = try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate - 60), now: now)
        }
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now).samples.isEmpty)
        await reopened.close()

        let protectedFixture = try makeFixture()
        defer { removeFixture(protectedFixture.container) }
        let failProtection = storageTestSeams(protectAndVerify: { _, item in
            if item == .file {
                throw RouteStoreError.protectionFailed
            }
        })
        expectStoreError(.protectionFailed) {
            _ = try StorageTestFactory.createNew(at: protectedFixture.store, seams: failProtection)
        }
    }

    @Test func schemaSidecarProtectionFailureDoesNotPublishAStore() throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let seams = storageTestSeams(protectAndVerify: { url, item in
            try protectForStorageTest(url, as: item)
            if item == .sidecar {
                throw RouteStoreError.protectionFailed
            }
        })

        expectStoreError(.protectionFailed) {
            _ = try StorageTestFactory.createNew(at: fixture.store, seams: seams)
        }
        #expect(!FileManager.default.fileExists(
            atPath: fixture.store.appendingPathComponent(RouteStoreFiles.manifestName).path
        ))
        expectStoreError(.manifestMissing) {
            _ = try StorageTestFactory.openExisting(at: fixture.store)
        }
    }

    @Test func sidecarProtectionFailureRollsBackTheWritingTransaction() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let initial = try StorageTestFactory.createNew(at: fixture.store)
        await initial.close()
        let seams = storageTestSeams(protectAndVerify: { url, item in
            try protectForStorageTest(url, as: item)
            if item == .sidecar {
                throw RouteStoreError.protectionFailed
            }
        })
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let store = try StorageTestFactory.openExisting(at: fixture.store, seams: seams)

        await expectStoreError(.protectionFailed) {
            _ = try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate - 60), now: now)
        }
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        #expect(try await reopened.load(now: now).samples.isEmpty)
        await reopened.close()
    }

    @Test func aSecondWriterAndSymlinkedRootAreRejected() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let store = try StorageTestFactory.createNew(at: fixture.store)
        expectStoreError(.lockUnavailable) {
            _ = try StorageTestFactory.openExisting(at: fixture.store)
        }

        let link = fixture.container.appendingPathComponent("synthetic-store-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.store)
        expectStoreError(.unsafePath) {
            _ = try StorageTestFactory.openExisting(at: link)
        }
        await store.close()
    }

    @Test(.enabled(if: !modelsSimulatorProtection, "Verifies real file protection, not modeled simulator metadata"))
    func protectedStoreFilesAndDirectoriesAreBackupExcluded() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let store = try RouteStore.createNew(at: fixture.store)
        for url in [
            fixture.store,
            fixture.store.appendingPathComponent(RouteStoreFiles.databaseName),
            fixture.store.appendingPathComponent(RouteStoreFiles.manifestName),
            fixture.store.appendingPathComponent(RouteStoreFiles.lockName)
        ] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
            #expect(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
        }
        for suffix in ["-journal", "-wal", "-shm"] {
            let sidecar = URL(fileURLWithPath: fixture.store.appendingPathComponent(RouteStoreFiles.databaseName).path + suffix)
            if FileManager.default.fileExists(atPath: sidecar.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: sidecar.path)
                #expect(attributes[.protectionKey] as? FileProtectionType == .completeUntilFirstUserAuthentication)
                #expect(try sidecar.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
            }
        }
        await store.close()
    }

    @Test func storeAndExportLeaveParentMetadataUnchangedAndProtectExportBeforeWriting() async throws {
        let fixture = try makeFixture()
        defer { removeFixture(fixture.container) }
        let parentAttributes = try FileManager.default.attributesOfItem(atPath: fixture.container.path)
        let parentProtection = parentAttributes[.protectionKey] as? FileProtectionType
        let parentBackupExclusion = try fixture.container.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
        let seams = storageTestSeams(protectAndVerify: { url, item in
            if item == .file && url.lastPathComponent.hasPrefix(".route-export-") {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard (attributes[.size] as? NSNumber)?.intValue == 0 else {
                    throw RouteStoreError.protectionFailed
                }
            }
            try protectForStorageTest(url, as: item)
        })
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let store = try StorageTestFactory.createNew(at: fixture.store, seams: seams)

        var currentParentAttributes = try FileManager.default.attributesOfItem(atPath: fixture.container.path)
        #expect(currentParentAttributes[.protectionKey] as? FileProtectionType == parentProtection)
        #expect(try fixture.container.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == parentBackupExclusion)

        #expect(try await store.append(makeSample(at: now.timeIntervalSinceReferenceDate - 60), now: now) == .stored)
        let destinationURL = fixture.container.appendingPathComponent("synthetic-protected-export.jsonl")
        try await store.exportCompatibleLegacy(to: destinationURL, now: now)
        currentParentAttributes = try FileManager.default.attributesOfItem(atPath: fixture.container.path)
        #expect(currentParentAttributes[.protectionKey] as? FileProtectionType == parentProtection)
        #expect(try fixture.container.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == parentBackupExclusion)
        await store.close()

        let reopened = try StorageTestFactory.openExisting(at: fixture.store)
        currentParentAttributes = try FileManager.default.attributesOfItem(atPath: fixture.container.path)
        #expect(currentParentAttributes[.protectionKey] as? FileProtectionType == parentProtection)
        #expect(try fixture.container.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == parentBackupExclusion)
        await reopened.close()
    }

    @Test func legacyExportRejectsEqualTimeDistinctSamplesAsUnrepresentable() {
        let date = 1_999_000_000.0
        let first = makeSample(at: date, id: UUID(), latitude: 12.3456)
        let second = makeSample(at: date, id: UUID(), latitude: 12.3457)

        #expect(!RouteStoreFiles.legacyRepresentable([first, second]))
        #expect(RouteStoreFiles.legacyRepresentable([first]))
    }
}

// Simulator metadata is explicitly modeled for transaction tests only. Production
// defaults and the two hardware tests still require real protection readback.
#if targetEnvironment(simulator)
private let modelsSimulatorProtection = true
#else
private let modelsSimulatorProtection = false
#endif

private func protectForStorageTest(_ url: URL, as item: RouteStoreProtectedItem) throws {
    #if targetEnvironment(simulator)
    // Keep actual path/permission checks, protection-setting, backup exclusion and
    // backup verification. Substitute only unavailable protection metadata.
    try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in
        .completeUntilFirstUserAuthentication
    })
    #else
    try RouteStoreFiles.protectAndVerify(url, as: item)
    #endif
}

private func storageTestSeams(
    protectAndVerify: @escaping @Sendable (URL, RouteStoreProtectedItem) throws -> Void = {
        try protectForStorageTest($0, as: $1)
    },
    requireCapacity: @escaping @Sendable (URL, Int64, RouteStoreCapacityCheck) throws -> Void = { url, bytes, _ in
        try RouteStoreFiles.requireCapacity(at: url, requiredBytes: bytes)
    },
    fault: @escaping @Sendable (RouteStoreFaultPoint) throws -> Void = { _ in }
) -> RouteStoreSeams {
    RouteStoreSeams(protectAndVerify: protectAndVerify, requireCapacity: requireCapacity, fault: fault)
}

private enum StorageTestFactory {
    static func createNew(at url: URL, seams: RouteStoreSeams = storageTestSeams()) throws -> RouteStore {
        try RouteStore.createNew(at: url, seams: seams)
    }

    static func openExisting(at url: URL, seams: RouteStoreSeams = storageTestSeams()) throws -> RouteStore {
        try RouteStore.openExisting(at: url, seams: seams)
    }

    static func migrateStoppedLegacyFile(
        at source: URL,
        to root: URL,
        authorization: RouteStoreMigrationAuthorization,
        seams: RouteStoreSeams = storageTestSeams()
    ) throws -> RouteStore {
        try RouteStore.migrateStoppedLegacyFile(at: source, to: root, authorization: authorization, seams: seams)
    }
}

private func makeFixture() throws -> (container: URL, store: URL) {
    // Resolve only the trusted OS-provided temporary base. Untrusted store paths
    // must still be rejected, not silently resolved through arbitrary symlinks.
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
        throw RouteStoreError.unsafePath
    }
    defer { Darwin.free(resolved) }
    let container = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("RouteStore-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: container,
        withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700]
    )
    return (container, container.appendingPathComponent("store", isDirectory: true))
}

private func removeFixture(_ container: URL) {
    try? FileManager.default.removeItem(at: container)
}

private func makeSample(
    at referenceSeconds: TimeInterval,
    id: UUID = UUID(),
    recordingID: UUID = UUID(),
    latitude: Double = 12.3456,
    longitude: Double = -45.6789,
    accuracy: Double = 7.5,
    includeOptionalMeasurements: Bool = false,
    stationary: Bool = false
) -> RouteSample {
    RouteSample(
        id: id,
        recordingID: recordingID,
        observedAt: Date(timeIntervalSinceReferenceDate: referenceSeconds),
        latitude: latitude,
        longitude: longitude,
        horizontalAccuracy: accuracy,
        altitude: includeOptionalMeasurements ? 123.25 : nil,
        verticalAccuracy: includeOptionalMeasurements ? 2.75 : nil,
        speed: includeOptionalMeasurements ? 1.125 : nil,
        speedAccuracy: includeOptionalMeasurements ? 0.5 : nil,
        course: includeOptionalMeasurements ? 270.25 : nil,
        courseAccuracy: includeOptionalMeasurements ? 1.75 : nil,
        isStationary: stationary
    )
}

private func legacyArchive(_ samples: [RouteSample]) throws -> Data {
    var data = Data()
    for sample in samples {
        data.append(try JSONEncoder().encode(sample))
        data.append(0x0A)
    }
    return data
}

private func decodedArchive(_ data: Data) throws -> [RouteSample] {
    try data.split(separator: 0x0A, omittingEmptySubsequences: true).map {
        try JSONDecoder().decode(RouteSample.self, from: Data($0))
    }
}

private func expectStoreError(
    _ expected: RouteStoreError,
    operation: () throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    do {
        try operation()
        Issue.record("Expected a typed RouteStoreError", sourceLocation: sourceLocation)
    } catch let error as RouteStoreError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
    }
}

private func expectStoreError(
    _ expected: RouteStoreError,
    operation: () async throws -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    do {
        try await operation()
        Issue.record("Expected a typed RouteStoreError", sourceLocation: sourceLocation)
    } catch let error as RouteStoreError {
        #expect(error == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("Unexpected error type", sourceLocation: sourceLocation)
    }
}
