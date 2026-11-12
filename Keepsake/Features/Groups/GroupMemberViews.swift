import SwiftUI

@MainActor
struct GroupMemberCardView: View {
    let group: SoloGroup
    let onExpand: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                GroupMonogram(name: "You", size: 44)

                Button(action: onExpand) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("You")
                            .font(.headline)
                            .foregroundStyle(KeepsakeStyle.ink)
                        Text("Owner · 1 member")
                            .font(.footnote)
                            .foregroundStyle(KeepsakeStyle.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("You, group owner")
                .accessibilityHint("Opens your member details")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.bold))
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                        .frame(width: 32, height: 32)
                        .background(KeepsakeStyle.cardFill, in: Circle())
                        .frame(width: KeepsakeStyle.minimumHitTarget, height: KeepsakeStyle.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close member card")
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()
                .overlay(KeepsakeStyle.separator)

            Text("You’re the only member of \(group.name). Keepsake doesn’t share your location in this build.")
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()
                .overlay(KeepsakeStyle.separator)

            GroupListRow(
                title: "Member details",
                symbol: "person.text.rectangle",
                showsDisclosure: true,
                action: onExpand
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeepsakeStyle.surface, in: RoundedRectangle(cornerRadius: KeepsakeStyle.sheetRadius, style: .continuous))
        .shadow(color: .black.opacity(0.1), radius: 24, y: -4)
        .padding(.horizontal, KeepsakeStyle.margin)
        .padding(.bottom, 8)
    }
}

@MainActor
struct GroupMemberDetailView: View {
    let group: SoloGroup
    let onBack: () -> Void
    let onUnavailable: (UnavailableFeature) -> Void

    var body: some View {
        VStack(spacing: 0) {
            GroupScreenHeader(title: "You", onBack: onBack)

            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    identity
                    facts
                    activity
                }
                .padding(.horizontal, KeepsakeStyle.margin)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { KeepsakeStyle.canvas.ignoresSafeArea() }
    }

    private var identity: some View {
        HStack(spacing: 16) {
            GroupMonogram(name: "You", size: 68)

            VStack(alignment: .leading, spacing: 4) {
                Text("You")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(KeepsakeStyle.ink)
                Text("Owner")
                    .font(.subheadline)
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                Text(group.name)
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
                row("Group", value: group.name)
                Divider().overlay(KeepsakeStyle.separator)
                row("Role", value: "Owner")
                Divider().overlay(KeepsakeStyle.separator)
                row("Location sharing", value: "Not shared")
            }
            .padding(.horizontal, 16)
            .background(KeepsakeStyle.cardFill, in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius))

            Button {
                onUnavailable(.locationSharing)
            } label: {
                HStack(spacing: 8) {
                    Text("Why isn’t my location shared?")
                        .font(.footnote.weight(.medium))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(KeepsakeStyle.accent)
                .frame(minHeight: KeepsakeStyle.minimumHitTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Not available in this build")
        }
    }

    private var activity: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: "Recent activity")
            GroupEmptyState(
                title: "No activity yet",
                message: "Keepsake doesn’t record or share member activity in this build."
            )
        }
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
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 46)
        .accessibilityElement(children: .combine)
    }
}
