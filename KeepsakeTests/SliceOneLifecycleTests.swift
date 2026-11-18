import Foundation
import Testing
@testable import Keepsake

@MainActor
struct SliceOneLifecycleTests {
    @Test func sameAccountRefreshPreservesLifetimeAndConfirmedGroup() async {
        let identity = LifecycleIdentity(account: sliceAccount(1))
        let groups = LifecycleGroups(loaded: sliceGroup(1))
        let session = AppSession(services: AppServices(identity: identity, groups: groups))
        await session.restore()
        let phase = session.phase
        await session.restore()
        #expect(session.phase == phase)
        #expect(session.group == .ready(sliceGroup(1), offline: false))
    }

    @Test func accountReplacementFencesOldRequestWithoutSignOut() async {
        let identity = LifecycleIdentity(account: sliceAccount(1))
        let gate = SliceGate<SoloGroup?>()
        let groups = LifecycleGroups(loaded: nil, loadGate: gate)
        let session = AppSession(services: AppServices(identity: identity, groups: groups))
        let old = Task { await session.restore() }
        await gate.waitUntilEntered()
        await identity.replace(with: sliceAccount(2))
        await session.restore()
        let phase = session.phase
        await gate.release(sliceGroup(1))
        await old.value
        #expect(session.phase == phase)
        #expect(session.group == .noGroup)
        guard case .signedIn(let account, _) = session.phase else { Issue.record("Missing replacement"); return }
        #expect(account.id == sliceAccount(2).id)
    }

    @Test func pendingIntentSurvivesRelaunchAndReplaysOnlyAfterRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        let identity = LifecycleIdentity(account: sliceAccount(1))
        let groups = LifecycleGroups(loaded: nil, uncertain: true)
        let services = AppServices(identity: identity, groups: groups, cache: cache)
        let first = AppSession(services: services)
        await first.restore()
        await first.createGroup(named: " Café ")
        let journal = try cache.read(for: sliceAccount(1).id)
        let intent = try #require(journal.pending)
        #expect(intent.normalizedName == "Café")
        let second = AppSession(services: services)
        await second.restore()
        #expect(await groups.operations == [intent, intent])
        #expect(await groups.calls == ["read", "create", "read", "create"])
        await second.createGroup(named: "Different")
        #expect(await groups.operations.count == 2)
        #expect(try cache.read(for: sliceAccount(1).id).pending == intent)
    }

    @Test func lostSuccessIsReconciledWithoutSecondCreate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        var record = AccountGroupRecord(accountID: sliceAccount(1).id)
        record.pending = GroupCreateIntent(operationID: UUID(), normalizedName: "Old request")
        try cache.write(record)
        let groups = LifecycleGroups(loaded: sliceGroup(1))
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: cache))
        await session.restore()
        #expect(await groups.operations.isEmpty)
        #expect(try cache.read(for: sliceAccount(1).id).pending == nil)
        #expect(session.group == .ready(sliceGroup(1), offline: false))
    }

    @Test func failedJournalWriteNeverDispatchesCreate() async {
        let groups = LifecycleGroups(loaded: nil)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: DeniedJournalCache()))
        await session.restore()
        await session.createGroup(named: "Group")
        #expect(await groups.operations.isEmpty)
        #expect(session.group != .noGroup)
    }

    @Test func corruptCacheCannotBeBypassedByReloadOrCreate() async {
        let groups = LifecycleGroups(loaded: nil)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: CorruptCache()))
        await session.restore()
        await session.reloadGroup()
        await session.createGroup(named: "Group")
        #expect(await groups.calls.isEmpty)
        #expect(session.group == .failed(message: AppServiceError.localStorage.message, offline: false))
    }

    @Test func offlineRelaunchShowsOnlyOwnedConfirmedSnapshotWithTimestamp() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        var record = AccountGroupRecord(accountID: sliceAccount(1).id)
        record.confirmed = sliceGroup(1)
        record.checkedAt = Date(timeIntervalSince1970: 42)
        try cache.write(record)
        let groups = LifecycleGroups(loaded: nil, offline: true)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: cache))
        await session.restore()
        #expect(session.group == .ready(sliceGroup(1), offline: true))
        #expect(session.lastCheckedAt == record.checkedAt)
        await session.createGroup(named: "Offline write")
        #expect(await groups.operations.isEmpty)
        let other = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(2)), groups: groups, cache: cache))
        await other.restore()
        guard case .failed(_, true) = other.group else { Issue.record("No cross-account snapshot allowed"); return }
    }

    @Test func signOutInvalidatesOnlyCurrentAccountsJournalAndSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        var other = AccountGroupRecord(accountID: sliceAccount(2).id)
        other.pending = GroupCreateIntent(operationID: UUID(), normalizedName: "Other")
        try cache.write(other)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: LifecycleGroups(loaded: sliceGroup(1)), cache: cache))
        await session.restore()
        await session.signOut()
        #expect(session.phase == .signedOut)
        #expect(try cache.read(for: sliceAccount(1).id).confirmed == nil)
        #expect(try cache.read(for: sliceAccount(2).id) == other)
    }

    @Test func definiteRejectionReleasesJournalOnlyAfterDurableClear() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        let groups = LifecycleGroups(loaded: nil, rejected: true)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: cache))
        await session.restore()
        await session.createGroup(named: "Group")
        #expect(try cache.read(for: sliceAccount(1).id).pending == nil)
        await session.reloadGroup()
        #expect(session.group == .noGroup)
    }

    @Test func concurrentWinnerIsReloadedWithoutClaimingNewName() async {
        let groups = LifecycleGroups(loaded: nil, competingWinner: true)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups))
        await session.restore()
        await session.createGroup(named: "Not saved")
        #expect(session.group == .ready(sliceGroup(1), offline: false))
        #expect(session.localNotice == AppServiceError.groupExists.message)
        #expect(await groups.operations.count == 1)
    }

    @Test func unchangedShellHasExactlyFiveTabsAndOnlyRealSelf() {
        #expect(AppTab.allCases == [.groups, .explore, .camera, .friends, .memories])
        let member = GroupMemberPresentation.selfMember(account: sliceAccount(2))
        #expect(member.id == sliceAccount(2).id)
    }

    @Test func oldSameAccountRevisionCannotOverwriteNewSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = AccountGroupCache(root: root)
        let groups = LifecycleGroups(loaded: sliceGroup(1))
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups, cache: cache))
        await session.restore()
        let gate = SliceGate<SoloGroup?>()
        await groups.setLoadGate(gate)
        let old = Task { await session.reloadGroup() }
        await gate.waitUntilEntered()
        let newer = SoloGroup(id: sliceGroup(1).id, ownerID: sliceAccount(1).id, name: "Newer", createdAt: sliceGroup(1).createdAt)
        await groups.setLoaded(newer)
        await session.reloadGroup()
        await gate.release(sliceGroup(1))
        await old.value
        #expect(session.group == .ready(newer, offline: false))
        #expect(try cache.read(for: sliceAccount(1).id).confirmed == newer)
    }

    @Test func cancelledInitialViewTaskDoesNotPreventLaterRestoration() async {
        let gate = SliceGate<SoloGroup?>()
        let groups = LifecycleGroups(loaded: sliceGroup(1), loadGate: gate)
        let session = AppSession(services: AppServices(identity: LifecycleIdentity(account: sliceAccount(1)), groups: groups))
        let viewTask = Task { await session.run() }
        await gate.waitUntilEntered()
        viewTask.cancel()
        await gate.release(sliceGroup(1))
        await viewTask.value
        #expect(session.group == .loading)
        await session.restore()
        #expect(session.group == .ready(sliceGroup(1), offline: false))
        #expect(await groups.calls == ["read", "read"])
    }
}

