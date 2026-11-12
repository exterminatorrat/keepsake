import Foundation
import SwiftUI
import UIKit

@MainActor
struct AuthScreenView: View {
    private enum Field: Hashable {
        case email
        case code
    }

    let state: AuthScreenState
    let onSendCode: (String) -> Void
    let onVerifyCode: (String) -> Void
    let onResend: () -> Void
    let onChangeEmail: () -> Void
    let onRetryConfiguration: () -> Void

    @State private var email: String
    @State private var code = ""
    @State private var showsEmailValidation = false
    @State private var showsCodeValidation = false
    @FocusState private var focusedField: Field?
    @ScaledMetric(relativeTo: .title2) private var codeSize: CGFloat = 24

    init(
        state: AuthScreenState,
        onSendCode: @escaping (String) -> Void,
        onVerifyCode: @escaping (String) -> Void,
        onResend: @escaping () -> Void,
        onChangeEmail: @escaping () -> Void,
        onRetryConfiguration: @escaping () -> Void
    ) {
        self.state = state
        self.onSendCode = onSendCode
        self.onVerifyCode = onVerifyCode
        self.onResend = onResend
        self.onChangeEmail = onChangeEmail
        self.onRetryConfiguration = onRetryConfiguration
        _email = State(initialValue: state.email)
    }

    var body: some View {
        ZStack {
            KeepsakeStyle.canvas.ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    wordmark
                    heading

                    if let message = state.configurationMessage {
                        configurationCard(message)
                    }

                    fieldSection

                    if let message = state.errorMessage {
                        errorCard(message)
                    }

                    primaryButton

                    if state.step == .code {
                        codeActions
                    }

                    Text(footnote)
                        .font(.caption)
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 32)
                .frame(maxWidth: 480, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .scrollDismissesKeyboard(.interactively)
        }
        .tint(KeepsakeStyle.accent)
        .toolbar { keyboardToolbar }
        .onChange(of: state.step) { _, _ in
            code = ""
            showsEmailValidation = false
            showsCodeValidation = false
        }
        .onChange(of: state.email) { _, _ in
            code = ""
        }
    }

