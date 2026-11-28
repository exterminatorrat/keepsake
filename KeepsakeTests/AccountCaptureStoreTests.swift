import CryptoKit
import Darwin
import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Keepsake

@Suite(.timeLimit(.minutes(1)))
struct AccountCaptureStoreTests {
    @Test func ownerReopensAndAnotherAccountHasNoHistoryOrIntent() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!
        let other = UUID(uuidString: "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB")!
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let recording = UUID()
        let sample = RouteSample(
            id: UUID(), recordingID: recording, observedAt: now.addingTimeInterval(-1),
            latitude: 1, longitude: 2, horizontalAccuracy: 3, isStationary: false
        )
        let owned = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        #expect(owned.accountUUID == owner)
        #expect(try await owned.persistence.readControl().activeEpoch == nil)
        let begin = try await owned.persistence.beginRecording(
            recordingID: recording, expectedControlRevision: 0, operationID: UUID()
        )
        _ = try await owned.persistence.appendBatch([sample], epoch: begin.epoch, operationID: UUID(), now: now)
        await owned.close()

        let reopened = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        #expect(try await reopened.persistence.readControl().activeEpoch == begin.epoch)
        let page = try await reopened.persistence.readPage(
            interval: CapturePageInterval(start: now.addingTimeInterval(-2), end: now), now: now, limit: 1, cursor: nil
        )
        #expect(page.items.map(\.sample) == [sample])
        #expect(try await reopened.persistence.lookupReceipt(operationID: begin.operationID) == .found(.control(begin)))
        await reopened.close()

