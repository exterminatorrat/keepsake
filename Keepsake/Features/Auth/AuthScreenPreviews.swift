import SwiftUI

private enum AuthPreviewFixtures {
    static let email = AuthScreenState(
        step: .email,
        email: ""
    )

    static let code = AuthScreenState(
        step: .code,
        email: "harry@example.com"
    )

    static let error = AuthScreenState(
        step: .code,
        email: "harry@example.com",
        errorMessage: AppServiceError.invalidCode.message,
        resendAvailableAt: .now.addingTimeInterval(24)
    )

    static let configuration = AuthScreenState(
        step: .email,
        configurationMessage: AppServiceError.configurationUnavailable.message
    )
}

#Preview("CONFIGURATION") {
    AuthScreenView(
        state: AuthPreviewFixtures.configuration,
        onSendCode: { _ in },
        onVerifyCode: { _ in },
        onResend: {},
        onChangeEmail: {},
        onRetryConfiguration: {}
    )
}

#Preview("EMAIL") {
    AuthScreenView(
        state: AuthPreviewFixtures.email,
        onSendCode: { _ in },
        onVerifyCode: { _ in },
        onResend: {},
        onChangeEmail: {},
        onRetryConfiguration: {}
    )
}

#Preview("CODE") {
    AuthScreenView(
        state: AuthPreviewFixtures.code,
        onSendCode: { _ in },
        onVerifyCode: { _ in },
        onResend: {},
        onChangeEmail: {},
        onRetryConfiguration: {}
    )
}

#Preview("ERROR") {
    AuthScreenView(
        state: AuthPreviewFixtures.error,
        onSendCode: { _ in },
        onVerifyCode: { _ in },
        onResend: {},
        onChangeEmail: {},
        onRetryConfiguration: {}
    )
}
