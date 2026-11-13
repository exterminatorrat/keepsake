import SwiftUI

@MainActor
struct AccountView: View {
    let account: AccountIdentity
    let onBack: () -> Void
    let onSignOut: () -> Void
    let onUnavailable: (UnavailableFeature) -> Void

    private var subtitle: String {
        account.email ?? "Signed in on this device"
    }

    var body: some View {
        VStack(spacing: 0) {
            GroupScreenHeader(title: "Account", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    profile
                    section(rows: libraryRows)
                    section(rows: supportRows)
                    signOutButton
                }
                .padding(.horizontal, KeepsakeStyle.margin)
                .padding(.top, 12)
                .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
    }

    private var profile: some View {
        HStack(spacing: 14) {
            GroupMonogram(name: "You", size: 64)

            VStack(alignment: .leading, spacing: 4) {
                Text("You")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(KeepsakeStyle.ink)
                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var libraryRows: [SettingsRowModel] {
        [
            SettingsRowModel(title: "My memories", symbol: "rectangle.stack") { onUnavailable(.memories) },
            SettingsRowModel(title: "Trips", symbol: "airplane") { onUnavailable(.trips) }
        ]
    }

    private var supportRows: [SettingsRowModel] {
        [
            SettingsRowModel(title: "Help & Support", symbol: "questionmark.circle") { onUnavailable(.helpSupport) }
        ]
    }

    private var signOutButton: some View {
        Button(role: .destructive, action: onSignOut) {
            Text("Sign out")
                .font(.body.weight(.medium))
                .foregroundStyle(KeepsakeStyle.destructive)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 52)
                .background(
                    KeepsakeStyle.surface,
                    in: RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius, style: .continuous)
                        .strokeBorder(KeepsakeStyle.separator, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func section(rows: [SettingsRowModel]) -> some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                GroupListRow(
                    title: row.title,
                    symbol: row.symbol,
                    showsDisclosure: row.showsDisclosure,
                    action: row.action
                )

                if index < rows.count - 1 {
                    Divider()
                        .overlay(KeepsakeStyle.separator)
                        .padding(.leading, 72)
                }
            }
        }
        .background(
            KeepsakeStyle.cardFill,
            in: RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius, style: .continuous)
        )
    }
}
