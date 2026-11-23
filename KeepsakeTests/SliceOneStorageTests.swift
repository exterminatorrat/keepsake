import Foundation
import Supabase
import Testing
@testable import Keepsake

struct SliceOneStorageTests {
    @Test func configurationRejectsPrivilegedOrMissingKeysAndUnsafeURLs() throws {
        let valid: [String: Any] = ["KeepsakeSupabaseURL": "https://test.example.invalid", "KeepsakeSupabasePublishableKey": "sb_publishable_TEST_ONLY", "KeepsakeEnvironment": "test", "CFBundleIdentifier": "com.example.keepsake.tests"]
        let configuration = try BackendConfiguration(info: valid)
        #expect(configuration.namespace == "com.example.keepsake.tests.test.test.example.invalid")
        for value in ["", "sb_secret_TEST_ONLY", "eyJ.TEST_ONLY", "$(MISSING)"] {
            var info = valid
            info["KeepsakeSupabasePublishableKey"] = value
            #expect(throws: AppServiceError.configurationUnavailable) { try BackendConfiguration(info: info) }
        }
        for value in ["http://test.example.invalid", "https://name:password@test.example.invalid", "https://test.example.invalid?key=value", "https://test.example.invalid/path"] {
            var info = valid
            info["KeepsakeSupabaseURL"] = value
            #expect(throws: AppServiceError.configurationUnavailable) { try BackendConfiguration(info: info) }
        }
    }

    @Test func namespacesChangeWithProjectEnvironmentAndAppIdentity() throws {
        let base: [String: Any] = ["KeepsakeSupabaseURL": "https://one.example.invalid", "KeepsakeSupabasePublishableKey": "sb_publishable_TEST_ONLY", "KeepsakeEnvironment": "test", "CFBundleIdentifier": "com.example.one"]
        let first = try BackendConfiguration(info: base)
        for (key, value) in [("KeepsakeSupabaseURL", "https://two.example.invalid"), ("KeepsakeSupabaseURL", "https://one.example.invalid:9443"), ("KeepsakeEnvironment", "development"), ("CFBundleIdentifier", "com.example.two")] {
            var info = base
            info[key] = value
            #expect(try BackendConfiguration(info: info).namespace != first.namespace)
        }
    }

    @Test func credentialRemovalIsScopedAndMarkerSurvivesFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixtureAuthStorage(root: root)
        for key in AuthCredentialStore.ownedKeys { try storage.store(key: key, value: Data([7])) }
        try storage.store(key: "unrelated", value: Data([9]))
        let credentials = AuthCredentialStore(storage: storage)
        let account = UUID()
        try credentials.lock(accountID: account)
        let failing = AuthCredentialStore(storage: FixtureAuthStorage(root: root, deniesRemoval: true))
        #expect(throws: AppServiceError.localStorage) { try failing.clearCredentials() }
        #expect(try credentials.isLocked())
        #expect(try credentials.lockedAccount()?.rawValue == account)
        try credentials.clearCredentials()
        for key in AuthCredentialStore.ownedKeys { #expect(try storage.retrieve(key: key) == nil) }
        #expect(try storage.retrieve(key: "unrelated") == Data([9]))
        try credentials.unlock()
        #expect(try !credentials.isLocked())
    }

    @Test func credentialReadErrorsNeverMeanSignedOut() {
        let credentials = AuthCredentialStore(storage: UnavailableAuthStorage())
        #expect(throws: AppServiceError.localStorage) { try credentials.isLocked() }
        #expect(throws: AppServiceError.localStorage) { try credentials.storedSession() }
        #expect(throws: AppServiceError.localStorage) { try credentials.lock() }
    }

