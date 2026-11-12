import SwiftUI

@MainActor
struct AppRootView: View {
    let session: AppSession

    var body: some View {
        Group {
            switch session.phase {
            case .restoring:
                VStack(spacing: 16) {
                    Text("Keepsake")
                        .font(.largeTitle.bold())
                    ProgressView("Restoring your account…")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeepsakeStyle.canvas)
            case .signedOut, .configurationUnavailable:
                NavigationStack {
                    AuthScreenView(
                        state: session.auth,
                        onSendCode: { email in Task { await session.sendCode(to: email) } },
                        onVerifyCode: { code in Task { await session.verifyCode(code) } },
                        onResend: { Task { await session.resendCode() } },
                        onChangeEmail: session.changeEmail,
                        onRetryConfiguration: { Task { await session.restore() } }
                    )
                    .toolbar(.hidden, for: .navigationBar)
                }
            case .signedIn(let account, let context):
                GroupsShellView(
                    account: account,
                    state: session.group,
                    onCreate: { name in Task { await session.createGroup(named: name) } },
                    onRetry: { Task { await session.reloadGroup() } },
                    onSignOut: { Task { await session.signOut() } }
                )
                .id(context.generation)
            }
        }
        .tint(KeepsakeStyle.accent)
        .task { await session.restore() }
    }
}
