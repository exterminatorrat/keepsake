import CryptoKit
import Foundation
import Darwin
import SQLite3

enum RouteStoreFaultPoint: String, Hashable, Sendable {
    case beforeManifestPublish
    case afterManifestPublish
    case beforeTransactionWrite
    case beforeTransactionCommit
    case afterTransactionCommit
    case beforeTransactionFileSync
    case beforeTransactionDirectorySync
}

enum RouteStoreMigrationAuthorization: String, Codable, Equatable, Sendable {
    case stopped
}

enum RouteStoreError: Error, Equatable, Sendable {
    case destinationExists
    case unsafePath
    case lockUnavailable
    case storeClosed
    case manifestMissing
    case invalidManifest
    case unsupportedSchema
    case corruptDatabase
    case unreadableSource
    case sourceTooLarge
    case corruptSource
    case sourceChanged
    case insufficientSpace
    case protectionFailed
    case backupExclusionFailed
    case writeFailed
    case commitOutcomeUncertain
    case incompatibleLegacyExport
    case injectedFault(RouteStoreFaultPoint)
}

actor RouteStore {
    private let core: RouteStoreCore

    private init(core: sending RouteStoreCore) {
        self.core = core
    }

    static func createNew(at rootURL: URL, seams: RouteStoreSeams = RouteStoreSeams()) throws -> RouteStore {
        RouteStore(core: try RouteStoreCore(rootURL: rootURL, setup: .createNew, seams: seams))
    }

    static func openExisting(at rootURL: URL, seams: RouteStoreSeams = RouteStoreSeams()) throws -> RouteStore {
        RouteStore(core: try RouteStoreCore(rootURL: rootURL, setup: .openExisting, seams: seams))
    }

    static func migrateStoppedLegacyFile(
        at sourceURL: URL,
        to rootURL: URL,
        authorization: RouteStoreMigrationAuthorization,
        seams: RouteStoreSeams = RouteStoreSeams()
    ) throws -> RouteStore {
        RouteStore(core: try RouteStoreCore(
            rootURL: rootURL,
            setup: .migrate(sourceURL: sourceURL, authorization: authorization),
            seams: seams
        ))
    }

    func load(now: Date = .now) throws -> RouteLoadResult {
        try core.load(now: now)
    }

    func append(_ sample: RouteSample, now: Date = .now) throws -> SampleIngestResult {
        try core.append(sample, now: now)
    }

    func clear() throws {
        try core.clear()
    }

    func exportCompatibleLegacy(to destinationURL: URL, now: Date = .now) throws {
        try core.exportCompatibleLegacy(to: destinationURL, now: now)
    }

    func close() {
        core.close()
    }
}

private final class RouteStoreCore {
    private static let schemaVersion: Int32 = 1
    private static let retentionInterval = TimeInterval(90 * 24 * 60 * 60)

    private let rootURL: URL
    private let databaseURL: URL
    private let seams: RouteStoreSeams
    private let resources: RouteStoreResourceCapsule
    private var rootIdentity: RouteStoreFileIdentity?
    private var databaseIdentity: RouteStoreFileIdentity?
    private var lockIdentity: RouteStoreFileIdentity?

    init(rootURL: URL, setup: RouteStoreSetup, seams: RouteStoreSeams) throws {
        let normalizedRootURL = try RouteStoreFiles.validatedRootURL(rootURL)
        self.rootURL = normalizedRootURL
        databaseURL = normalizedRootURL.appendingPathComponent(RouteStoreFiles.databaseName, isDirectory: false)
        self.seams = seams
        resources = RouteStoreResourceCapsule()

        do {
            try initialize(setup)
        } catch {
            releaseResources()
            throw error
        }
    }

    func load(now: Date = .now) throws -> RouteLoadResult {
        try withTransaction {
            let stored = try RouteStoreSQLite.readSamples(try activeDatabase())
            let cutoff = now.addingTimeInterval(-Self.retentionInterval)
            let retained = RouteHistory.retainedSamples(stored, after: cutoff)
            if retained.count != stored.count {
                let requiredBytes = max(65_536, Int64(stored.count - retained.count) * 1_024)
                try seams.requireCapacity(rootURL, requiredBytes, .retention)
                try faultBeforeTransactionWrite()
                try RouteStoreSQLite.deleteExpired(try activeDatabase(), before: cutoff.timeIntervalSinceReferenceDate)
            }
            return RouteLoadResult(samples: retained, recoveredIncompleteTail: false)
        }
    }

