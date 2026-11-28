import Darwin
import Foundation

struct AccountCaptureStore: Sendable {
    let accountUUID: UUID
    let persistence: RouteStore

    private init(accountUUID: UUID, persistence: RouteStore) {
        self.accountUUID = accountUUID
        self.persistence = persistence
    }

    static func createNew(
        for accountUUID: UUID,
        in applicationSupportURL: URL,
        seams: RouteStoreSeams = RouteStoreSeams()
    ) throws -> AccountCaptureStore {
        try RouteStoreFiles.validateOwnedDirectory(applicationSupportURL, requirePrivate: false)
        var parent = applicationSupportURL
        for component in ["Keepsake", "Accounts"] {
            parent = parent.appendingPathComponent(component, isDirectory: true)
            var info = stat()
            if lstat(parent.path, &info) == 0 {
                try RouteStoreFiles.verifyProtection(at: parent, directory: true, seams: seams)
            } else {
                guard errno == ENOENT else {
                    throw RouteStoreError.unsafePath
                }
                _ = try RouteStoreFiles.prepareNewRoot(parent, seams: seams)
            }
        }
        let accountDirectory = parent.appendingPathComponent(accountUUID.uuidString.lowercased(), isDirectory: true)
        _ = try RouteStoreFiles.prepareNewRoot(accountDirectory, seams: seams)
        let store = try RouteStore.createAccountStore(
            at: accountDirectory.appendingPathComponent("LocalCapture-v3", isDirectory: true),
            ownerAccountUUID: accountUUID,
            seams: seams
        )
        return AccountCaptureStore(accountUUID: accountUUID, persistence: store)
    }

    static func openExisting(
        for accountUUID: UUID,
        in applicationSupportURL: URL,
        seams: RouteStoreSeams = RouteStoreSeams()
    ) throws -> AccountCaptureStore {
        try RouteStoreFiles.validateOwnedDirectory(applicationSupportURL, requirePrivate: false)
        var parent = applicationSupportURL
        for component in ["Keepsake", "Accounts", accountUUID.uuidString.lowercased()] {
            parent = parent.appendingPathComponent(component, isDirectory: true)
            try RouteStoreFiles.verifyProtection(at: parent, directory: true, seams: seams)
        }
        let store = try RouteStore.openAccountStore(
            at: parent.appendingPathComponent("LocalCapture-v3", isDirectory: true),
            ownerAccountUUID: accountUUID,
            seams: seams
        )
        return AccountCaptureStore(accountUUID: accountUUID, persistence: store)
    }

    func close() async {
        await persistence.close()
    }
}
