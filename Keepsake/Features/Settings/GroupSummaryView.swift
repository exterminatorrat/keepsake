import SwiftUI

@MainActor
struct GroupSummaryView: View {
    let group: SoloGroup
    let onBack: () -> Void
    let onUnavailable: (UnavailableFeature) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GroupScreenHeader(title: "Group", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    identity
                    facts
                    actions
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

    private var identity: some View {
        HStack(spacing: 14) {
            GroupMonogram(name: group.name, size: 56)

            VStack(alignment: .leading, spacing: 3) {
                Text(group.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(KeepsakeStyle.ink)
                    .lineLimit(2)
                Text("1 member · You")
                    .font(.footnote)
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var facts: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: "Details")

            VStack(spacing: 0) {
                row("Created", value: group.createdAt.formatted(date: .abbreviated, time: .omitted))
                Divider().overlay(KeepsakeStyle.separator)
                row("Members", value: "1")
                Divider().overlay(KeepsakeStyle.separator)
                row("Privacy", value: "Private")
            }
            .padding(.horizontal, 16)
            .background(
                KeepsakeStyle.cardFill,
                in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius, style: .continuous)
            )
        }
    }

    private var actions: some View {
        VStack(spacing: 0) {
            GroupListRow(
                title: "Invite people",
                symbol: "person.badge.plus",
                showsDisclosure: false
            ) { onUnavailable(.invitePeople) }

            Divider()
                .overlay(KeepsakeStyle.separator)
                .padding(.leading, 72)

            GroupListRow(
                title: "Manage members",
                symbol: "person.2",
                showsDisclosure: false
            ) { onUnavailable(.manageMembers) }
        }
        .background(
            KeepsakeStyle.cardFill,
            in: RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius, style: .continuous)
        )
    }

    private func row(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
            Spacer(minLength: 12)
            Text(value)
                .font(.subheadline)
                .foregroundStyle(KeepsakeStyle.ink)
        }
        .frame(minHeight: 46)
        .accessibilityElement(children: .combine)
    }
}
