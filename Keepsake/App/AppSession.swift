import Foundation
import Observation

@MainActor
@Observable
final class AppSession {
    private(set) var phase: SessionPhase = .restoring
    private(set) var auth = AuthScreenState()
    private(set) var group: GroupScreenState = .loading

    @ObservationIgnored private let services: AppServices
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var authRevision = UUID()
    @ObservationIgnored private var groupRevision = UUID()
    @ObservationIgnored private var authEffect: Task<AccountIdentity?, Error>?
    @ObservationIgnored private var groupEffect: Task<SoloGroup?, Error>?
    @ObservationIgnored private var pendingCreation: GroupCreateIntent?
    @ObservationIgnored private var signOutNeedsRetry = false

    init(services: AppServices, now: @escaping @Sendable () -> Date = { .now }) {
        self.services = services
        self.now = now
    }

    func restore() async {
        if signOutNeedsRetry {
            await signOut()
            return
        }
        guard !auth.isWorking else { return }
        phase = .restoring
        let revision = beginAuthRequest()
        let identity = services.identity
        let effect = Task { try await identity.restore() }
        authEffect = effect
        do {
            let account = try await effect.value
            guard revision == authRevision else { return }
            finishAuthRequest()
            if let account {
                await accept(account)
            } else {
                phase = .signedOut
            }
        } catch {
            guard revision == authRevision else { return }
            finishAuthRequest()
            showAuthError(error)
        }
    }

    func sendCode(to rawEmail: String) async {
        guard canAuthenticate else { return }
        guard let email = AuthInput.normalizedEmail(rawEmail) else {
            auth.errorMessage = "Enter a valid email address."
            return
        }
        let revision = beginAuthRequest()
        let identity = services.identity
        let effect = Task<AccountIdentity?, Error> {
            try await identity.sendEmailCode(to: email)
            return nil
        }
        authEffect = effect
        do {
            _ = try await effect.value
            guard revision == authRevision else { return }
            finishAuthRequest()
            auth.step = .code
            auth.email = email
            auth.resendAvailableAt = now().addingTimeInterval(60)
        } catch {
            guard revision == authRevision else { return }
            finishAuthRequest()
            showAuthError(error)
        }
    }

    func verifyCode(_ rawCode: String) async {
        guard canAuthenticate, auth.step == .code else { return }
        guard let code = AuthInput.normalizedCode(rawCode) else {
            auth.errorMessage = "Enter the six-digit code from your email."
            return
        }
        let revision = beginAuthRequest()
        let identity = services.identity
        let email = auth.email
        let effect = Task<AccountIdentity?, Error> {
            try await identity.verifyEmailCode(code, email: email)
        }
        authEffect = effect
        do {
            let account = try await effect.value
            guard revision == authRevision else { return }
            finishAuthRequest()
            guard let account else { throw AppServiceError.invalidResponse }
            await accept(account)
        } catch {
            guard revision == authRevision else { return }
            finishAuthRequest()
            showAuthError(error)
        }
    }

    func resendCode() async {
        guard auth.step == .code,
              auth.resendAvailableAt.map({ now() >= $0 }) ?? true else { return }
        await sendCode(to: auth.email)
    }

    func changeEmail() {
        guard !auth.isWorking else { return }
        authRevision = UUID()
        auth.step = .email
        auth.errorMessage = nil
        auth.resendAvailableAt = nil
    }

    func reloadGroup() async {
        guard case .signedIn(_, let context) = phase else { return }
        let prior = group
        groupEffect?.cancel()
        groupRevision = UUID()
        let revision = groupRevision
        group = pendingCreation.map { .reconciling(name: $0.normalizedName) } ?? .loading
        let groups = services.groups
        let effect = Task { try await groups.loadSoloGroup(for: context) }
        groupEffect = effect
        do {
            let loaded = try await effect.value
            guard isCurrent(context, revision: revision) else { return }
            groupEffect = nil
            if let loaded {
                try showGroup(loaded, context: context)
            } else if let pendingCreation {
                await submitCreation(pendingCreation, context: context)
            } else {
                group = .noGroup
            }
        } catch {
            guard isCurrent(context, revision: revision) else { return }
            groupEffect = nil
            if let pendingCreation {
                group = .reconciling(name: pendingCreation.normalizedName)
            } else if error as? AppServiceError == .offline,
                      case .ready(let confirmed, _) = prior {
                group = .ready(confirmed, offline: true)
            } else {
                group = .failed(message: friendly(error), offline: error as? AppServiceError == .offline)
            }
        }
    }

