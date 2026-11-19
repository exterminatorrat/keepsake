import SwiftUI

@MainActor
struct AppRootView: View {
    let session: AppSession
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Group {
            switch session.phase {
            case .restoring:
                AuthLoadingView(title: "Checking your sign-in…")
            case .signedOut, .configurationUnavailable:
                NavigationStack {
                    AuthScreenView(
                        state: session.auth,
                        onSendCode: { email in Task { await session.sendCode(to: email) } },
                        onVerifyCode: { code in Task { await session.verifyCode(code) } },
                        onResend: { Task { await session.resendCode() } },
                        onChangeEmail: session.changeEmail,
                        onRetryConfiguration: { Task { await session.restore() } },
                        startsAtWelcome: true
                    )
                    .toolbar(.hidden, for: .navigationBar)
                }
                .safeAreaInset(edge: .bottom) {
                    Button("Sign out on this device") { Task { await session.signOut() } }
                        .disabled(session.auth.isWorking)
                        .padding()
                }
            case .signedIn(let account, let context):
                GroupsShellView(
                    account: account,
                    state: session.group,
                    onCreate: { name in Task { await session.createGroup(named: name) } },
                    onRetry: { Task { await session.reloadGroup() } },
                    onSignOut: { Task { await session.signOut() } },
                    accountGeneration: context.generation,
                    lastCheckedAt: session.lastCheckedAt,
                    notice: session.localNotice
                )
                .id(context.generation)
            }
        }
        .tint(KeepsakeStyle.accent)
        .task { await session.run() }
        .onChange(of: scenePhase) { _, value in
            if value == .active { Task { await session.restore() } }
        }
    }
}
