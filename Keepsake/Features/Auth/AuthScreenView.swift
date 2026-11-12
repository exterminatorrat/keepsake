import Foundation
import SwiftUI

@MainActor
struct AuthScreenView: View {
    let state: AuthScreenState
    let onSendCode: (String) -> Void
    let onVerifyCode: (String) -> Void
    let onResend: () -> Void
    let onChangeEmail: () -> Void
    let onRetryConfiguration: () -> Void
    private let isCodeExpired: Bool
    private let countdownDate: Date?

    @State private var entryProvider: AuthEntryProvider
    @State private var navigation: AuthPresentationNavigation
    @State private var email: String
    @State private var code: String
    @State private var validation: String?
    @State private var showsLegalNotice = false
    @FocusState private var isEmailFocused: Bool

    init(
        state: AuthScreenState,
        onSendCode: @escaping (String) -> Void,
        onVerifyCode: @escaping (String) -> Void,
        onResend: @escaping () -> Void,
        onChangeEmail: @escaping () -> Void,
        onRetryConfiguration: @escaping () -> Void,
        startsAtWelcome: Bool = false,
        entryProvider: AuthEntryProvider = .email,
        initialCode: String = "",
        isCodeExpired: Bool = false,
        countdownDate: Date? = nil
    ) {
        self.state = state
        self.onSendCode = onSendCode
        self.onVerifyCode = onVerifyCode
        self.onResend = onResend
        self.onChangeEmail = onChangeEmail
        self.onRetryConfiguration = onRetryConfiguration
        _entryProvider = State(initialValue: entryProvider)
        self.isCodeExpired = isCodeExpired
        self.countdownDate = countdownDate
        _navigation = State(initialValue: AuthPresentationNavigation(state: state, startsAtWelcome: startsAtWelcome))
        _email = State(initialValue: state.email)
        _code = State(initialValue: AuthCodeInput.editingValue(initialCode))
    }