    func createGroup(named rawName: String) async {
        guard case .signedIn(_, let context) = phase,
              group == .noGroup, pendingCreation == nil else { return }
        guard let name = GroupNameInput.normalize(rawName) else {
            group = .failed(message: "Use a group name of 1–80 characters without control characters.", offline: false)
            return
        }
        let intent = GroupCreateIntent(operationID: UUID(), normalizedName: name)
        pendingCreation = intent
        await submitCreation(intent, context: context)
    }

    func signOut() async {
        guard !signOutNeedsRetry || !auth.isWorking else { return }
        let previousAuth = authEffect
        authRevision = UUID()
        let revision = authRevision
        groupRevision = UUID()
        previousAuth?.cancel()
        groupEffect?.cancel()
        groupEffect = nil
        pendingCreation = nil
        group = .loading
        phase = .signedOut
        auth = AuthScreenState(isWorking: true)
        signOutNeedsRetry = true
        _ = await previousAuth?.result
        guard authRevision == revision else { return }
        do {
            try await services.identity.signOutOnThisDevice()
            guard authRevision == revision else { return }
            signOutNeedsRetry = false
            auth = AuthScreenState()
            authEffect = nil
        } catch {
            guard authRevision == revision else { return }
            auth = AuthScreenState(configurationMessage: "Sign-out could not be verified. Retry to finish signing out before using another account.")
            phase = .configurationUnavailable
        }
    }

    private var canAuthenticate: Bool {
        guard !auth.isWorking, !signOutNeedsRetry else { return false }
        return switch phase {
        case .signedOut, .configurationUnavailable: true
        case .restoring, .signedIn: false
        }
    }

    private func beginAuthRequest() -> UUID {
        authRevision = UUID()
        auth.isWorking = true
        auth.errorMessage = nil
        auth.configurationMessage = nil
        return authRevision
    }

    private func finishAuthRequest() {
        auth.isWorking = false
        authEffect = nil
    }

    private func showAuthError(_ error: any Error) {
        if error as? AppServiceError == .configurationUnavailable {
            auth.configurationMessage = AppServiceError.configurationUnavailable.message
            phase = .configurationUnavailable
        } else {
            auth.errorMessage = friendly(error)
            if phase == .restoring { phase = .signedOut }
        }
    }

    private func accept(_ account: AccountIdentity) async {
        let context = AccountContext(accountID: account.id, generation: UUID())
        auth = AuthScreenState()
        pendingCreation = nil
        phase = .signedIn(account, context)
        await reloadGroup()
    }

    private func submitCreation(_ intent: GroupCreateIntent, context: AccountContext) async {
        groupRevision = UUID()
        let revision = groupRevision
        group = .creating(name: intent.normalizedName)
        let groups = services.groups
        let effect = Task<SoloGroup?, Error> { try await groups.createSoloGroup(intent, for: context) }
        groupEffect = effect
        do {
            guard let created = try await effect.value else { throw AppServiceError.invalidResponse }
            guard isCurrent(context, revision: revision) else { return }
            groupEffect = nil
            try showGroup(created, context: context)
        } catch {
            guard isCurrent(context, revision: revision) else { return }
            groupEffect = nil
            if let error = error as? AppServiceError,
               case .rejected = error {
                pendingCreation = nil
                group = .failed(message: error.message, offline: false)
            } else {
                group = .reconciling(name: intent.normalizedName)
            }
        }
    }

    private func showGroup(_ loaded: SoloGroup, context: AccountContext) throws {
        guard loaded.ownerID == context.accountID,
              GroupNameInput.normalize(loaded.name) == loaded.name else {
            throw AppServiceError.invalidResponse
        }
        pendingCreation = nil
        group = .ready(loaded, offline: false)
    }

    private func isCurrent(_ context: AccountContext, revision: UUID) -> Bool {
        guard case .signedIn(_, let current) = phase else { return false }
        return context == current && groupRevision == revision
    }

    private func friendly(_ error: any Error) -> String {
        (error as? AppServiceError)?.message ?? "Something went wrong. Please try again."
    }
}
