import Foundation

struct AccountGroupRecord: Codable, Equatable, Sendable {
    let schema: Int
    let accountID: AccountID
    var confirmed: SoloGroup?
    var checkedAt: Date?
    var pending: GroupCreateIntent?

    init(accountID: AccountID) {
        schema = 1
        self.accountID = accountID
    }

    func validate(for account: AccountID) throws {
        guard schema == 1, accountID == account,
              confirmed.map({ $0.ownerID == account && GroupNameInput.normalize($0.name) == $0.name }) ?? true,
              pending.map({ GroupNameInput.normalize($0.normalizedName) == $0.normalizedName }) ?? true,
              (confirmed == nil) == (checkedAt == nil) else {
            throw AppServiceError.localStorage
        }
    }
}

protocol AccountGroupCaching: Sendable {
    func read(for account: AccountID) throws -> AccountGroupRecord
    func write(_ record: AccountGroupRecord) throws
    func invalidate(_ account: AccountID) throws
}

struct AccountGroupCache: AccountGroupCaching {
    let root: URL

    init(namespace: String) throws {
        root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
            .appendingPathComponent("KeepsakeIdentity", isDirectory: true)
            .appendingPathComponent(namespace, isDirectory: true)
    }

    init(root: URL) { self.root = root }

    func read(for account: AccountID) throws -> AccountGroupRecord {
        let url = file(account)
        guard FileManager.default.fileExists(atPath: url.path) else { return AccountGroupRecord(accountID: account) }
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let size = values.fileSize, size <= 16_384 else { throw AppServiceError.localStorage }
            let record = try JSONDecoder().decode(AccountGroupRecord.self, from: Data(contentsOf: url))
            try record.validate(for: account)
            return record
        } catch { throw AppServiceError.localStorage }
    }

    func write(_ record: AccountGroupRecord) throws {
        do {
            try record.validate(for: record.accountID)
            let url = file(record.accountID)
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            let data = try JSONEncoder().encode(record)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forWritingTo: url)
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            var protectedFile = url
            try protectedFile.setResourceValues(values)
            guard try read(for: record.accountID) == record else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }

    func invalidate(_ account: AccountID) throws {
        let url = file(account)
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard !FileManager.default.fileExists(atPath: url.path) else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }

    private func file(_ account: AccountID) -> URL {
        root.appendingPathComponent(account.rawValue.uuidString.lowercased(), isDirectory: true)
            .appendingPathComponent("group.json")
    }
}

struct LocalSignOutLatch: Sendable {
    struct Marker: Codable, Sendable {
        let schema: Int
        let account: AccountID?
    }

    let url: URL

    func read() throws -> Marker? {
        do {
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true, let size = values.fileSize, size <= 1024 else { throw AppServiceError.localStorage }
            let marker = try JSONDecoder().decode(Marker.self, from: Data(contentsOf: url))
            guard marker.schema == 1 else { throw AppServiceError.localStorage }
            return marker
        } catch { throw AppServiceError.localStorage }
    }

    func lock(account: AccountID?) throws {
        if let marker = try read(), marker.account != nil || account == nil { return }
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700, .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication
            ])
            var excluded = directory
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try excluded.setResourceValues(values)
            try JSONEncoder().encode(Marker(schema: 1, account: account)).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.synchronize()
            guard try read() != nil else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }

    func unlock() throws {
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            guard try read() == nil else { throw AppServiceError.localStorage }
        } catch { throw AppServiceError.localStorage }
    }
}