private func sliceAccount(_ value: Int) -> AccountIdentity {
    AccountIdentity(id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(value)")!), email: "test\(value)@example.invalid")
}

private func sliceGroup(_ value: Int) -> SoloGroup {
    SoloGroup(id: GroupID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!), ownerID: sliceAccount(value).id, name: "Confirmed", createdAt: Date(timeIntervalSince1970: 1))
}

private actor LifecycleIdentity: IdentityService {
    var account: AccountIdentity?
    init(account: AccountIdentity?) { self.account = account }
    func restore() async throws -> AccountIdentity? { account }
    func sendEmailCode(to email: String) async throws {}
    func verifyEmailCode(_ code: String, email: String) async throws -> AccountIdentity { throw AppServiceError.invalidCode }
    func signOutOnThisDevice() async throws { account = nil }
    func replace(with account: AccountIdentity?) { self.account = account }
}

private actor LifecycleGroups: GroupService {
    var loaded: SoloGroup?
    var loadGate: SliceGate<SoloGroup?>?
    let uncertain: Bool
    let offline: Bool
    let rejected: Bool
    let competingWinner: Bool
    private(set) var operations: [GroupCreateIntent] = []
    private(set) var calls: [String] = []
    init(loaded: SoloGroup?, loadGate: SliceGate<SoloGroup?>? = nil, uncertain: Bool = false, offline: Bool = false, rejected: Bool = false, competingWinner: Bool = false) {
        self.loaded = loaded
        self.loadGate = loadGate
        self.uncertain = uncertain
        self.offline = offline
        self.rejected = rejected
        self.competingWinner = competingWinner
    }
    func loadSoloGroup(for context: AccountContext) async throws -> SoloGroup? {
        calls.append("read")
        if let gate = loadGate { loadGate = nil; return await gate.enter() }
        if offline { throw AppServiceError.offline }
        return loaded
    }
    func createSoloGroup(_ intent: GroupCreateIntent, for context: AccountContext) async throws -> SoloGroup {
        calls.append("create")
        operations.append(intent)
        if uncertain { throw AppServiceError.outcomeUncertain }
        if rejected { throw AppServiceError.rejected("Invalid name") }
        if competingWinner { loaded = sliceGroup(1); throw AppServiceError.groupExists }
        return sliceGroup(1)
    }
    func setLoadGate(_ gate: SliceGate<SoloGroup?>) { loadGate = gate }
    func setLoaded(_ group: SoloGroup?) { loaded = group }
}

actor SliceGate<Value: Sendable> {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    private var operation: CheckedContinuation<Value, Never>?
    func enter() async -> Value {
        await withCheckedContinuation {
            operation = $0
            entered = true
            waiter?.resume()
            waiter = nil
        }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func release(_ value: Value) { operation?.resume(returning: value); operation = nil }
}

private struct DeniedJournalCache: AccountGroupCaching {
    func read(for account: AccountID) throws -> AccountGroupRecord { AccountGroupRecord(accountID: account) }
    func write(_ record: AccountGroupRecord) throws {
        if record.pending != nil { throw AppServiceError.localStorage }
    }
    func invalidate(_ account: AccountID) throws {}
}

private struct CorruptCache: AccountGroupCaching {
    func read(for account: AccountID) throws -> AccountGroupRecord { throw AppServiceError.localStorage }
    func write(_ record: AccountGroupRecord) throws { throw AppServiceError.localStorage }
    func invalidate(_ account: AccountID) throws {}
}
