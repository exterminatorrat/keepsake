import Foundation

enum AppServiceError: Error, Equatable, Sendable {
    case configurationUnavailable
    case offline
    case invalidCode
    case rejected(String)
    case outcomeUncertain
    case invalidResponse

    var message: String {
        switch self {
        case .configurationUnavailable:
            "Real sign-in is not configured for this build. No account or group has been created."
        case .offline:
            "You’re offline. Check your connection and try again."
        case .invalidCode:
            "That code is invalid or has expired. Check it or request a new code."
        case .rejected(let message):
            message
        case .outcomeUncertain:
            "The result could not be confirmed. Check status before trying again."
        case .invalidResponse:
            "Your account data could not be verified. Please try again."
        }
    }
}

protocol IdentityService: Sendable {
    func restore() async throws -> AccountIdentity?
    func sendEmailCode(to email: String) async throws
    func verifyEmailCode(_ code: String, email: String) async throws -> AccountIdentity
    func signOutOnThisDevice() async throws
}

protocol GroupService: Sendable {
    func loadSoloGroup(for context: AccountContext) async throws -> SoloGroup?
    func createSoloGroup(_ intent: GroupCreateIntent, for context: AccountContext) async throws -> SoloGroup
}

struct AppServices: Sendable {
    let identity: any IdentityService
    let groups: any GroupService

    static var production: Self {
        Self(identity: UnconfiguredIdentityService(), groups: UnconfiguredGroupService())
    }
}

private struct UnconfiguredIdentityService: IdentityService {
    func restore() async throws -> AccountIdentity? { throw AppServiceError.configurationUnavailable }
    func sendEmailCode(to email: String) async throws { throw AppServiceError.configurationUnavailable }
    func verifyEmailCode(_ code: String, email: String) async throws -> AccountIdentity {
        throw AppServiceError.configurationUnavailable
    }
    func signOutOnThisDevice() async throws {}
}

private struct UnconfiguredGroupService: GroupService {
    func loadSoloGroup(for context: AccountContext) async throws -> SoloGroup? {
        throw AppServiceError.configurationUnavailable
    }
    func createSoloGroup(_ intent: GroupCreateIntent, for context: AccountContext) async throws -> SoloGroup {
        throw AppServiceError.configurationUnavailable
    }
}