    @Test func cacheRejectsWrongOwnerSchemaAndCorruptBytes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountID(rawValue: UUID())
        let other = AccountID(rawValue: UUID())
        let cache = AccountGroupCache(root: root)
        var record = AccountGroupRecord(accountID: account)
        record.pending = GroupCreateIntent(operationID: UUID(), normalizedName: "Café")
        try cache.write(record)
        #expect(try cache.read(for: account) == record)
        #expect(throws: AppServiceError.localStorage) { try record.validate(for: other) }
        let file = root.appendingPathComponent(account.rawValue.uuidString.lowercased()).appendingPathComponent("group.json")
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["schema"] = 2
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(throws: AppServiceError.localStorage) { try cache.read(for: account) }
        try Data([0xff]).write(to: file)
        #expect(throws: AppServiceError.localStorage) { try cache.read(for: account) }
    }

    @Test func effectsAreSerializedAcrossSuspensionAndFailure() async throws {
        let queue = SerializedEffects()
        let gate = SliceGate<Void>()
        let log = EffectLog()
        let first: Task<Void, Error> = await queue.submit {
                await log.append(1)
                await gate.enter()
                await log.append(2)
                throw AppServiceError.invalidCode
        }
        await gate.waitUntilEntered()
        let second = await queue.submit { await log.append(3) }
        await gate.release(())
        _ = await first.result
        try await second.value
        #expect(await log.values == [1, 2, 3])
    }

    @Test func diskSignOutLatchSurvivesRelaunchWithoutKeychainAccess() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = AccountID(rawValue: UUID())
        let url = root.appendingPathComponent("signout.json")
        let first = LocalSignOutLatch(url: url)
        try first.lock(account: account)
        let relaunched = LocalSignOutLatch(url: url)
        #expect(try relaunched.read()?.account == account)
        try relaunched.lock(account: AccountID(rawValue: UUID()))
        #expect(try relaunched.read()?.account == account)
        try relaunched.unlock()
        #expect(try first.read() == nil)
    }

    @Test func corruptSignOutLatchFailsClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("signout.json")
        try Data([0xff]).write(to: url)
        #expect(throws: AppServiceError.localStorage) { try LocalSignOutLatch(url: url).read() }
    }

    @Test func malformedCredentialsCanBeRemovedAndRemovalFailureCanBeRetried() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixtureAuthStorage(root: root)
        try storage.store(key: BackendConfiguration.sessionKey, value: Data([0xff]))
        let cache = AccountGroupCache(root: root.appendingPathComponent("cache"))
        let backend = SupabaseBackend(configuration: try fixtureConfiguration(), cache: cache, latch: LocalSignOutLatch(url: cache.root.appendingPathComponent("local-signout.json")), storage: storage, fetch: { _ in throw URLError(.notConnectedToInternet) })
        try backend.prepareForSignOut(account: nil)
        let denial = root.appendingPathComponent("deny-removal")
        try Data([1]).write(to: denial)
        await #expect(throws: AppServiceError.localStorage) { try await backend.signOutOnThisDevice() }
        #expect(try AuthCredentialStore(storage: storage).isLocked())
        try FileManager.default.removeItem(at: denial)
        try await backend.signOutOnThisDevice()
        #expect(try storage.retrieve(key: BackendConfiguration.sessionKey) == nil)
        #expect(try !AuthCredentialStore(storage: storage).isLocked())
        #expect(try LocalSignOutLatch(url: cache.root.appendingPathComponent("local-signout.json")).read() == nil)
    }

    @Test func backendDrainsLateVerificationBeforeRemovingItsCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixtureAuthStorage(root: root)
        let gate = SliceGate<Void>()
        let transport = FixtureBackendTransport(verificationGate: gate)
        let cache = AccountGroupCache(root: root.appendingPathComponent("cache"))
        let backend = SupabaseBackend(configuration: try fixtureConfiguration(), cache: cache, latch: LocalSignOutLatch(url: cache.root.appendingPathComponent("local-signout.json")), storage: storage, fetch: { try await transport.fetch($0) })
        let verify = Task { try await backend.verifyEmailCode("123456", email: "slice@example.invalid") }
        await gate.waitUntilEntered()
        try backend.prepareForSignOut(account: nil)
        let signOut = Task { try await backend.signOutOnThisDevice() }
        await gate.release(())
        _ = await verify.result
        try await signOut.value
        #expect(try storage.retrieve(key: BackendConfiguration.sessionKey) == nil)
        #expect(try await backend.restore() == nil)
        #expect(await transport.paths == ["/auth/v1/verify", "/auth/v1/logout"])
    }

    @MainActor
    @Test func corruptAccountCacheCanBeSignedOutAndSameAccountCanSignInAgain() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixtureAuthStorage(root: root)
        let cache = AccountGroupCache(root: root.appendingPathComponent("cache"))
        let account = AccountID(rawValue: FixtureBackendTransport.accountID)
        let corrupt = cache.root.appendingPathComponent(account.rawValue.uuidString.lowercased()).appendingPathComponent("group.json")
        try FileManager.default.createDirectory(at: corrupt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0xff]).write(to: corrupt)
        let transport = FixtureBackendTransport()
        let backend = SupabaseBackend(configuration: try fixtureConfiguration(), cache: cache, latch: LocalSignOutLatch(url: cache.root.appendingPathComponent("local-signout.json")), storage: storage, fetch: { try await transport.fetch($0) })
        let session = AppSession(services: AppServices(identity: backend, groups: backend, cache: cache))
        await session.restore()
        await session.sendCode(to: "slice@example.invalid")
        await session.verifyCode("123456")
        #expect(session.group == .failed(message: AppServiceError.localStorage.message, offline: false))
        await session.signOut()
        #expect(session.phase == .signedOut)
        #expect(!FileManager.default.fileExists(atPath: corrupt.path))
        await session.sendCode(to: "slice@example.invalid")
        await session.verifyCode("123456")
        #expect(session.group == .noGroup)
    }

    @Test func interruptedCleanupPersistsDiscoveredAccountBeforeRemovingCredentials() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = FixtureAuthStorage(root: root)
        let cache = AccountGroupCache(root: root.appendingPathComponent("cache"))
        let account = AccountID(rawValue: FixtureBackendTransport.accountID)
        var record = AccountGroupRecord(accountID: account)
        record.pending = GroupCreateIntent(operationID: UUID(), normalizedName: "Retained")
        try cache.write(record)
        let denial = root.appendingPathComponent("deny-invalidation")
        let retryCache = RetryInvalidationCache(base: cache, denial: denial)
        let latch = LocalSignOutLatch(url: cache.root.appendingPathComponent("local-signout.json"))
        let transport = FixtureBackendTransport()
        let first = SupabaseBackend(configuration: try fixtureConfiguration(), cache: retryCache, latch: latch, storage: storage, fetch: { try await transport.fetch($0) })
        _ = try await first.verifyEmailCode("123456", email: "slice@example.invalid")
        try first.prepareForSignOut(account: nil)
        try Data([1]).write(to: denial)
        let recovery = SupabaseBackend(configuration: try fixtureConfiguration(), cache: retryCache, latch: latch, storage: storage, fetch: { try await transport.fetch($0) })
        await #expect(throws: AppServiceError.localStorage) { try await recovery.restore() }
        #expect(try storage.retrieve(key: BackendConfiguration.sessionKey) == nil)
        #expect(try latch.read()?.account == account)
        #expect(try AuthCredentialStore(storage: storage).lockedAccount() == account)
        try FileManager.default.removeItem(at: denial)
        let relaunched = SupabaseBackend(configuration: try fixtureConfiguration(), cache: retryCache, latch: latch, storage: storage, fetch: { try await transport.fetch($0) })
        #expect(try await relaunched.restore() == nil)
        #expect(try cache.read(for: account).pending == nil)
        #expect(try latch.read() == nil)
    }
}