    func append(_ sample: RouteSample, now: Date = .now) throws -> SampleIngestResult {
        try withTransaction {
            let database = try activeDatabase()
            let cutoff = now.addingTimeInterval(-Self.retentionInterval)
            let expiredCount = try RouteStoreSQLite.expiredSampleCount(database, before: cutoff.timeIntervalSinceReferenceDate)
            if expiredCount > 0 {
                let (estimatedBytes, overflow) = expiredCount.multipliedReportingOverflow(by: 1_024)
                guard !overflow else {
                    throw RouteStoreError.insufficientSpace
                }
                let requiredBytes = max(65_536, estimatedBytes)
                try seams.requireCapacity(rootURL, requiredBytes, .retention)
                try faultBeforeTransactionWrite()
                try RouteStoreSQLite.deleteExpired(database, before: cutoff.timeIntervalSinceReferenceDate)
            }

            guard sample.isValid,
                  sample.observedAt <= now.addingTimeInterval(60) else {
                return .invalid
            }
            guard sample.observedAt >= cutoff else {
                return .expired
            }
            guard try !RouteStoreSQLite.contains(sample, in: database) else {
                return .duplicate
            }
            if let latest = try RouteStoreSQLite.latestObservation(database),
               sample.observedAt.timeIntervalSinceReferenceDate <= latest {
                return .outOfOrder
            }

            let payload: Data
            do {
                payload = try JSONEncoder().encode(sample)
            } catch {
                throw RouteStoreError.writeFailed
            }
            let (scaled, overflow) = Int64(payload.count).multipliedReportingOverflow(by: 3)
            guard !overflow else {
                throw RouteStoreError.insufficientSpace
            }
            try seams.requireCapacity(rootURL, max(65_536, scaled + 65_536), .append)
            try faultBeforeTransactionWrite()
            try RouteStoreSQLite.insert(sample, payload: payload, into: database)
            return .stored
        }
    }

    func clear() throws {
        try withTransaction {
            let database = try activeDatabase()
            let count = try RouteStoreSQLite.sampleCount(database)
            if count > 0 {
                let (requiredBytes, overflow) = count.multipliedReportingOverflow(by: 1_024)
                guard !overflow else {
                    throw RouteStoreError.insufficientSpace
                }
                try seams.requireCapacity(rootURL, max(65_536, requiredBytes), .clear)
                try faultBeforeTransactionWrite()
                try RouteStoreSQLite.clear(database)
            }
        }
    }

    func exportCompatibleLegacy(to destinationURL: URL, now: Date = .now) throws {
        try RouteStoreFiles.validateNewFileDestination(destinationURL)
        let samples = try load(now: now).samples
        guard RouteStoreFiles.legacyRepresentable(samples) else {
            throw RouteStoreError.incompatibleLegacyExport
        }

        var output = Data()
        do {
            for sample in samples {
                output.append(try JSONEncoder().encode(sample))
                output.append(0x0A)
            }
        } catch {
            throw RouteStoreError.incompatibleLegacyExport
        }
        try RouteStoreFiles.writeCompatibleExport(output, to: destinationURL, seams: seams)
    }

    func close() {
        releaseResources()
    }

    private func initialize(_ setup: RouteStoreSetup) throws {
        switch setup {
        case .createNew:
            try initializeNewStore()
        case .openExisting:
            try initializeExistingStore()
        case let .migrate(sourceURL, authorization):
            guard authorization == .stopped else {
                throw RouteStoreError.unsafePath
            }
            try initializeMigration(sourceURL: sourceURL, authorization: authorization)
        }
    }

    private func initializeNewStore() throws {
        rootIdentity = try RouteStoreFiles.prepareNewRoot(rootURL, seams: seams)
        try captureRootDescriptor()
        resources.lockDescriptor = try RouteStoreFiles.acquireExclusiveLock(at: rootURL, seams: seams)
        try captureLockIdentity()
        let createdDatabaseIdentity = try RouteStoreFiles.createDatabaseFile(at: databaseURL, seams: seams)
        try captureDatabaseIdentity(matches: createdDatabaseIdentity)
        resources.database = try RouteStoreSQLite.open(databaseURL, create: true)
        try validateStoreIdentities()
        try RouteStoreSQLite.configureNew(database: try activeDatabase())
        try createSchema(migrationAuthorization: nil)
        try RouteStoreSQLite.validateDatabase(database: try activeDatabase(), migrationAuthorization: nil)
        try RouteStoreFiles.synchronizeFile(databaseURL)
        try RouteStoreFiles.synchronizeDirectory(rootURL)

        let newManifest = RouteStoreManifest(
            formatVersion: 1,
            schemaVersion: Int(Self.schemaVersion),
            database: RouteStoreFiles.databaseName,
            sourceSnapshot: nil,
            sourceSHA256: nil,
            importedSampleCount: nil,
            migrationAuthorization: nil
        )
        try publish(newManifest)
    }

