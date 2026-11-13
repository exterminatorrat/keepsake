import SwiftUI

@MainActor
struct AuthOnboardingView: View {
    let step: AuthOnboardingStep
    var showsOffState = false
    var invitationName: String? = nil
    let onBack: () -> Void
    let onContinue: () -> Void
    @State private var name = ""
    @State private var showsPhotoNotice = false

    init(
        step: AuthOnboardingStep,
        showsOffState: Bool = false,
        invitationName: String? = nil,
        initialName: String = "",
        onBack: @escaping () -> Void,
        onContinue: @escaping () -> Void
    ) {
        self.step = step
        self.showsOffState = showsOffState
        self.invitationName = invitationName
        self.onBack = onBack
        self.onContinue = onContinue
        _name = State(initialValue: initialName)
    }

    var body: some View {
        Group {
            if step == .completion {
                completion
            } else {
                AuthPageScaffold(onBack: onBack, topSpacing: step == .profile ? 64 : 32) {
                    switch step {
                    case .profile: profile
                    case .location, .notifications: permissionExplanation
                    case .completion: EmptyView()
                    }
                } footer: {
                    footer
                }
            }
        }
        .tint(KeepsakeStyle.accent)
        .alert("Photo selection unavailable", isPresented: $showsPhotoNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No photo picker is enabled in this build. This profile draft is local presentation only and is not saved to an account.")
        }
    }

    private var profile: some View {
        VStack(spacing: 28) {
            AuthHeading(title: "Set up your profile", subtitle: "Add a name and photo so your friends can recognize you.", centered: true)
            Button { showsPhotoNotice = true } label: {
                Image(systemName: "person.fill")
                    .font(.system(size: 52, weight: .light))
                    .foregroundStyle(AuthBoardStyle.muted)
                    .frame(width: 132, height: 132)
                    .background(AuthBoardStyle.field, in: Circle())
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "camera.fill")
                            .font(.body)
                            .foregroundStyle(AuthBoardStyle.ink)
                            .frame(width: 44, height: 44)
                            .background(AuthBoardStyle.canvas, in: Circle())
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Profile photo, unavailable in this build")
            TextField("Your name", text: $name)
                .textContentType(.name)
                .textInputAutocapitalization(.words)
                .font(.body)
                .padding(16)
                .frame(minHeight: 54)
                .background(AuthBoardStyle.field, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Profile name draft")
            Text("Preview only. Your name and photo are not saved to a server.")
                .font(.footnote)
                .foregroundStyle(AuthBoardStyle.muted)
                .multilineTextAlignment(.center)
        }
    }

    private var permissionExplanation: some View {
        VStack(spacing: 28) {
            Image(systemName: step == .location ? "location" : "bell")
                .font(.system(size: showsOffState ? 32 : 40, weight: .light))
                .foregroundStyle(KeepsakeStyle.accent)
                .frame(width: showsOffState ? 76 : 116, height: showsOffState ? 76 : 116)
                .background(KeepsakeStyle.accent.opacity(0.06), in: RoundedRectangle(cornerRadius: showsOffState ? 22 : 40))
                .frame(height: !showsOffState && step == .location ? 200 : nil)
                .accessibilityHidden(true)

            AuthHeading(title: permissionTitle, subtitle: permissionSubtitle, centered: true)

            if !showsOffState {
                VStack(spacing: 24) {
                    if step == .location {
                        feature("Precise location", symbol: "location", detail: "Not requested or shared in this build.")
                        feature("Background updates", symbol: "infinity", detail: "Not enabled. Keepsake does not track you in the background.")
                    } else {
                        feature("Group activity", symbol: "person.2", detail: "Group alerts are not enabled.")
                        feature("New moments", symbol: "photo", detail: "Memory notifications are not enabled.")
                        feature("Trip updates", symbol: "suitcase", detail: "Trip notifications are not enabled.")
                    }
                }
                .padding(.top, 8)
            }
        }
        .padding(.top, showsOffState ? 28 : 0)
    }

    private var permissionTitle: String {
        if step == .location {
            return showsOffState ? "Location access is off" : "Share your location"
        }
        return showsOffState ? "Notifications are off" : "Turn on notifications"
    }

    private var permissionSubtitle: String {
        if showsOffState {
            return "Preview of an off state. No device authorization was checked, and Settings access is not enabled here."
        }
        return step == .location
            ? "Location sharing is not enabled in this build. You can skip this step without granting access."
            : "Notifications are not enabled in this build. Continue without an OS permission prompt."
    }

    private func feature(_ title: String, symbol: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(KeepsakeStyle.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(AuthBoardStyle.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var footer: some View {
        switch step {
        case .profile:
            AuthBoardButton(title: "Continue", isEnabled: !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, action: onContinue)
        case .location:
            VStack(spacing: 4) {
                AuthBoardButton(title: showsOffState ? "Open Settings unavailable" : "Continue", isEnabled: !showsOffState, action: onContinue)
                Button("Not Now", action: onContinue)
                    .font(.footnote)
                    .frame(minHeight: 44)
            }
        case .notifications:
            VStack(spacing: 4) {
                AuthBoardButton(title: showsOffState ? "Open Settings unavailable" : "Allow Notifications unavailable", isEnabled: false) {}
                Button("Not Now", action: onContinue)
                    .font(.footnote)
                    .frame(minHeight: 44)
            }
        case .completion:
            EmptyView()
        }
    }

    private var completion: some View {
        ZStack {
            AuthArtworkPlaceholder()
                .ignoresSafeArea()
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 22) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 60, weight: .ultraLight))
                            .accessibilityHidden(true)
                        AuthHeading(
                            title: invitationName == nil ? "You’re all set" : "You’re in!",
                            subtitle: invitationName == nil ? "Welcome to Keepsake. This is a completion preview; no account or group was created." : "Invitation preview only. No group was joined.",
                            centered: true
                        )
                        if let invitationName {
                            HStack(spacing: 14) {
                                Image(systemName: "person.2")
                                    .frame(width: 48, height: 48)
                                    .background(AuthBoardStyle.field, in: RoundedRectangle(cornerRadius: 12))
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(invitationName).font(.subheadline.weight(.semibold))
                                    Text("Sample invitation").font(.footnote).foregroundStyle(AuthBoardStyle.muted)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(16)
                            .background(.white, in: RoundedRectangle(cornerRadius: 16))
                        }
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 76)
                    .padding(.bottom, 40)
                    .frame(maxWidth: 480)
                    .frame(maxWidth: .infinity)
                    .background {
                        LinearGradient(colors: [AuthBoardStyle.canvas, AuthBoardStyle.canvas.opacity(0.95), AuthBoardStyle.canvas.opacity(0.95)], startPoint: .top, endPoint: .bottom)
                    }
                }
                AuthBoardButton(title: invitationName == nil ? "Go to Groups" : "Go to Group", action: onContinue)
                    .padding(20)
                    .background {
                        UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                            .fill(AuthBoardStyle.canvas)
                            .ignoresSafeArea(edges: .bottom)
                    }
            }
        }
        .foregroundStyle(AuthBoardStyle.ink)
    }
}
