import SwiftUI

@MainActor
struct SettingsView: View {
    let account: AccountIdentity
    let group: SoloGroup
    let onShowGroup: () -> Void
    let onShowAccount: () -> Void
    let onBack: () -> Void
    let onUnavailable: (UnavailableFeature) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GroupScreenHeader(title: "Settings", onBack: onBack, backSymbol: "xmark", backLabel: "Close settings")

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    groupCard
                    section("Group", rows: groupRows)
                    section("Universal", rows: universalRows)
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

    private var groupCard: some View {
        GroupCardButton(action: onShowGroup) {
            HStack(spacing: 12) {
                GroupMonogram(name: group.name, size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(KeepsakeStyle.ink)
                        .lineLimit(1)
                    Text("1 member")
                        .font(.footnote)
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                }

                Spacer(minLength: 8)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(KeepsakeStyle.secondaryInk.opacity(0.7))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityLabel("\(group.name), 1 member")
        .accessibilityHint("Shows group details")
    }

    private var groupRows: [SettingsRowModel] {
        [
            SettingsRowModel(title: "Notifications", symbol: "bell") { onUnavailable(.notifications) },
            SettingsRowModel(title: "Location sharing", symbol: "location") { onUnavailable(.locationSharing) },
            SettingsRowModel(title: "Activity sharing", symbol: "waveform.path.ecg") { onUnavailable(.activitySharing) },
            SettingsRowModel(title: "Saved places", symbol: "mappin.and.ellipse") { onUnavailable(.savedPlaces) },
            SettingsRowModel(title: "Manage members", symbol: "person.2") { onUnavailable(.manageMembers) }
        ]
    }

    private var universalRows: [SettingsRowModel] {
        [
            SettingsRowModel(title: "Account", symbol: "person.crop.circle", showsDisclosure: true, action: onShowAccount),
            SettingsRowModel(title: "Privacy Center", symbol: "hand.raised") { onUnavailable(.privacyCenter) },
            SettingsRowModel(title: "Help & Support", symbol: "questionmark.circle") { onUnavailable(.helpSupport) }
        ]
    }

    private func section(_ title: String, rows: [SettingsRowModel]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: title)

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
}

struct SettingsRowModel: Identifiable {
    var id: String { title }
    let title: String
    let symbol: String
    var showsDisclosure = false
    let action: () -> Void
}
