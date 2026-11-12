import Foundation
import Testing
@testable import Keepsake

@MainActor
struct AppSessionTests {
    @Test(.timeLimit(.minutes(1)))
    func productionCompositionFailsClosedWithoutConstructingARecorder() async {
        let session = AppSession(services: .production)
        await session.restore()
        #expect(session.phase == .configurationUnavailable)
        #expect(session.auth.configurationMessage != nil)
        await session.sendCode(to: "person@example.com")
        #expect(session.phase == .configurationUnavailable)
        #expect(session.auth.step == .email)
    }

    @Test(.timeLimit(.minutes(1)))
    func requestingAnEmailCodeDoesNotAuthenticate() async {
        let identity = ScreenIdentityService(account: nil)
        let session = makeSession(identity: identity)
        await session.restore()
        await session.sendCode(to: "  person@example.com  ")
        #expect(session.phase == .signedOut)
        #expect(session.auth.step == .code)
        #expect(session.auth.email == "person@example.com")
        #expect(await identity.sentEmails == ["person@example.com"])
        await session.resendCode()
        #expect(await identity.sentEmails.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func invalidInputNeverReachesTheIdentityService() async {
        let identity = ScreenIdentityService(account: nil)
        let session = makeSession(identity: identity)
        await session.restore()
        await session.sendCode(to: "not an email")
        #expect(await identity.sentEmails.isEmpty)
        #expect(session.auth.errorMessage != nil)
        await session.sendCode(to: "person@example.com")
        await session.verifyCode("12")
        #expect(await identity.verifyCount == 0)
        #expect(session.phase == .signedOut)
    }

    @Test(.timeLimit(.minutes(1)))
    func restoredAccountWithoutAGroupGetsTheRealEmptyState() async {
        let account = account(1)
        let session = makeSession(identity: ScreenIdentityService(account: account))
        await session.restore()
        guard case .signedIn(let restored, let context) = session.phase else {
            Issue.record("Expected restored identity")
            return
        }
        #expect(restored == account)
        #expect(context.accountID == account.id)
        #expect(session.group == .noGroup)
    }

    @Test(.timeLimit(.minutes(1)))
    func wrongOwnerCannotBePresentedAsTheCurrentGroup() async {
        let groups = ScreenGroupService(group: group(owner: account(2)))
        let session = makeSession(identity: ScreenIdentityService(account: account(1)), groups: groups)
        await session.restore()
        #expect(session.group == .failed(message: AppServiceError.invalidResponse.message, offline: false))
    }

    @Test(.timeLimit(.minutes(1)))
    func uncertainCreationRetriesTheSameOperationAfterCheckingStatus() async {
        let groups = ScreenGroupService(group: nil, failFirstCreate: true)
        let session = makeSession(identity: ScreenIdentityService(account: account(1)), groups: groups)
        await session.restore()
        await session.createGroup(named: "  My group  ")
        #expect(session.group == .reconciling(name: "My group"))
        await session.createGroup(named: "Another group")
        #expect(await groups.operations.count == 1)
        await session.reloadGroup()
        let operations = await groups.operations
        #expect(operations.count == 2)
        #expect(operations.first == operations.last)
        guard case .ready(let created, false) = session.group else {
            Issue.record("Expected confirmed group")
            return
        }
        #expect(created.name == "My group")
        #expect(created.ownerID == account(1).id)
    }

    @Test(.timeLimit(.minutes(1)))
    func staleGroupCompletionAfterSignOutCannotRestoreAccountContent() async {
        let identity = ScreenIdentityService(account: account(1))
        let groups = ScreenGroupService(group: nil, suspendLoad: true)
        let session = makeSession(identity: identity, groups: groups)
        let restore = Task { await session.restore() }
        await groups.waitForLoad()
        await session.signOut()
        await groups.releaseLoad(group(owner: account(1)))
        await restore.value
        #expect(session.phase == .signedOut)
        #expect(session.group == .loading)
    }

    @Test(.timeLimit(.minutes(1)))
    func accountSwitchDropsTheOldAccountsLateGroupResult() async {
        let identity = ScreenIdentityService(account: account(1))
        let groups = ScreenGroupService(group: nil, suspendLoad: true)
        let session = makeSession(identity: identity, groups: groups)
        let firstRestore = Task { await session.restore() }
        await groups.waitForLoad()
        await session.signOut()
        await identity.setRestoredAccount(account(2))
        await session.restore()
        let secondPhase = session.phase
        await groups.releaseLoad(group(owner: account(1)))
        await firstRestore.value
        #expect(session.phase == secondPhase)
        #expect(session.group == .noGroup)
        guard case .signedIn(let current, _) = session.phase else {
            Issue.record("Expected the second account")
            return
        }
        #expect(current.id == account(2).id)
    }

    @Test(.timeLimit(.minutes(1)))
    func unconfirmedSignOutBlocksRestorationAndAnotherSignIn() async {
        let identity = ScreenIdentityService(account: account(1), signOutFails: true)
        let session = makeSession(identity: identity)
        await session.restore()
        await session.signOut()
        #expect(session.phase == .configurationUnavailable)
        await session.sendCode(to: "another@example.com")
        #expect(await identity.sentEmails.isEmpty)
        await session.restore()
        #expect(session.phase == .configurationUnavailable)
        #expect(await identity.signOutCount == 2)
        await identity.allowSignOut()
        await session.restore()
        #expect(session.phase == .signedOut)
        #expect(await identity.storedAccount == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func signOutJoinsLateVerificationBeforeClearingIdentity() async {
        let identity = ScreenIdentityService(account: nil, suspendVerification: true)
        let session = makeSession(identity: identity)
        await session.restore()
        await session.sendCode(to: "person@example.com")
        let verify = Task { await session.verifyCode("123456") }
        await identity.waitForVerification()
        let release = Task { await identity.releaseVerification(account(1)) }
        await session.signOut()
        await release.value
        await verify.value
        #expect(session.phase == .signedOut)
        #expect(await identity.signOutCount == 1)
        #expect(await identity.storedAccount == nil)
        #expect(session.group == .loading)
    }