    var body: some View {
        Group {
            if state.isWorking {
                AuthLoadingView(title: "Please wait…")
            } else if navigation.screen == .welcome {
                welcome
            } else {
                entryOrVerification
            }
        }
        .tint(KeepsakeStyle.accent)
        .onChange(of: state.step) { _, _ in
            navigation.sync(with: state)
            code = ""
            validation = nil
        }
        .onChange(of: state.email) { _, newEmail in
            email = newEmail
            code = ""
        }
        .onChange(of: code) { _, newCode in
            if AuthInput.normalizedCode(newCode) != nil { submitCode() }
        }
        .alert("Legal links unavailable", isPresented: $showsLegalNotice) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Terms of Service and Privacy Policy links have not been configured for this build.")
        }
    }

    private var welcome: some View {
        ZStack {
            AuthArtworkPlaceholder()
                .ignoresSafeArea()
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Keepsake")
                                .font(.largeTitle.weight(.medium))
                                .accessibilityAddTraits(.isHeader)
                            Text("Stay connected to the people and places that matter.")
                                .font(.title3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .foregroundStyle(.white)
                        .frame(maxWidth: 480, alignment: .leading)
                        .padding(.horizontal, 28)
                        .padding(.top, 120)
                        .padding(.bottom, 32)
                        .frame(minHeight: max(0, geometry.size.height - 380), alignment: .bottom)

                        VStack(spacing: 12) {
                            providerButton(.apple, title: "Continue with Apple", symbol: "apple.logo")
                            providerButton(.phone, title: "Continue with Phone", symbol: "phone")
                            providerButton(.email, title: "Continue with Email", symbol: "envelope")
                            if let message = state.configurationMessage {
                                configurationNotice(message)
                            }
                            legalNotice
                        }
                        .frame(maxWidth: 480)
                        .padding(.horizontal, 24)
                        .padding(.top, 22)
                        .padding(.bottom, 16)
                        .frame(maxWidth: .infinity)
                        .background {
                            UnevenRoundedRectangle(topLeadingRadius: 28, topTrailingRadius: 28)
                                .fill(AuthBoardStyle.canvas)
                                .ignoresSafeArea(edges: .bottom)
                        }
                    }
                    .frame(minHeight: geometry.size.height, alignment: .bottom)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private func providerButton(_ provider: AuthEntryProvider, title: String, symbol: String) -> some View {
        VStack(spacing: 3) {
            AuthBoardButton(
                title: title,
                symbol: symbol,
                isEnabled: provider.supportsEmailOTP,
                isPrimary: provider == .apple
            ) {
                if navigation.choose(provider) { entryProvider = provider }
            }
            if !provider.supportsEmailOTP {
                Text(provider == .apple ? "Apple sign-in is not configured" : "Phone sign-in is not configured")
                    .font(.caption2)
                    .foregroundStyle(AuthBoardStyle.muted)
            }
        }
    }

    private var legalNotice: some View {
        VStack(spacing: 0) {
            Text("By continuing, you agree to our")
                .font(.caption)
                .foregroundStyle(AuthBoardStyle.muted)
            HStack(spacing: 4) {
                Button { showsLegalNotice = true } label: {
                    Text("Terms of Service").underline().frame(minHeight: 44)
                }
                Text("and").foregroundStyle(AuthBoardStyle.muted)
                Button { showsLegalNotice = true } label: {
                    Text("Privacy Policy").underline().frame(minHeight: 44)
                }
            }
            .font(.caption)
            .frame(minHeight: 44)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(AuthBoardStyle.ink)
    }

    private var entryOrVerification: some View {
        AuthPageScaffold(onBack: goBack) {
            VStack(alignment: .leading, spacing: 28) {
                AuthHeading(
                    title: navigation.screen == .verification ? "Enter the\nverification code" : (entryProvider == .phone ? "Enter your\nphone number" : "Enter your\nemail address"),
                    subtitle: navigation.screen == .verification ? verificationSubtitle : (entryProvider == .phone ? "Phone sign-in is not configured. Use email instead." : "We’ll send a verification code to confirm it’s you.")
                )
                if navigation.screen == .verification {
                    verificationFields
                } else {
                    entryFields
                }
                if navigation.screen == .entry, let message = validation ?? state.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Input error: \(message)")
                }
                if let message = state.configurationMessage {
                    configurationNotice(message)
                }
            }
        } footer: {
            if navigation.screen == .entry {
                AuthBoardButton(
                    title: entryProvider == .phone ? "Phone sign-in unavailable" : "Continue",
                    isEnabled: entryProvider.supportsEmailOTP && state.configurationMessage == nil,
                    action: submitEmail
                )
            }
        }
        .toolbar {
            if isEmailFocused {
                ToolbarItemGroup(placement: .keyboard) {
                    Button("Done") { isEmailFocused = false }
                    Spacer()
                    Button("Continue", action: submitEmail)
                        .disabled(state.configurationMessage != nil)
                }
            }
        }
    }

    @ViewBuilder
    private var entryFields: some View {
        if entryProvider == .phone {
            HStack(spacing: 12) {
                Text("+1")
                Text("(415) 123-4567")
                    .foregroundStyle(AuthBoardStyle.muted)
                Spacer(minLength: 0)
            }
            .font(.body)
            .padding(16)
            .frame(minHeight: 54)
            .background(AuthBoardStyle.field, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Example phone number. Phone sign-in is unavailable.")
            Text("Phone sign-in is not configured. Email OTP is the only planned supported sign-in method.")
                .font(.footnote)
                .foregroundStyle(AuthBoardStyle.muted)
            Button("Use email instead") {
                entryProvider = .email
                navigation.choose(.email)
                onChangeEmail()
            }
            .frame(minHeight: 44)
        } else {
            TextField("name@example.com", text: $email)
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($isEmailFocused)
                .onSubmit(submitEmail)
                .font(.body)
                .padding(16)
                .frame(minHeight: 54)
                .background(AuthBoardStyle.field, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel("Email address")
                .onAppear { isEmailFocused = state.configurationMessage == nil }
            Text("Email sign-in uses a six-digit code. No password needed.")
                .font(.footnote)
                .foregroundStyle(AuthBoardStyle.muted)
        }
    }

    private var verificationSubtitle: String {
        state.email.isEmpty ? "Enter the six-digit code from your email." : "We sent a six-digit code to\n\(state.email)."
    }

    private var verificationFields: some View {
        VStack(spacing: 14) {
            AuthOTPInput(code: $code, hasError: isCodeExpired || validation != nil || state.errorMessage != nil, onSubmit: submitCode)
                .disabled(isCodeExpired || state.configurationMessage != nil)
            if let message = validation ?? state.errorMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Input error: \(message)")
            }
            if isCodeExpired {
                Text("The code has expired.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                AuthBoardButton(title: "Resend code", action: resend)
            } else {
                resendControl
            }
            Button("Change email", action: goBack)
                .font(.footnote.weight(.medium))
                .foregroundStyle(AuthBoardStyle.ink)
                .frame(minHeight: 44)
        }
    }

    @ViewBuilder
    private var resendControl: some View {
        if let countdownDate {
            resendButton(at: countdownDate)
        } else {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                resendButton(at: context.date)
            }
        }
    }

    private func resendButton(at date: Date) -> some View {
        let remaining = max(0, Int((state.resendAvailableAt ?? date).timeIntervalSince(date).rounded(.up)))
        return Button(action: resend) {
            Text(remaining > 0 ? "Resend code in \(remaining / 60):\(String(format: "%02d", remaining % 60))" : "Resend code")
                .font(.footnote)
                .foregroundStyle(remaining > 0 ? AuthBoardStyle.muted : AuthBoardStyle.ink)
                .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .disabled(remaining > 0 || state.configurationMessage != nil)
    }

    private func configurationNotice(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign-in isn’t enabled in this build")
                .font(.footnote.weight(.semibold))
            Text(message)
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Retry configuration", action: onRetryConfiguration)
                .font(.footnote.weight(.semibold))
                .frame(minHeight: 44)
        }
        .foregroundStyle(AuthBoardStyle.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(KeepsakeStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }

    private func submitEmail() {
        guard !state.isWorking, state.configurationMessage == nil, entryProvider.supportsEmailOTP else { return }
        guard let normalized = AuthInput.normalizedEmail(email) else {
            validation = "Enter a valid email address."
            return
        }
        validation = nil
        email = normalized
        isEmailFocused = false
        onSendCode(normalized)
    }

    private func submitCode() {
        guard !state.isWorking, state.configurationMessage == nil, !isCodeExpired,
              navigation.screen == .verification else { return }
        guard let normalized = AuthInput.normalizedCode(code) else {
            validation = "Enter the six-digit code from your email."
            return
        }
        validation = nil
        onVerifyCode(normalized)
    }

    private func resend() {
        guard !state.isWorking, state.configurationMessage == nil else { return }
        code = ""
        validation = nil
        onResend()
    }

    private func goBack() {
        guard !state.isWorking else { return }
        if navigation.screen == .verification {
            code = ""
            onChangeEmail()
        }
        navigation.goBack()
        validation = nil
    }
}