    private var wordmark: some View {
        HStack(spacing: 8) {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(KeepsakeStyle.accent)
                .frame(width: 10, height: 10)

            Text("Keepsake")
                .font(.footnote.weight(.semibold))
                .tracking(1.4)
                .textCase(.uppercase)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Keepsake")
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.step == .email ? "Sign in" : "Check your email")
                .font(.largeTitle.weight(.semibold))
                .fontDesign(.rounded)
                .foregroundStyle(KeepsakeStyle.ink)
                .accessibilityAddTraits(.isHeader)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var subtitle: String {
        switch state.step {
        case .email:
            "We’ll email you a one-time code. No password needed."
        case .code:
            state.email.isEmpty
                ? "Enter the 6-digit code from your email."
                : "Enter the 6-digit code we sent to \(state.email)."
        }
    }

    private var fieldSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(state.step == .email ? "Email" : "One-time code")
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .tracking(0.8)
                .foregroundStyle(KeepsakeStyle.secondaryInk)

            switch state.step {
            case .email:
                emailField
            case .code:
                codeField
            }

            if let message = validationMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityLabel("Input error: \(message)")
            }
        }
    }

    private var emailField: some View {
        TextField("name@example.com", text: $email)
            .textContentType(.emailAddress)
            .keyboardType(.emailAddress)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .submitLabel(.continue)
            .focused($focusedField, equals: .email)
            .onSubmit(submitEmail)
            .font(.body)
            .foregroundStyle(KeepsakeStyle.ink)
            .disabled(state.isWorking)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(fieldBackground)
            .accessibilityLabel("Email address")
            .onAppear {
                if !state.isWorking {
                    focusedField = .email
                }
            }
    }

    private var codeField: some View {
        TextField("000000", text: $code)
            .textContentType(.oneTimeCode)
            .keyboardType(.numberPad)
            .submitLabel(.done)
            .focused($focusedField, equals: .code)
            .onSubmit(submitCode)
            .font(.system(size: codeSize, weight: .medium, design: .monospaced))
            .foregroundStyle(KeepsakeStyle.ink)
            .disabled(state.isWorking)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(fieldBackground)
            .accessibilityLabel("One-time code")
            .onAppear {
                if !state.isWorking {
                    focusedField = .code
                }
            }
    }

    private var fieldBackground: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(.white)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(KeepsakeStyle.separator, lineWidth: 1)
            }
    }

    private var primaryButton: some View {
        Button(action: submit) {
            HStack(spacing: 10) {
                if state.isWorking {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }

                Text(primaryTitle)
            }
            .font(.headline)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(KeepsakeStyle.ink)
            )
            .opacity(state.isWorking ? 0.6 : 1)
        }
        .buttonStyle(.plain)
        .disabled(state.isWorking)
        .accessibilityLabel(primaryTitle)
    }

    private var primaryTitle: String {
        switch state.step {
        case .email:
            state.isWorking ? "Sending code…" : "Continue"
        case .code:
            state.isWorking ? "Verifying…" : "Verify code"
        }
    }

    private var codeActions: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                Text("Didn’t get it?")
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                resendControl
            }
            .font(.footnote)

            Button("Change email", action: changeEmail)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.accent)
                .buttonStyle(.plain)
                .disabled(state.isWorking)
                .opacity(state.isWorking ? 0.4 : 1)
        }
    }

    @ViewBuilder
    private var resendControl: some View {
        if let availableAt = state.resendAvailableAt {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                resendButton(availableAt: availableAt, now: context.date)
            }
        } else {
            resendButton(availableAt: nil, now: .now)
        }
    }

    private func resendButton(availableAt: Date?, now: Date) -> some View {
        let seconds = remainingSeconds(availableAt: availableAt, now: now)

        return Button {
            code = ""
            focusedField = .code
            onResend()
        } label: {
            Text(seconds > 0 ? "Resend in \(timeText(seconds))" : "Resend")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(seconds > 0 ? KeepsakeStyle.secondaryInk : KeepsakeStyle.accent)
        }
        .buttonStyle(.plain)
        .disabled(state.isWorking || seconds > 0)
        .accessibilityLabel(seconds > 0 ? "Resend available in \(seconds) seconds" : "Resend code")
        .accessibilityHint(
            seconds > 0
                ? "Please wait before requesting another code."
                : "Sends a new six-digit code to \(state.email)."
        )
    }

    private var validationMessage: String? {
        switch state.step {
        case .email:
            guard showsEmailValidation, AuthInput.normalizedEmail(email) == nil else { return nil }
            return "Enter a valid email address, like name@example.com."
        case .code:
            guard showsCodeValidation, AuthInput.normalizedCode(code) == nil else { return nil }
            return "Enter the 6-digit code from your email."
        }
    }

    private var footnote: String {
        switch state.step {
        case .email:
            "Your email is only used to sign in to Keepsake."
        case .code:
            "Codes are short-lived. Request a new one if this code has expired."
        }
    }

    private func configurationCard(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sign-in isn’t available in this build", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.ink)

            Text(message)
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)

            Button("Retry", action: onRetryConfiguration)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Capsule().fill(KeepsakeStyle.accent))
                .buttonStyle(.plain)
                .disabled(state.isWorking)
                .opacity(state.isWorking ? 0.4 : 1)
                .accessibilityHint("Checks the sign-in configuration again.")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(KeepsakeStyle.accent.opacity(0.08))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(KeepsakeStyle.accent.opacity(0.4), lineWidth: 1)
        }
    }

    private func errorCard(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)

            Text(message)
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.red.opacity(0.07))
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }

    @ToolbarContentBuilder
    private var keyboardToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .keyboard) {
            Button("Done") {
                focusedField = nil
            }

            Spacer()

            switch state.step {
            case .email:
                Button("Continue", action: submitEmail)
                    .fontWeight(.semibold)
                    .disabled(state.isWorking)
            case .code:
                Button("Verify", action: submitCode)
                    .fontWeight(.semibold)
                    .disabled(state.isWorking)
            }
        }
    }

    private func submit() {
        switch state.step {
        case .email:
            submitEmail()
        case .code:
            submitCode()
        }
    }

    private func submitEmail() {
        guard let normalized = AuthInput.normalizedEmail(email) else {
            showsEmailValidation = true
            return
        }

        showsEmailValidation = false
        email = normalized
        focusedField = nil
        onSendCode(normalized)
    }

    private func submitCode() {
        guard let normalized = AuthInput.normalizedCode(code) else {
            showsCodeValidation = true
            return
        }

        showsCodeValidation = false
        focusedField = nil
        onVerifyCode(normalized)
    }

    private func changeEmail() {
        code = ""
        showsCodeValidation = false
        focusedField = .email
        onChangeEmail()
    }

    private func remainingSeconds(availableAt: Date?, now: Date) -> Int {
        guard let availableAt else { return 0 }
        return max(0, Int(availableAt.timeIntervalSince(now).rounded(.up)))
    }

    private func timeText(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