    private func initializeExistingStore() throws {
        rootIdentity = try RouteStoreFiles.validateExistingRoot(rootURL, seams: seams)
        try captureRootDescriptor()
        resources.lockDescriptor = try RouteStoreFiles.acquireExclusiveLock(at: rootURL, seams: seams)
        try captureLockIdentity()

        let manifestURL = rootURL.appendingPathComponent(RouteStoreFiles.manifestName, isDirectory: false)
        var manifestInfo = stat()
        guard lstat(manifestURL.path, &manifestInfo) == 0 else {
            if errno == ENOENT {
                throw RouteStoreError.manifestMissing
            }
            throw RouteStoreError.invalidManifest
        }
        try seams.protectAndVerify(manifestURL, .file)

        let decodedManifest: RouteStoreManifest
        do {
            decodedManifest = try JSONDecoder().decode(RouteStoreManifest.self, from: RouteStoreFiles.readManifest(at: manifestURL))
        } catch let error as RouteStoreError {
            throw error
        } catch {
            throw RouteStoreError.invalidManifest
        }
        try validateManifest(decodedManifest)

        if let snapshotName = decodedManifest.sourceSnapshot {
            let snapshotURL = rootURL.appendingPathComponent(snapshotName, isDirectory: false)
            try RouteStoreFiles.validateOwnedRegularFile(snapshotURL, requirePrivate: true, requireReadOnly: true)
            try seams.protectAndVerify(snapshotURL, .file)
            let snapshot = try RouteStoreFiles.readStableRegularFile(
                at: snapshotURL,
                maximumBytes: RouteStoreFiles.maximumLegacySourceBytes
            )
            let snapshotSamples = try Self.decodeLegacyArchive(snapshot.data)
            guard Self.sha256(snapshot.data) == decodedManifest.sourceSHA256,
                  decodedManifest.importedSampleCount == snapshotSamples.count else {
                throw RouteStoreError.invalidManifest
            }
        }

        try RouteStoreFiles.validateOwnedRegularFile(databaseURL, requirePrivate: true)
        let expectedDatabaseIdentity = try RouteStoreFiles.captureIdentity(at: databaseURL, directory: false)
        try seams.protectAndVerify(databaseURL, .file)
        try RouteStoreFiles.verifyIdentity(
            at: databaseURL,
            matches: expectedDatabaseIdentity,
            directory: false
        )
        try captureDatabaseIdentity(matches: expectedDatabaseIdentity)
        try protectExistingSidecars()
        try seams.requireCapacity(rootURL, 65_536, .openExisting)
        resources.database = try RouteStoreSQLite.open(databaseURL, create: false)
        try validateStoreIdentities()
        try RouteStoreSQLite.configureExisting(database: try activeDatabase())
        try RouteStoreSQLite.validateDatabase(
            database: try activeDatabase(),
            migrationAuthorization: decodedManifest.migrationAuthorization
        )
        _ = try RouteStoreSQLite.readSamples(try activeDatabase())
        try validateStoreIdentities()
    }

    private func initializeMigration(
        sourceURL: URL,
        authorization: RouteStoreMigrationAuthorization
    ) throws {
        try RouteStoreFiles.validateNewRoot(rootURL)
        let source = try RouteStoreFiles.readStableRegularFile(
            at: sourceURL,
            maximumBytes: RouteStoreFiles.maximumLegacySourceBytes
        )
        let importedSamples = try Self.decodeLegacyArchive(source.data)
        let sourceByteCount = Int64(source.data.count)
        let (scaledSource, sourceOverflow) = sourceByteCount.multipliedReportingOverflow(by: 3)
        let (requiredBytes, additionOverflow) = scaledSource.addingReportingOverflow(1_048_576)
        guard !sourceOverflow, !additionOverflow else {
            throw RouteStoreError.insufficientSpace
        }
        try seams.requireCapacity(rootURL.deletingLastPathComponent(), requiredBytes, .migration)

        rootIdentity = try RouteStoreFiles.prepareNewRoot(rootURL, seams: seams)
        try captureRootDescriptor()
        resources.lockDescriptor = try RouteStoreFiles.acquireExclusiveLock(at: rootURL, seams: seams)
        try captureLockIdentity()

        let snapshotURL = rootURL.appendingPathComponent(RouteStoreFiles.snapshotName, isDirectory: false)
        try RouteStoreFiles.writeNewFile(source.data, at: snapshotURL, readOnly: true, seams: seams)
        let snapshot = try RouteStoreFiles.readStableRegularFile(
            at: snapshotURL,
            maximumBytes: RouteStoreFiles.maximumLegacySourceBytes
        )
        guard snapshot.data == source.data else {
            throw RouteStoreError.writeFailed
        }

        let createdDatabaseIdentity = try RouteStoreFiles.createDatabaseFile(at: databaseURL, seams: seams)
        try captureDatabaseIdentity(matches: createdDatabaseIdentity)
        resources.database = try RouteStoreSQLite.open(databaseURL, create: true)
        try validateStoreIdentities()
        try RouteStoreSQLite.configureNew(database: try activeDatabase())
        try createSchema(migrationAuthorization: authorization)
        try withTransaction {
            let database = try activeDatabase()
            for sample in importedSamples {
                try faultBeforeTransactionWrite()
                let payload: Data
                do {
                    payload = try JSONEncoder().encode(sample)
                } catch {
                    throw RouteStoreError.corruptSource
                }
                try RouteStoreSQLite.insert(sample, payload: payload, into: database)
            }
        }

        let storedSamples = try RouteStoreSQLite.readSamples(try activeDatabase())
        guard RouteStoreFiles.exactSamplesEquality(storedSamples, importedSamples) else {
            throw RouteStoreError.corruptDatabase
        }
        guard snapshot.data == source.data else {
            throw RouteStoreError.sourceChanged
        }
        try RouteStoreFiles.synchronizeFile(databaseURL)
        try RouteStoreFiles.synchronizeFile(snapshotURL)
        try RouteStoreFiles.synchronizeDirectory(rootURL)

        let migratedManifest = RouteStoreManifest(
            formatVersion: 1,
            schemaVersion: Int(Self.schemaVersion),
            database: RouteStoreFiles.databaseName,
            sourceSnapshot: RouteStoreFiles.snapshotName,
            sourceSHA256: Self.sha256(snapshot.data),
            importedSampleCount: importedSamples.count,
            migrationAuthorization: authorization
        )
        try publish(migratedManifest) {
            try RouteStoreFiles.verifyUnchanged(
                source,
                at: sourceURL,
                maximumBytes: RouteStoreFiles.maximumLegacySourceBytes
            )
        }
    }