        let isolated = try AccountCaptureStore.createNew(for: other, in: support, seams: accountStoreSeams())
        #expect(try await isolated.persistence.readControl().revision == 0)
        #expect(try await isolated.persistence.readPage(
            interval: CapturePageInterval(start: now.addingTimeInterval(-2), end: now), now: now, limit: 1, cursor: nil
        ).items.isEmpty)
        await isolated.close()
        let manifest = try accountManifest(at: accountRoot(support, owner))
        #expect(manifest["ownerAccountUUID"] as? String == owner.uuidString)
        #expect(manifest["schemaVersion"] as? Int == 3)
        #expect(FileManager.default.fileExists(atPath: accountRoot(support, owner).path))
    }

    @Test func missingOpenDoesNotCreateAnyNamespaceOrChooseCreate() throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.unsafePath) {
            _ = try AccountCaptureStore.openExisting(for: UUID(), in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test func foreignAccountDirectoryIsNotRelabeledOrOpened() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let foreign = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        try FileManager.default.moveItem(
            at: accountRoot(support, owner).deletingLastPathComponent(),
            to: accountRoot(support, foreign).deletingLastPathComponent()
        )
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.ownerMismatch) {
            _ = try AccountCaptureStore.openExisting(for: foreign, in: support, seams: accountStoreSeams())
        }
        #expect(throws: RouteStoreError.destinationExists) {
            _ = try AccountCaptureStore.createNew(for: foreign, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test(arguments: ["manifestForeign", "manifestMissing", "databaseForeign", "databaseMissing"])
    func disagreementBetweenOwnerProofsFailsWithoutRepair(change: String) async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let root = accountRoot(support, owner)
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        if change.hasPrefix("manifest") {
            var manifest = try accountManifest(at: root)
            manifest["ownerAccountUUID"] = change == "manifestForeign" ? UUID().uuidString : nil
            try replaceAccountManifest(manifest, at: root)
        } else {
            let sql = change == "databaseForeign"
                ? "UPDATE route_store_metadata SET value = '\(UUID().uuidString.lowercased())' WHERE key = 'owner_account_uuid'"
                : "DELETE FROM route_store_metadata WHERE key = 'owner_account_uuid'"
            try accountSQL(root, sql)
        }
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.ownerMismatch) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test(arguments: ["manifest.json", ".route-store.lock", "route.sqlite"])
    func incompleteStoreOpenCannotRecreateMissingFiles(name: String) async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        try FileManager.default.removeItem(at: accountRoot(support, owner).appendingPathComponent(name))
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.incompleteAccountStore) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test(arguments: ["route.sqlite-journal", "route.sqlite-wal", "route.sqlite-shm", ".manifest-interrupted.pending", "source-snapshot.jsonl"])
    func uncertainOrLegacyFilesArePreservedWithoutRecovery(name: String) async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        try Data("synthetic interrupted state".utf8).write(to: accountRoot(support, owner).appendingPathComponent(name))
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.incompleteAccountStore) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test func abortedCreationCannotBeAdoptedOrRetriedAsNew() throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        #expect(throws: RouteStoreError.injectedFault(.beforeManifestPublish)) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams(fault: { point in
                if point == .beforeManifestPublish { throw RouteStoreError.injectedFault(point) }
            }))
        }
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.incompleteAccountStore) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(throws: RouteStoreError.destinationExists) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test func walHeaderIsRejectedBeforeSQLiteCanCreateSidecars() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let root = accountRoot(support, owner)
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        try accountSQL(root, "PRAGMA journal_mode=WAL")
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: root.path)) == Set([
            RouteStoreFiles.databaseName, RouteStoreFiles.manifestName, RouteStoreFiles.lockName
        ]))
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.corruptDatabase) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test func durablePublishedCreationCanOnlyBeReconciledByExplicitOpen() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        #expect(throws: RouteStoreError.injectedFault(.afterManifestPublish)) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams(fault: { point in
                if point == .afterManifestPublish { throw RouteStoreError.injectedFault(point) }
            }))
        }
        #expect(throws: RouteStoreError.destinationExists) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        }
        let store = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        #expect(try await store.persistence.readControl().revision == 0)
        await store.close()
    }

    @Test func databaseProtectionFailurePrecedesSchemaOrOwnerBytes() throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let defaults = accountStoreSeams()
        let seams = RouteStoreSeams(protectAndVerify: { url, item in
            if url.lastPathComponent == RouteStoreFiles.databaseName {
                #expect(try Data(contentsOf: url).isEmpty)
                throw RouteStoreError.protectionFailed
            }
            try defaults.protectAndVerify(url, item)
        }, readProtection: defaults.readProtection)
        #expect(throws: RouteStoreError.protectionFailed) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: seams)
        }
        #expect(try Data(contentsOf: accountRoot(support, owner).appendingPathComponent(RouteStoreFiles.databaseName)).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: accountRoot(support, owner).appendingPathComponent(RouteStoreFiles.manifestName).path))
    }

    @Test(arguments: ["manifest", "database"])
    func creationRechecksBothOwnerProofsBeforeReturningAHandle(changedProof: String) throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let root = accountRoot(support, owner)
        let seams = accountStoreSeams(fault: { point in
            guard point == .afterManifestPublish else { return }
            if changedProof == "manifest" {
                var manifest = try accountManifest(at: root)
                manifest["ownerAccountUUID"] = UUID().uuidString
                try replaceAccountManifest(manifest, at: root)
            } else {
                try accountSQL(root, "DELETE FROM route_store_metadata WHERE key = 'owner_account_uuid'")
            }
        })
        #expect(throws: RouteStoreError.ownerMismatch) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: seams)
        }
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.ownerMismatch) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(support) == before)
    }

    @Test func postCommitProtectionLossReturnsUncertaintyInsteadOfAnEpoch() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let denyProtection = Mutex(false)
        let defaults = accountStoreSeams()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams(
            fault: { point in
                if point == .afterTransactionCommit { denyProtection.withLock { $0 = true } }
            },
            readProtection: { url in
                if denyProtection.withLock({ $0 }) { return nil }
                return try defaults.readProtection(url)
            }
        ))
        let operationID = UUID()
        await #expect(throws: CapturePersistenceError.outcomeUncertain(operationID)) {
            _ = try await store.persistence.beginRecording(recordingID: UUID(), expectedControlRevision: 0, operationID: operationID)
        }
        await #expect(throws: CapturePersistenceError.unavailable(.storeClosed)) {
            _ = try await store.persistence.readControl()
        }
        await store.close()
        let reopened = try AccountCaptureStore.openExisting(for: owner, in: support, seams: defaults)
        let control = try await reopened.persistence.readControl()
        #expect(control.revision == 1)
        #expect(control.lastControlReceipt?.operationID == operationID)
        await reopened.close()
    }

    @Test func openVerifiesProtectionWithoutRepairingOrPublishingAHandle() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        let before = try accountTree(support)
        let defaults = accountStoreSeams()
        let seams = RouteStoreSeams(
            protectAndVerify: { _, _ in throw RouteStoreError.writeFailed },
            readProtection: { url in
                if url.lastPathComponent == RouteStoreFiles.manifestName { return nil }
                return try defaults.readProtection(url)
            }
        )
        #expect(throws: RouteStoreError.protectionFailed) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: seams)
        }
        #expect(try accountTree(support) == before)
        let reopened = try AccountCaptureStore.openExisting(for: owner, in: support, seams: RouteStoreSeams(
            protectAndVerify: { _, _ in throw RouteStoreError.writeFailed }, readProtection: defaults.readProtection
        ))
        await reopened.close()
    }

    @Test(arguments: ["control", "page", "begin"], [false, true])
    func protectionOrOwnerDriftClosesBeforeReadsAndWrites(operation: String, changeOwner: Bool) async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let denyProtection = Mutex(false)
        let defaults = accountStoreSeams()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams(readProtection: { url in
            if denyProtection.withLock({ $0 }) && url.lastPathComponent == RouteStoreFiles.manifestName { return nil }
            return try defaults.readProtection(url)
        }))
        if changeOwner {
            var manifest = try accountManifest(at: accountRoot(support, owner))
            manifest["ownerAccountUUID"] = UUID().uuidString
            try replaceAccountManifest(manifest, at: accountRoot(support, owner))
        } else {
            denyProtection.withLock { $0 = true }
        }
        let before = try accountTree(support)
        let reason: RouteStoreError = changeOwner ? .ownerMismatch : .protectionFailed
        if operation == "begin" {
            await #expect(throws: CapturePersistenceError.notCommitted(reason)) {
                _ = try await store.persistence.beginRecording(recordingID: UUID(), expectedControlRevision: 0, operationID: UUID())
            }
        } else {
            await #expect(throws: CapturePersistenceError.unavailable(reason)) {
                if operation == "control" {
                    _ = try await store.persistence.readControl()
                } else {
                    let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
                    _ = try await store.persistence.readPage(
                        interval: CapturePageInterval(start: now.addingTimeInterval(-1), end: now), now: now, limit: 1, cursor: nil
                    )
                }
            }
        }
        await #expect(throws: CapturePersistenceError.unavailable(.storeClosed)) {
            _ = try await store.persistence.readControl()
        }
        #expect(try accountTree(support) == before)
        await store.close()
    }

    @Test func databaseOwnerDriftClosesAnAlreadyBoundHandle() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        try accountSQL(accountRoot(support, owner), "DELETE FROM route_store_metadata WHERE key = 'owner_account_uuid'")
        await #expect(throws: CapturePersistenceError.unavailable(.ownerMismatch)) {
            _ = try await store.persistence.readControl()
        }
        await #expect(throws: CapturePersistenceError.unavailable(.storeClosed)) {
            _ = try await store.persistence.readControl()
        }
        await store.close()
    }

    @Test func symlinkedAccountIsRejectedWithoutFollowingIt() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await store.close()
        let account = accountRoot(support, owner).deletingLastPathComponent()
        let target = support.appendingPathComponent("preserved-synthetic-account", isDirectory: true)
        try FileManager.default.moveItem(at: account, to: target)
        try FileManager.default.createSymbolicLink(at: account, withDestinationURL: target)
        let before = try accountTree(target)
        #expect(throws: RouteStoreError.unsafePath) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(throws: RouteStoreError.unsafePath) {
            _ = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        }
        #expect(try accountTree(target) == before)
    }

    @Test(arguments: [false, true])
    func unownedProfilesAndLegacyArchiveCannotBecomeAccountHistory(foundation: Bool) async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let root = accountRoot(support, owner)
        let defaults = accountStoreSeams()
        var parent = support
        for component in ["Keepsake", "Accounts", owner.uuidString.lowercased()] {
            parent = parent.appendingPathComponent(component, isDirectory: true)
            _ = try RouteStoreFiles.prepareNewRoot(parent, seams: defaults)
        }
        let unowned: RouteStore
        if foundation {
            unowned = try RouteStore.createFoundation(at: root, seams: defaults)
        } else {
            unowned = try RouteStore.createNew(at: root, seams: defaults)
        }
        await unowned.close()
        let archive = support.appendingPathComponent("Keepsake/route-history.jsonl")
        try Data("synthetic legacy archive, deliberately invalid".utf8).write(to: archive)
        let before = try accountTree(support)
        #expect(throws: RouteStoreError.invalidManifest) {
            _ = try AccountCaptureStore.openExisting(for: owner, in: support, seams: defaults)
        }
        #expect(try accountTree(support) == before)
        let original: RouteStore
        if foundation {
            original = try RouteStore.openFoundation(at: root, seams: defaults)
        } else {
            original = try RouteStore.openExisting(at: root, seams: defaults)
        }
        await original.close()
    }

    @Test func ownedProfileRejectsLegacyAndUnownedFoundationEntrypoints() async throws {
        let support = try accountStoreFixture()
        defer { try? FileManager.default.removeItem(at: support) }
        let owner = UUID()
        let store = try AccountCaptureStore.createNew(for: owner, in: support, seams: accountStoreSeams())
        await #expect(throws: CapturePersistenceError.notFoundationStore) { _ = try await store.persistence.load() }
        await #expect(throws: CapturePersistenceError.notFoundationStore) { try await store.persistence.clear() }
        await #expect(throws: CapturePersistenceError.notFoundationStore) {
            try await store.persistence.exportCompatibleLegacy(to: support.appendingPathComponent("forbidden.jsonl"))
        }
        await store.close()
        #expect(throws: RouteStoreError.invalidManifest) {
            _ = try RouteStore.openFoundation(at: accountRoot(support, owner), seams: accountStoreSeams())
        }
        #expect(throws: RouteStoreError.invalidManifest) {
            _ = try RouteStore.openExisting(at: accountRoot(support, owner), seams: accountStoreSeams())
        }
        #expect(!FileManager.default.fileExists(atPath: support.appendingPathComponent("forbidden.jsonl").path))
    }
}