private struct RetryInvalidationCache: AccountGroupCaching {
    let base: AccountGroupCache
    let denial: URL
    func read(for account: AccountID) throws -> AccountGroupRecord { try base.read(for: account) }
    func write(_ record: AccountGroupRecord) throws { try base.write(record) }
    func invalidate(_ account: AccountID) throws {
        if FileManager.default.fileExists(atPath: denial.path) { throw AppServiceError.localStorage }
        try base.invalidate(account)
    }
}

private func fixtureConfiguration() throws -> BackendConfiguration {
    try BackendConfiguration(info: ["KeepsakeSupabaseURL": "https://fixture.example.invalid", "KeepsakeSupabasePublishableKey": "sb_publishable_TEST_ONLY", "KeepsakeEnvironment": "test", "CFBundleIdentifier": "com.example.keepsake.tests"])
}

private actor FixtureBackendTransport {
    static let accountID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
    let verificationGate: SliceGate<Void>?
    private(set) var paths: [String] = []
    init(verificationGate: SliceGate<Void>? = nil) { self.verificationGate = verificationGate }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let url = try #require(request.url)
        paths.append(url.path)
        let data: Data
        switch url.path {
        case "/auth/v1/verify":
            if let verificationGate { await verificationGate.enter() }
            data = Data("""
            {"access_token":"fixture-access-not-a-real-token","token_type":"bearer","expires_in":3600,"expires_at":4102444800,"refresh_token":"fixture-refresh-not-a-real-token","user":{"id":"77777777-7777-7777-7777-777777777777","aud":"authenticated","email":"slice@example.invalid","created_at":"2026-01-01T00:00:00Z","updated_at":"2026-01-01T00:00:00Z"}}
            """.utf8)
        case "/auth/v1/otp", "/auth/v1/logout": data = Data("{}".utf8)
        case "/rest/v1/groups": data = Data("[]".utf8)
        default: throw AppServiceError.invalidResponse
        }
        return (data, try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])))
    }
}

private actor EffectLog {
    private(set) var values: [Int] = []
    func append(_ value: Int) { values.append(value) }
}

private struct FixtureAuthStorage: AuthLocalStorage {
    let root: URL
    var deniesRemoval = false
    func store(key: String, value: Data) throws { try value.write(to: root.appendingPathComponent(key), options: .atomic) }
    func retrieve(key: String) throws -> Data? {
        let url = root.appendingPathComponent(key)
        return FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
    }
    func remove(key: String) throws {
        if deniesRemoval || FileManager.default.fileExists(atPath: root.appendingPathComponent("deny-removal").path) { throw AppServiceError.localStorage }
        let url = root.appendingPathComponent(key)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
}

private struct UnavailableAuthStorage: AuthLocalStorage {
    func store(key: String, value: Data) throws { throw AppServiceError.localStorage }
    func retrieve(key: String) throws -> Data? { throw AppServiceError.localStorage }
    func remove(key: String) throws { throw AppServiceError.localStorage }
}