    private func publish(_ newManifest: RouteStoreManifest, verifySource: () throws -> Void = {}) throws {
        let encoded: Data
        do {
            encoded = try JSONEncoder().encode(newManifest)
        } catch {
            throw RouteStoreError.writeFailed
        }
        try seams.fault(.beforeManifestPublish)
        try verifySource()
        try validateStoreIdentities()
        try RouteStoreFiles.publishManifest(encoded, in: rootURL, seams: seams) {
            try validateStoreIdentities()
        }
        try seams.fault(.afterManifestPublish)
    }

    private func validateManifest(_ manifest: RouteStoreManifest) throws {
        guard manifest.formatVersion == 1,
              manifest.schemaVersion == Int(Self.schemaVersion),
              manifest.database == RouteStoreFiles.databaseName else {
            throw RouteStoreError.invalidManifest
        }

        switch (
            manifest.sourceSnapshot,
            manifest.sourceSHA256,
            manifest.importedSampleCount,
            manifest.migrationAuthorization
        ) {
        case (nil, nil, nil, nil):
            break
        case let (snapshot?, digest?, count?, authorization?) where snapshot == RouteStoreFiles.snapshotName
            && digest.count == 64
            && digest.allSatisfy({ $0.isHexDigit })
            && count >= 0
            && authorization == .stopped:
            break
        default:
            throw RouteStoreError.invalidManifest
        }
    }

    private func protectExistingSidecars() throws {
        for sidecar in try RouteStoreFiles.existingDatabaseSidecars(in: rootURL) {
            try seams.protectAndVerify(sidecar, .sidecar)
        }
    }

