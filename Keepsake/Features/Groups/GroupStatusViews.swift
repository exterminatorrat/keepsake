import SwiftUI

@MainActor
struct GroupLoadingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
                .tint(KeepsakeStyle.accent)
            Text("Loading your group")
                .font(.headline)
                .foregroundStyle(KeepsakeStyle.ink)
            Text("Checking this account for a group.")
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
        }
        .multilineTextAlignment(.center)
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
        .accessibilityElement(children: .combine)
    }
}

@MainActor
struct GroupFailureView: View {
    let message: String
    let isOffline: Bool
    let onRetry: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            if isOffline {
                GroupMapBackdrop(isDimmed: true)
                    .ignoresSafeArea()
            } else {
                KeepsakeStyle.canvas
                    .ignoresSafeArea()
            }

            VStack(spacing: 12) {
                Image(systemName: isOffline ? "wifi.slash" : "exclamationmark.triangle")
                    .font(.system(size: 28, weight: .medium))
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                    .accessibilityHidden(true)

                Text(isOffline ? "You’re offline" : "Something went wrong")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(KeepsakeStyle.ink)
                    .accessibilityAddTraits(.isHeader)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                GroupPrimaryButton(title: "Retry", action: onRetry)
                    .padding(.top, 6)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
            .background(
                KeepsakeStyle.surface,
                in: UnevenRoundedRectangle(
                    topLeadingRadius: KeepsakeStyle.sheetRadius,
                    topTrailingRadius: KeepsakeStyle.sheetRadius,
                    style: .continuous
                )
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(KeepsakeStyle.separator)
                    .frame(height: 1)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

@MainActor
struct GroupReconcilingView: View {
    let name: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .accessibilityHidden(true)

            Text("Confirming your group")
                .font(.title3.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.ink)
                .accessibilityAddTraits(.isHeader)

            Text("The earlier attempt to create “\(name)” didn’t get a clear result. Check your account before trying again.")
                .font(.subheadline)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            GroupPrimaryButton(title: "Check status", action: onRetry)
                .padding(.top, 6)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
    }
}

@MainActor
struct GroupTabUnavailableView: View {
    let tab: AppTab
    let onBackToGroups: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .accessibilityHidden(true)

            Text(tab.title)
                .font(.title2.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.ink)
                .accessibilityAddTraits(.isHeader)

            Text("Not available yet")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KeepsakeStyle.accent)

            Text("\(tab.title) isn’t part of this early screen slice. You can return to Groups and account settings.")
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            Button("Back to Groups", action: onBackToGroups)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.accent)
                .frame(minHeight: KeepsakeStyle.minimumHitTarget)
                .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
        .accessibilityElement(children: .contain)
    }

    private var symbol: String {
        switch tab {
        case .groups: "person.3"
        case .explore: "magnifyingglass"
        case .camera: "camera"
        case .friends: "person.2"
        case .memories: "photo"
        }
    }
}