    @Test(.timeLimit(.minutes(1)))
    func offlineRefreshRetainsOnlyTheConfirmedCurrentAccountGroup() async {
        let ownGroup = group(owner: account(1))
        let groups = ScreenGroupService(group: ownGroup)
        let session = makeSession(identity: ScreenIdentityService(account: account(1)), groups: groups)
        await session.restore()
        await groups.goOffline()
        await session.reloadGroup()
        #expect(session.group == .ready(ownGroup, offline: true))
    }

    @Test(.timeLimit(.minutes(1)))
    func groupNameValidationUsesNormalizedUnicodeScalars() {
        #expect(GroupNameInput.normalize(" Cafe\u{301} ") == "Café")
        #expect(GroupNameInput.normalize("   ") == nil)
        #expect(GroupNameInput.normalize("\t") == nil)
        #expect(GroupNameInput.normalize("\u{00A0}") == nil)
        #expect(GroupNameInput.normalize("Family 👨‍👩‍👧") != nil)
        #expect(GroupNameInput.normalize(String(repeating: "a", count: 80)) != nil)
        #expect(GroupNameInput.normalize(String(repeating: "a", count: 81)) == nil)
    }

    private func makeSession(identity: ScreenIdentityService, groups: ScreenGroupService = ScreenGroupService(group: nil)) -> AppSession {
        AppSession(services: AppServices(identity: identity, groups: groups), now: { Date(timeIntervalSince1970: 100) })
    }

    private func account(_ suffix: Int) -> AccountIdentity {
        AccountIdentity(id: AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(suffix)")!), email: "person\(suffix)@example.com")
    }

    private func group(owner: AccountIdentity) -> SoloGroup {
        SoloGroup(id: GroupID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000010")!), ownerID: owner.id, name: "My group", createdAt: Date(timeIntervalSince1970: 100))
    }
}

private actor ScreenIdentityService: IdentityService {
    private(set) var storedAccount: AccountIdentity?
    private(set) var sentEmails: [String] = []
    private(set) var verifyCount = 0
    private(set) var signOutCount = 0
    private let suspendVerification: Bool
    private var signOutFails: Bool
    private var verification: CheckedContinuation<AccountIdentity, Never>?
    private var verificationWaiter: CheckedContinuation<Void, Never>?

    init(account: AccountIdentity?, suspendVerification: Bool = false, signOutFails: Bool = false) {
        storedAccount = account
        self.suspendVerification = suspendVerification
        self.signOutFails = signOutFails
    }

    func restore() async throws -> AccountIdentity? { storedAccount }
    func sendEmailCode(to email: String) async throws { sentEmails.append(email) }

    func verifyEmailCode(_ code: String, email: String) async throws -> AccountIdentity {
        verifyCount += 1
        if suspendVerification {
            let account = await withCheckedContinuation { continuation in
                verification = continuation
                verificationWaiter?.resume()
                verificationWaiter = nil
            }
            storedAccount = account
            return account
        }
        throw AppServiceError.invalidCode
    }

    func signOutOnThisDevice() async throws {
        signOutCount += 1
        if signOutFails { throw AppServiceError.offline }
        storedAccount = nil
    }

    func setRestoredAccount(_ account: AccountIdentity?) { storedAccount = account }

    func allowSignOut() { signOutFails = false }

    func waitForVerification() async {
        if verification != nil { return }
        await withCheckedContinuation { verificationWaiter = $0 }
    }

    func releaseVerification(_ account: AccountIdentity) {
        verification?.resume(returning: account)
        verification = nil
    }
}

private actor ScreenGroupService: GroupService {
    private var group: SoloGroup?
    private var failFirstCreate: Bool
    private var suspendLoad: Bool
    private var offline = false
    private var load: CheckedContinuation<SoloGroup?, Never>?
    private var loadWaiter: CheckedContinuation<Void, Never>?
    private(set) var operations: [GroupCreateIntent] = []

    init(group: SoloGroup?, failFirstCreate: Bool = false, suspendLoad: Bool = false) {
        self.group = group
        self.failFirstCreate = failFirstCreate
        self.suspendLoad = suspendLoad
    }

    func loadSoloGroup(for context: AccountContext) async throws -> SoloGroup? {
        if offline { throw AppServiceError.offline }
        if suspendLoad {
            suspendLoad = false
            return await withCheckedContinuation { continuation in
                load = continuation
                loadWaiter?.resume()
                loadWaiter = nil
            }
        }
        return group
    }

    func createSoloGroup(_ intent: GroupCreateIntent, for context: AccountContext) async throws -> SoloGroup {
        operations.append(intent)
        if failFirstCreate {
            failFirstCreate = false
            throw AppServiceError.outcomeUncertain
        }
        let created = SoloGroup(id: GroupID(rawValue: UUID()), ownerID: context.accountID, name: intent.normalizedName, createdAt: Date(timeIntervalSince1970: 100))
        group = created
        return created
    }

    func waitForLoad() async {
        if load != nil { return }
        await withCheckedContinuation { loadWaiter = $0 }
    }

    func releaseLoad(_ group: SoloGroup?) {
        load?.resume(returning: group)
        load = nil
    }

    func goOffline() { offline = true }
}
