import Foundation

enum AuthStep: Equatable, Sendable {
    case email, code
}

struct AuthScreenState: Equatable, Sendable {
    var step: AuthStep = .email
    var email = ""
    var isWorking = false
    var errorMessage: String?
    var resendAvailableAt: Date?
    var configurationMessage: String?
}

enum SessionPhase: Equatable, Sendable {
    case restoring
    case signedOut
    case configurationUnavailable
    case signedIn(AccountIdentity, AccountContext)
}

enum GroupScreenState: Equatable, Sendable {
    case loading
    case noGroup
    case creating(name: String)
    case reconciling(name: String)
    case ready(SoloGroup, offline: Bool)
    case failed(message: String, offline: Bool)
}

enum AppTab: String, CaseIterable, Identifiable, Sendable {
    case groups, explore, camera, friends, memories

    var id: Self { self }

    var title: String { rawValue.capitalized }
}

enum GroupPresentation: Equatable, Sendable {
    case groupCollapsed, groupExpanded
    case memberCollapsed, memberExpanded
    case settings, account, groupSummary
}