private func accountRoot(_ support: URL, _ owner: UUID) -> URL {
    support.appendingPathComponent("Keepsake/Accounts/\(owner.uuidString.lowercased())/LocalCapture-v3", isDirectory: true)
}

private func accountStoreFixture() throws -> URL {
    guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw RouteStoreError.unsafePath }
    defer { Darwin.free(resolved) }
    let support = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        .appendingPathComponent("AccountCapture-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return support
}

private func accountStoreSeams(
    fault: @escaping @Sendable (RouteStoreFaultPoint) throws -> Void = { _ in },
    readProtection: @escaping @Sendable (URL) throws -> FileProtectionType? = { url in
        #if targetEnvironment(simulator)
        return .completeUntilFirstUserAuthentication
        #else
        return try RouteStoreFiles.readProtection(at: url)
        #endif
    }
) -> RouteStoreSeams {
    RouteStoreSeams(protectAndVerify: { url, item in
        #if targetEnvironment(simulator)
        try RouteStoreFiles.protectAndVerify(url, as: item, readProtection: { _ in .completeUntilFirstUserAuthentication })
        #else
        try RouteStoreFiles.protectAndVerify(url, as: item)
        #endif
    }, fault: fault, readProtection: readProtection)
}

private func accountManifest(at root: URL) throws -> [String: Any] {
    let data = try Data(contentsOf: root.appendingPathComponent(RouteStoreFiles.manifestName))
    return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func replaceAccountManifest(_ manifest: [String: Any], at root: URL) throws {
    let url = root.appendingPathComponent(RouteStoreFiles.manifestName)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o400], ofItemAtPath: url.path)
}

