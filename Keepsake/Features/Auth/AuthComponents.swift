import SwiftUI

enum AuthBoardStyle {
    static let canvas = Color(red: 0.985, green: 0.985, blue: 0.992)
    static let ink = Color(red: 0.075, green: 0.071, blue: 0.106)
    static let field = Color(red: 0.953, green: 0.953, blue: 0.969)
    static let muted = Color(red: 0.36, green: 0.36, blue: 0.40)
    static let inset: CGFloat = 24
}

@MainActor
struct AuthBoardButton: View {
    let title: String
    var symbol: String? = nil
    var isEnabled = true
    var isPrimary = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let symbol {
                    Image(systemName: symbol)
                }
                Text(title)
                    .multilineTextAlignment(.center)
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isPrimary ? Color.white : AuthBoardStyle.ink)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(isPrimary ? AuthBoardStyle.ink : AuthBoardStyle.field, in: Capsule())
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
    }
}

@MainActor
struct AuthPageScaffold<Content: View, Footer: View>: View {
    let onBack: () -> Void
    private let topSpacing: CGFloat
    private let content: Content
    private let footer: Footer

    init(onBack: @escaping () -> Void, topSpacing: CGFloat = 64, @ViewBuilder content: () -> Content, @ViewBuilder footer: () -> Footer) {
        self.onBack = onBack
        self.topSpacing = topSpacing
        self.content = content()
        self.footer = footer()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.body.weight(.medium))
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)

            ScrollView {
                content
                    .frame(maxWidth: 480, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, AuthBoardStyle.inset)
                    .padding(.top, topSpacing)
                    .padding(.bottom, 24)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollBounceBehavior(.basedOnSize)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            footer
                .frame(maxWidth: 480)
                .padding(.horizontal, AuthBoardStyle.inset)
                .padding(.top, 12)
                .padding(.bottom, 16)
                .frame(maxWidth: .infinity)
                .background(AuthBoardStyle.canvas)
        }
        .foregroundStyle(AuthBoardStyle.ink)
        .background { AuthBoardStyle.canvas.ignoresSafeArea() }
    }
}

@MainActor
struct AuthHeading: View {
    let title: String
    let subtitle: String
    var centered = false

    var body: some View {
        VStack(alignment: centered ? .center : .leading, spacing: 12) {
            Text(title)
                .font(.title.weight(.bold))
                .tracking(-0.5)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(AuthBoardStyle.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: centered ? .center : .leading)
        .multilineTextAlignment(centered ? .center : .leading)
    }
}

@MainActor
struct AuthArtworkPlaceholder: View {
    var body: some View {
        ZStack {
            Color(red: 0.34, green: 0.38, blue: 0.42)
            Text("Scenic artwork not included")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.8))
                .padding(16)
        }
        .accessibilityLabel("Scenic artwork placeholder")
    }
}

@MainActor
struct AuthLoadingView: View {
    let title: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(title)
                .font(.subheadline.weight(.medium))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundStyle(AuthBoardStyle.ink)
        .background { AuthBoardStyle.canvas.ignoresSafeArea() }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct AuthOTPInput: View {
    @Binding var code: String
    var hasError = false
    let onSubmit: () -> Void
    @FocusState private var isFocused: Bool
    @ScaledMetric(relativeTo: .title2) private var digitSize: CGFloat = 24

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    Text(digit(at: index))
                        .font(.system(size: digitSize, weight: .semibold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, minHeight: max(52, digitSize + 20))
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay {
                            RoundedRectangle(cornerRadius: 10)
                                .strokeBorder(border(at: index), lineWidth: isFocused && index == min(code.count, 5) ? 1.5 : 1)
                        }
                }
            }
            .accessibilityHidden(true)

            TextField("", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .foregroundStyle(.clear)
                .tint(.clear)
                .focused($isFocused)
                .frame(minHeight: 52)
                .onSubmit(onSubmit)
                .accessibilityLabel("Six-digit verification code")
                .accessibilityHint("Enter, paste or AutoFill the complete code in this single field")
                .onChange(of: code) { _, raw in
                    let edited = AuthCodeInput.editingValue(raw)
                    if raw != edited { code = edited }
                }
        }
        .contentShape(Rectangle())
        .onTapGesture { isFocused = true }
        .onAppear { isFocused = true }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Button("Done") { isFocused = false }
                Spacer()
                Button("Verify code", action: onSubmit)
                    .disabled(AuthInput.normalizedCode(code) == nil)
            }
        }
    }

    private func digit(at index: Int) -> String {
        let digits = Array(code)
        return digits.indices.contains(index) ? String(digits[index]) : " "
    }

    private func border(at index: Int) -> Color {
        if hasError { return .red.opacity(0.65) }
        return isFocused && index == min(code.count, 5) ? KeepsakeStyle.accent : KeepsakeStyle.separator
    }
}