    private func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        let database = try activeDatabase()
        do {
            try validateStoreIdentities()
        } catch {
            releaseResources()
            throw error
        }
        try RouteStoreSQLite.execute(database, sql: "BEGIN IMMEDIATE")
        var commitAttempted = false
        var commitSucceeded = false
        do {
            let result = try operation()
            try protectExistingSidecars()
            try seams.fault(.beforeTransactionCommit)
            try validateStoreIdentities()
            commitAttempted = true
            try RouteStoreSQLite.execute(database, sql: "COMMIT")
            commitSucceeded = true
            try seams.fault(.afterTransactionCommit)
            try validateStoreIdentities()
            try seams.fault(.beforeTransactionFileSync)
            try RouteStoreFiles.synchronizeFile(databaseURL)
            try seams.fault(.beforeTransactionDirectorySync)
            try RouteStoreFiles.synchronizeDirectory(rootURL)
            return result
        } catch {
            if commitSucceeded || (commitAttempted && sqlite3_get_autocommit(database) != 0) {
                releaseResources()
                throw RouteStoreError.commitOutcomeUncertain
            }
            if sqlite3_get_autocommit(database) == 0 {
                let rollbackStatus = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                guard rollbackStatus == SQLITE_OK else {
                    releaseResources()
                    throw RouteStoreError.corruptDatabase
                }
            }
            var protectionFailure: RouteStoreError?
            do {
                try validateStoreIdentities()
                try protectExistingSidecars()
            } catch let error as RouteStoreError {
                protectionFailure = error
            } catch {
                protectionFailure = .protectionFailed
            }
            if let protectionFailure {
                if protectionFailure == .unsafePath {
                    releaseResources()
                }
                throw protectionFailure
            }
            if let error = error as? RouteStoreError {
                throw error
            }
            throw RouteStoreError.writeFailed
        }
    }

    private func activeDatabase() throws -> OpaquePointer {
        guard let database = resources.database else {
            throw RouteStoreError.storeClosed
        }
        return database
    }

    private func releaseResources() {
        resources.close()
    }

    private func captureLockIdentity() throws {
        let lockURL = rootURL.appendingPathComponent(RouteStoreFiles.lockName, isDirectory: false)
        lockIdentity = try RouteStoreFiles.captureIdentity(at: lockURL, directory: false)
        guard let lockIdentity else {
            throw RouteStoreError.unsafePath
        }
        try RouteStoreFiles.verifyIdentity(
            at: lockURL,
            matches: lockIdentity,
            directory: false,
            descriptor: resources.lockDescriptor
        )
    }

    private func captureRootDescriptor() throws {
        guard let rootIdentity else {
            throw RouteStoreError.unsafePath
        }
        let (descriptor, _) = try RouteStoreFiles.openIdentityDescriptor(
            at: rootURL,
            directory: true,
            matching: rootIdentity
        )
        resources.rootDescriptor = descriptor
    }

    private func captureDatabaseIdentity(matches expected: RouteStoreFileIdentity? = nil) throws {
        let (descriptor, identity) = try RouteStoreFiles.openIdentityDescriptor(at: databaseURL)
        guard expected == nil || identity == expected else {
            _ = Darwin.close(descriptor)
            throw RouteStoreError.unsafePath
        }
        resources.databaseDescriptor = descriptor
        databaseIdentity = identity
    }

    private func validateStoreIdentities() throws {
        guard let rootIdentity,
              let databaseIdentity,
              let lockIdentity,
              resources.rootDescriptor >= 0,
              resources.databaseDescriptor >= 0,
              resources.lockDescriptor >= 0 else {
            throw RouteStoreError.unsafePath
        }
        try RouteStoreFiles.verifyIdentity(
            at: rootURL,
            matches: rootIdentity,
            directory: true,
            descriptor: resources.rootDescriptor
        )
        try RouteStoreFiles.verifyIdentity(
            at: databaseURL,
            matches: databaseIdentity,
            directory: false,
            descriptor: resources.databaseDescriptor
        )
        let lockURL = rootURL.appendingPathComponent(RouteStoreFiles.lockName, isDirectory: false)
        try RouteStoreFiles.verifyIdentity(
            at: lockURL,
            matches: lockIdentity,
            directory: false,
            descriptor: resources.lockDescriptor
        )
    }

    private func faultBeforeTransactionWrite() throws {
        try seams.fault(.beforeTransactionWrite)
        try validateStoreIdentities()
    }

    private func createSchema(migrationAuthorization: RouteStoreMigrationAuthorization?) throws {
        let database = try activeDatabase()
        try validateStoreIdentities()
        try RouteStoreSQLite.execute(database, sql: "BEGIN EXCLUSIVE")
        do {
            try RouteStoreSQLite.createSchemaContents(
                database: database,
                migrationAuthorization: migrationAuthorization
            )
            try protectExistingSidecars()
            try validateStoreIdentities()
            try RouteStoreSQLite.execute(database, sql: "COMMIT")
            try validateStoreIdentities()
        } catch {
            if sqlite3_get_autocommit(database) == 0 {
                let rollbackStatus = sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                guard rollbackStatus == SQLITE_OK else {
                    releaseResources()
                    throw RouteStoreError.corruptDatabase
                }
            }
            throw error
        }
    }

    private static func decodeLegacyArchive(_ data: Data) throws -> [RouteSample] {
        let hasTrailingNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var samples: [RouteSample] = []
        var ids: Set<UUID> = []
        var fingerprints: Set<RouteSampleFingerprint> = []

        for (index, line) in lines.enumerated() {
            let sample: RouteSample
            do {
                sample = try JSONDecoder().decode(RouteSample.self, from: Data(line))
            } catch {
                if !hasTrailingNewline && index == lines.count - 1 {
                    break
                }
                throw RouteStoreError.corruptSource
            }

            guard sample.isValid,
                  ids.insert(sample.id).inserted,
                  fingerprints.insert(sample.fingerprint).inserted,
                  samples.last.map({ sample.observedAt > $0.observedAt }) ?? true else {
                throw RouteStoreError.corruptSource
            }
            samples.append(sample)
        }
        return samples
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private final class RouteStoreResourceCapsule {
    var database: OpaquePointer?
    var rootDescriptor: Int32 = -1
    var databaseDescriptor: Int32 = -1
    var lockDescriptor: Int32 = -1

    func close() {
        if let database {
            _ = sqlite3_close_v2(database)
            self.database = nil
        }
        if databaseDescriptor >= 0 {
            _ = Darwin.close(databaseDescriptor)
            databaseDescriptor = -1
        }
        if rootDescriptor >= 0 {
            _ = Darwin.close(rootDescriptor)
            rootDescriptor = -1
        }
        if lockDescriptor >= 0 {
            _ = flock(lockDescriptor, LOCK_UN)
            _ = Darwin.close(lockDescriptor)
            lockDescriptor = -1
        }
    }

    deinit {
        close()
    }
}

private enum RouteStoreSetup: Sendable {
    case createNew
    case openExisting
    case migrate(sourceURL: URL, authorization: RouteStoreMigrationAuthorization)
}

private struct RouteStoreManifest: Codable, Sendable {
    let formatVersion: Int
    let schemaVersion: Int
    let database: String
    let sourceSnapshot: String?
    let sourceSHA256: String?
    let importedSampleCount: Int?
    let migrationAuthorization: RouteStoreMigrationAuthorization?
}

private enum RouteStoreSQLite {
    private static let tableSQL = "CREATE TABLE route_samples (sequence INTEGER PRIMARY KEY AUTOINCREMENT, sample_id TEXT NOT NULL UNIQUE, recording_id TEXT NOT NULL, observed_at_reference REAL NOT NULL, latitude REAL NOT NULL, longitude REAL NOT NULL, payload BLOB NOT NULL)"
    private static let fingerprintIndexSQL = "CREATE UNIQUE INDEX route_samples_fingerprint ON route_samples(observed_at_reference, latitude, longitude)"
    private static let recordingIndexSQL = "CREATE INDEX route_samples_recording_order ON route_samples(recording_id, sequence)"
    private static let metadataTableSQL = "CREATE TABLE route_store_metadata (key TEXT PRIMARY KEY NOT NULL, value TEXT NOT NULL) WITHOUT ROWID"

    static func open(_ url: URL, create: Bool) throws -> OpaquePointer {
        var database: OpaquePointer?
        var flags = SQLITE_OPEN_READWRITE
            | SQLITE_OPEN_FULLMUTEX
            | SQLITE_OPEN_FILEPROTECTION_COMPLETEUNTILFIRSTUSERAUTHENTICATION
            | SQLITE_OPEN_NOFOLLOW
        if create {
            flags |= SQLITE_OPEN_CREATE
        }
        let status = url.path.withCString { path in
            sqlite3_open_v2(path, &database, flags, nil)
        }
        guard status == SQLITE_OK, let database else {
            if let database {
                _ = sqlite3_close_v2(database)
            }
            throw map(status)
        }
        _ = sqlite3_busy_timeout(database, 0)
        return database
    }

    static func configureNew(database: OpaquePointer) throws {
        try execute(database, sql: "PRAGMA journal_mode=DELETE")
        guard try stringValue(database, sql: "PRAGMA journal_mode").lowercased() == "delete" else {
            throw RouteStoreError.corruptDatabase
        }
        try execute(database, sql: "PRAGMA synchronous=FULL")
        guard try integerValue(database, sql: "PRAGMA synchronous") == 2 else {
            throw RouteStoreError.corruptDatabase
        }
    }

    static func configureExisting(database: OpaquePointer) throws {
        guard try stringValue(database, sql: "PRAGMA journal_mode").lowercased() == "delete" else {
            throw RouteStoreError.corruptDatabase
        }
        try execute(database, sql: "PRAGMA synchronous=FULL")
        guard try integerValue(database, sql: "PRAGMA synchronous") == 2 else {
            throw RouteStoreError.corruptDatabase
        }
    }

    static func createSchemaContents(
        database: OpaquePointer,
        migrationAuthorization: RouteStoreMigrationAuthorization?
    ) throws {
        try execute(database, sql: tableSQL)
        try execute(database, sql: fingerprintIndexSQL)
        try execute(database, sql: recordingIndexSQL)
        try execute(database, sql: metadataTableSQL)
        try withStatement(
            database,
            sql: "INSERT INTO route_store_metadata (key, value) VALUES ('migration_authorization', ?)"
        ) { statement in
            try bindText(migrationAuthorization?.rawValue ?? "none", at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw map(sqlite3_errcode(database))
            }
        }
        try execute(database, sql: "PRAGMA application_id=1263759793")
        try execute(database, sql: "PRAGMA user_version=1")
    }

    static func validateDatabase(
        database: OpaquePointer,
        migrationAuthorization: RouteStoreMigrationAuthorization?
    ) throws {
        guard try integerValue(database, sql: "PRAGMA application_id") == 1_263_759_793,
              try integerValue(database, sql: "PRAGMA user_version") == 1 else {
            throw RouteStoreError.unsupportedSchema
        }

        let expected: [String: String] = [
            "route_samples": normalize(tableSQL),
            "route_samples_fingerprint": normalize(fingerprintIndexSQL),
            "route_samples_recording_order": normalize(recordingIndexSQL),
            "route_store_metadata": normalize(metadataTableSQL)
        ]
        let actual = try schemaObjects(database)
        guard actual == expected else {
            throw RouteStoreError.unsupportedSchema
        }
        guard try stringValue(
            database,
            sql: "SELECT value FROM route_store_metadata WHERE key = 'migration_authorization'"
        ) == (migrationAuthorization?.rawValue ?? "none") else {
            throw RouteStoreError.invalidManifest
        }

        try withStatement(database, sql: "PRAGMA integrity_check") { statement in
            guard sqlite3_step(statement) == SQLITE_ROW,
                  columnText(statement, 0) == "ok",
                  sqlite3_step(statement) == SQLITE_DONE else {
                throw RouteStoreError.corruptDatabase
            }
        }
    }

    static func readSamples(_ database: OpaquePointer) throws -> [RouteSample] {
        try withStatement(
            database,
            sql: "SELECT sequence, sample_id, recording_id, observed_at_reference, latitude, longitude, payload FROM route_samples ORDER BY sequence"
        ) { statement in
            var samples: [RouteSample] = []
            var ids: Set<UUID> = []
            var fingerprints: Set<RouteSampleFingerprint> = []
            var previousSequence: Int64 = 0

            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    break
                }
                guard status == SQLITE_ROW else {
                    throw map(status)
                }

                let sequence = sqlite3_column_int64(statement, 0)
                let storedID = columnText(statement, 1)
                let storedRecordingID = columnText(statement, 2)
                let storedDate = sqlite3_column_double(statement, 3)
                let storedLatitude = sqlite3_column_double(statement, 4)
                let storedLongitude = sqlite3_column_double(statement, 5)
                let payload = columnData(statement, 6)

                let sample: RouteSample
                do {
                    sample = try JSONDecoder().decode(RouteSample.self, from: payload)
                } catch {
                    throw RouteStoreError.corruptDatabase
                }

                guard sequence > previousSequence,
                      let id = UUID(uuidString: storedID),
                      id.uuidString == storedID,
                      let recordingID = UUID(uuidString: storedRecordingID),
                      recordingID.uuidString == storedRecordingID,
                      sample.isValid,
                      sample.id == id,
                      sample.recordingID == recordingID,
                      sample.observedAt.timeIntervalSinceReferenceDate == storedDate,
                      sample.latitude == storedLatitude,
                      sample.longitude == storedLongitude,
                      ids.insert(id).inserted,
                      fingerprints.insert(sample.fingerprint).inserted,
                      samples.last.map({ sample.observedAt > $0.observedAt }) ?? true else {
                    throw RouteStoreError.corruptDatabase
                }
                previousSequence = sequence
                samples.append(sample)
            }
            return samples
        }
    }

    static func insert(_ sample: RouteSample, payload: Data, into database: OpaquePointer) throws {
        try withStatement(
            database,
            sql: "INSERT INTO route_samples (sample_id, recording_id, observed_at_reference, latitude, longitude, payload) VALUES (?, ?, ?, ?, ?, ?)"
        ) { statement in
            try bindText(sample.id.uuidString, at: 1, to: statement)
            try bindText(sample.recordingID.uuidString, at: 2, to: statement)
            try bindDouble(sample.observedAt.timeIntervalSinceReferenceDate, at: 3, to: statement)
            try bindDouble(sample.latitude, at: 4, to: statement)
            try bindDouble(sample.longitude, at: 5, to: statement)
            try bindData(payload, at: 6, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw map(sqlite3_errcode(database))
            }
        }
    }

    static func deleteExpired(_ database: OpaquePointer, before cutoff: TimeInterval) throws {
        try withStatement(database, sql: "DELETE FROM route_samples WHERE observed_at_reference < ?") { statement in
            try bindDouble(cutoff, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw map(sqlite3_errcode(database))
            }
        }
    }

    static func clear(_ database: OpaquePointer) throws {
        try execute(database, sql: "DELETE FROM route_samples")
    }

    static func sampleCount(_ database: OpaquePointer) throws -> Int64 {
        try integerValue(database, sql: "SELECT count(*) FROM route_samples")
    }

    static func expiredSampleCount(_ database: OpaquePointer, before cutoff: TimeInterval) throws -> Int64 {
        try withStatement(database, sql: "SELECT count(*) FROM route_samples WHERE observed_at_reference < ?") { statement in
            try bindDouble(cutoff, at: 1, to: statement)
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw map(sqlite3_errcode(database))
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    static func contains(_ sample: RouteSample, in database: OpaquePointer) throws -> Bool {
        try withStatement(
            database,
            sql: "SELECT 1 FROM route_samples WHERE sample_id = ? OR (observed_at_reference = ? AND latitude = ? AND longitude = ?) LIMIT 1"
        ) { statement in
            try bindText(sample.id.uuidString, at: 1, to: statement)
            try bindDouble(sample.observedAt.timeIntervalSinceReferenceDate, at: 2, to: statement)
            try bindDouble(sample.latitude, at: 3, to: statement)
            try bindDouble(sample.longitude, at: 4, to: statement)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else {
                throw map(status)
            }
            return status == SQLITE_ROW
        }
    }

    static func latestObservation(_ database: OpaquePointer) throws -> TimeInterval? {
        try withStatement(database, sql: "SELECT observed_at_reference FROM route_samples ORDER BY sequence DESC LIMIT 1") { statement in
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {
                return nil
            }
            guard status == SQLITE_ROW else {
                throw map(status)
            }
            let value = sqlite3_column_double(statement, 0)
            guard value.isFinite else {
                throw RouteStoreError.corruptDatabase
            }
            return value
        }
    }

    static func execute(_ database: OpaquePointer, sql: String) throws {
        let status = sql.withCString { sqlite3_exec(database, $0, nil, nil, nil) }
        guard status == SQLITE_OK else {
            throw map(status)
        }
    }

    private static func schemaObjects(_ database: OpaquePointer) throws -> [String: String] {
        try withStatement(
            database,
            sql: "SELECT name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY name"
        ) { statement in
            var result: [String: String] = [:]
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE {
                    return result
                }
                guard status == SQLITE_ROW else {
                    throw map(status)
                }
                let name = columnText(statement, 0)
                guard let sql = columnOptionalText(statement, 1), result[name] == nil else {
                    throw RouteStoreError.unsupportedSchema
                }
                result[name] = normalize(sql)
            }
        }
    }

    private static func integerValue(_ database: OpaquePointer, sql: String) throws -> Int64 {
        try withStatement(database, sql: sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw RouteStoreError.corruptDatabase
            }
            return sqlite3_column_int64(statement, 0)
        }
    }

    private static func stringValue(_ database: OpaquePointer, sql: String) throws -> String {
        try withStatement(database, sql: sql) { statement in
            guard sqlite3_step(statement) == SQLITE_ROW else {
                throw RouteStoreError.corruptDatabase
            }
            return columnText(statement, 0)
        }
    }

    private static func withStatement<T>(
        _ database: OpaquePointer,
        sql: String,
        operation: (OpaquePointer) throws -> T
    ) throws -> T {
        var statement: OpaquePointer?
        let status = sql.withCString { sqlite3_prepare_v2(database, $0, -1, &statement, nil) }
        guard status == SQLITE_OK, let statement else {
            throw map(status)
        }
        defer { _ = sqlite3_finalize(statement) }
        return try operation(statement)
    }

    private static func bindText(_ value: String, at index: Int32, to statement: OpaquePointer) throws {
        let status = value.withCString { text in
            sqlite3_bind_text(statement, index, text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK else {
            throw map(status)
        }
    }

    private static func bindDouble(_ value: Double, at index: Int32, to statement: OpaquePointer) throws {
        let status = sqlite3_bind_double(statement, index, value)
        guard status == SQLITE_OK else {
            throw map(status)
        }
    }

    private static func bindData(_ value: Data, at index: Int32, to statement: OpaquePointer) throws {
        guard value.count <= Int(Int32.max) else {
            throw RouteStoreError.insufficientSpace
        }
        let status = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(bytes.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        }
        guard status == SQLITE_OK else {
            throw map(status)
        }
    }

    private static func columnText(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let value = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: UnsafeRawPointer(value).assumingMemoryBound(to: CChar.self))
    }

    private static func columnOptionalText(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return columnText(statement, index)
    }

    private static func columnData(_ statement: OpaquePointer, _ index: Int32) -> Data {
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0, let value = sqlite3_column_blob(statement, index) else {
            return Data()
        }
        return Data(bytes: value, count: count)
    }

    private static func normalize(_ sql: String) -> String {
        sql.lowercased().filter { !$0.isWhitespace && $0 != ";" }
    }

    private static func map(_ status: Int32) -> RouteStoreError {
        switch status & 0xFF {
        case SQLITE_FULL:
            return .insufficientSpace
        case SQLITE_CORRUPT, SQLITE_NOTADB:
            return .corruptDatabase
        default:
            return .writeFailed
        }
    }
}