private func accountSQL(_ root: URL, _ sql: String) throws {
    var database: OpaquePointer?
    let status = sqlite3_open_v2(root.appendingPathComponent(RouteStoreFiles.databaseName).path, &database, SQLITE_OPEN_READWRITE, nil)
    guard status == SQLITE_OK, let opened = database else {
        if let database { _ = sqlite3_close_v2(database) }
        throw RouteStoreError.writeFailed
    }
    defer { _ = sqlite3_close_v2(opened) }
    guard sqlite3_exec(opened, sql, nil, nil, nil) == SQLITE_OK else { throw RouteStoreError.writeFailed }
}

private struct AccountTreeEntry: Equatable {
    let digest: Data?
    let permissions: Int
    let excludedFromBackup: Bool?
    let protection: String?
}

private func accountTree(_ root: URL) throws -> [String: AccountTreeEntry] {
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isExcludedFromBackupKey]))
    var entries: [String: AccountTreeEntry] = [:]
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isExcludedFromBackupKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let digest: Data?
        if values.isRegularFile == true {
            digest = Data(SHA256.hash(data: try Data(contentsOf: url)))
        } else {
            digest = nil
        }
        entries[String(url.path.dropFirst(root.path.count))] = AccountTreeEntry(
            digest: digest,
            permissions: try #require(attributes[.posixPermissions] as? Int),
            excludedFromBackup: values.isExcludedFromBackup,
            protection: (attributes[.protectionKey] as? FileProtectionType)?.rawValue
        )
    }
    return entries
}
