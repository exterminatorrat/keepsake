import Foundation

enum AuthEntryProvider: String, CaseIterable, Sendable {
    case apple, phone, email

    var supportsEmailOTP: Bool { self == .email }
}

struct AuthPresentationNavigation: Equatable, Sendable {
    enum Screen: Equatable, Sendable {
        case welcome, entry, verification
    }

    private(set) var screen: Screen

    init(state: AuthScreenState, startsAtWelcome: Bool) {
        screen = state.step == .code ? .verification : (startsAtWelcome ? .welcome : .entry)
    }

    @discardableResult
    mutating func choose(_ provider: AuthEntryProvider) -> Bool {
        guard provider.supportsEmailOTP else { return false }
        screen = .entry
        return true
    }

    mutating func sync(with state: AuthScreenState) {
        if state.step == .code {
            screen = .verification
        } else if screen == .verification {
            screen = .entry
        }
    }

    mutating func goBack() {
        screen = screen == .verification ? .entry : .welcome
    }
}

enum AuthCodeInput {
    static func editingValue(_ raw: String) -> String {
        guard raw.utf8.count <= 4_096 else { return "" }
        return String(raw.filter { $0.isASCII && $0 >= "0" && $0 <= "9" }.prefix(6))
    }
}

enum AuthOnboardingStep: CaseIterable, Equatable, Sendable {
    case profile, location, notifications, completion

    var following: Self? {
        switch self {
        case .profile: .location
        case .location: .notifications
        case .notifications: .completion
        case .completion: nil
        }
    }
}
