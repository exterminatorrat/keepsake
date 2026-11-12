import SwiftUI

#if DEBUG
enum AuthReferencePose: String, CaseIterable, Hashable {
    case welcome = "AUTH01"
    case entry = "AUTH02"
    case verification = "AUTH03"
    case profile = "AUTH04"
    case location = "AUTH05"
    case notifications = "AUTH06"
    case completion = "AUTH07"
    case wrongCode = "AUTH-WrongCode"
    case expired = "AUTH-Expired"
    case loading = "AUTH-Loading"
    case locationOff = "AUTH-LocationOff"
    case notificationsOff = "AUTH-NotificationsOff"
    case invitation = "AUTH-Invitation"
    case phoneUnavailable = "AUTH-PhoneUnavailable"
    case configuration = "AUTH-Configuration"
}

@MainActor
struct AuthWorkflowPreview: View {
    @State private var pose: AuthReferencePose
    @State private var recipient = "fixture@example.com"
    @State private var showsCompletionNotice = false
    private let date = Date(timeIntervalSince1970: 100)

    init(pose: AuthReferencePose) {
        _pose = State(initialValue: pose)
    }

    var body: some View {
        Group {
            switch pose {
            case .welcome, .entry, .verification, .wrongCode, .expired, .phoneUnavailable, .configuration:
                AuthScreenView(
                    state: authState,
                    onSendCode: { email in recipient = email; pose = .verification },
                    onVerifyCode: { _ in pose = .profile },
                    onResend: { pose = .verification },
                    onChangeEmail: { pose = .entry },
                    onRetryConfiguration: {},
                    startsAtWelcome: pose == .welcome || pose == .configuration,
                    entryProvider: pose == .phoneUnavailable ? .phone : .email,
                    initialCode: pose == .wrongCode ? "327491" : "",
                    isCodeExpired: pose == .expired,
                    countdownDate: date
                )
                .id(pose)
            case .loading:
                AuthLoadingView(title: "Signing you in…")
            case .profile, .location, .notifications, .completion, .locationOff, .notificationsOff, .invitation:
                AuthOnboardingView(
                    step: onboardingStep,
                    showsOffState: pose == .locationOff || pose == .notificationsOff,
                    invitationName: pose == .invitation ? "Lake Trip" : nil,
                    initialName: "Maya Chen",
                    onBack: goBack,
                    onContinue: advance
                )
                .id(pose)
            }
        }
        .alert("Preview only", isPresented: $showsCompletionNotice) {
            Button("Back to welcome") { pose = .welcome }
        } message: {
            Text("This flow does not sign in, persist a profile, request permissions, or create or join a group.")
        }
    }

    private var authState: AuthScreenState {
        AuthScreenState(
            step: [.verification, .wrongCode, .expired].contains(pose) ? .code : .email,
            email: recipient,
            errorMessage: pose == .wrongCode ? "The code is incorrect. Try again." : nil,
            resendAvailableAt: pose == .verification || pose == .wrongCode ? date.addingTimeInterval(42) : nil,
            configurationMessage: pose == .configuration ? AppServiceError.configurationUnavailable.message : nil
        )
    }

    private var onboardingStep: AuthOnboardingStep {
        switch pose {
        case .profile: .profile
        case .location, .locationOff: .location
        case .notifications, .notificationsOff: .notifications
        default: .completion
        }
    }

    private func advance() {
        switch onboardingStep.following {
        case .profile: pose = .profile
        case .location: pose = .location
        case .notifications: pose = .notifications
        case .completion: pose = .completion
        case nil: showsCompletionNotice = true
        }
    }

    private func goBack() {
        switch pose {
        case .profile: pose = .verification
        case .location, .locationOff: pose = .profile
        case .notifications, .notificationsOff: pose = .location
        default: pose = .welcome
        }
    }
}

#Preview("AUTH01 Welcome") { AuthWorkflowPreview(pose: .welcome) }
#Preview("AUTH02 Email entry") { AuthWorkflowPreview(pose: .entry) }
#Preview("AUTH03 Verification") { AuthWorkflowPreview(pose: .verification) }
#Preview("AUTH04 Profile") { AuthWorkflowPreview(pose: .profile) }
#Preview("AUTH05 Location explanation") { AuthWorkflowPreview(pose: .location) }
#Preview("AUTH06 Notifications explanation") { AuthWorkflowPreview(pose: .notifications) }
#Preview("AUTH07 Completion") { AuthWorkflowPreview(pose: .completion) }
#Preview("Wrong code") { AuthWorkflowPreview(pose: .wrongCode) }
#Preview("Expired code") { AuthWorkflowPreview(pose: .expired) }
#Preview("Loading") { AuthWorkflowPreview(pose: .loading) }
#Preview("Location off - injected") { AuthWorkflowPreview(pose: .locationOff) }
#Preview("Notifications off - injected") { AuthWorkflowPreview(pose: .notificationsOff) }
#Preview("Invitation completion - sample") { AuthWorkflowPreview(pose: .invitation) }
#Preview("Phone unavailable") { AuthWorkflowPreview(pose: .phoneUnavailable) }
#Preview("Configuration unavailable") { AuthWorkflowPreview(pose: .configuration) }
#endif
