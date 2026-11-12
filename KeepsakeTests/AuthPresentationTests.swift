import Foundation
import Testing
@testable import Keepsake

struct AuthPresentationTests {
    @Test func welcomeDoesNotAssumeAnAuthenticatedAccount() {
        let state = AuthScreenState(configurationMessage: AppServiceError.configurationUnavailable.message)
        let navigation = AuthPresentationNavigation(state: state, startsAtWelcome: true)
        #expect(navigation.screen == .welcome)
        #expect(state.step == .email)
    }

    @Test(arguments: [AuthEntryProvider.apple, .phone])
    func unavailableProvidersCannotAdvanceTheLiveRouter(provider: AuthEntryProvider) {
        var navigation = AuthPresentationNavigation(state: AuthScreenState(), startsAtWelcome: true)
        #expect(!provider.supportsEmailOTP)
        #expect(!navigation.choose(provider))
        #expect(navigation.screen == .welcome)
    }

    @Test func emailSelectionOnlyOpensEntry() {
        var navigation = AuthPresentationNavigation(state: AuthScreenState(), startsAtWelcome: true)
        #expect(navigation.choose(.email))
        #expect(navigation.screen == .entry)
    }

    @Test func verificationFollowsExternalSessionStateAndBackReturnsToEntry() {
        var navigation = AuthPresentationNavigation(state: AuthScreenState(), startsAtWelcome: true)
        navigation.sync(with: AuthScreenState(step: .code, email: "fixture@example.com"))
        #expect(navigation.screen == .verification)
        navigation.goBack()
        #expect(navigation.screen == .entry)
        navigation.goBack()
        #expect(navigation.screen == .welcome)
    }

    @Test func changingEmailClearsTheVerificationRoute() {
        var navigation = AuthPresentationNavigation(state: AuthScreenState(step: .code), startsAtWelcome: false)
        navigation.sync(with: AuthScreenState())
        #expect(navigation.screen == .entry)
    }

    @Test(arguments: [
        ("123456", "123456"),
        ("123 456\n", "123456"),
        ("123-456", "123456"),
        ("1234567", "123456"),
        ("１２３４５６", ""),
        ("١٢٣٤٥٦", ""),
        ("12a3", "123")
    ])
    func singleInputSupportsCodePasteAndASCIIDigits(raw: String, expected: String) {
        #expect(AuthCodeInput.editingValue(raw) == expected)
    }

    @Test func editingValuePreservesDeletionAndReplacement() {
        #expect(AuthCodeInput.editingValue("12345") == "12345")
        #expect(AuthCodeInput.editingValue("") == "")
        #expect(AuthCodeInput.editingValue("654321") == "654321")
        #expect(AuthCodeInput.editingValue(String(repeating: "1", count: 4_097)) == "")
    }

    @Test func onboardingStepsAreOnlyAPresentationSequence() {
        #expect(AuthOnboardingStep.profile.following == .location)
        #expect(AuthOnboardingStep.location.following == .notifications)
        #expect(AuthOnboardingStep.notifications.following == .completion)
        #expect(AuthOnboardingStep.completion.following == nil)
    }
}
