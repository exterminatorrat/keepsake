import SwiftUI

@MainActor
struct GroupSheetView: View {
    let group: SoloGroup
    let isExpanded: Bool
    let isOffline: Bool
    let onToggleExpanded: () -> Void
    let onShowMember: () -> Void
    let onRetry: () -> Void
    let onUnavailable: (UnavailableFeature) -> Void

    var body: some View {
        VStack(spacing: 0) {
            handle
            ViewThatFits(in: .vertical) {
                sheetContent
                ScrollView {
                    sheetContent
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: KeepsakeStyle.sheetRadius,
                topTrailingRadius: KeepsakeStyle.sheetRadius,
                style: .continuous
            )
            .fill(KeepsakeStyle.surface)
            .shadow(color: .black.opacity(0.08), radius: 24, y: -6)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(group.name) group")
    }

    private var handle: some View {
        Capsule()
            .fill(KeepsakeStyle.separator)
            .frame(width: 40, height: 5)
            .frame(maxWidth: .infinity)
            .frame(height: 26)
            .contentShape(Rectangle())
            .onTapGesture(perform: onToggleExpanded)
            .gesture(
                DragGesture(minimumDistance: 10)
                    .onEnded { value in
                        guard abs(value.translation.height) > 24 else { return }
                        if value.translation.height < 0, !isExpanded {
                            onToggleExpanded()
                        } else if value.translation.height > 0, isExpanded {
                            onToggleExpanded()
                        }
                    }
            )
            .accessibilityHidden(true)
    }

    private var sheetContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            titleRow
            Button(action: onShowMember) {
                HStack(spacing: 12) {
                    GroupMonogram(name: "You", size: 48)
                    Text("You")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(KeepsakeStyle.ink)
                    Spacer()
                    Text("1 member")
                        .font(.footnote)
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("You, the only group member")
            .accessibilityHint("Shows your member card")
            actionRow
            if isOffline {
                offlineBanner
            }
            todaySection
            if isExpanded {
                membersSection
                detailsSection
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 2)
        .padding(.bottom, 26)
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(group.name)
                .font(.title2.weight(.bold))
                .foregroundStyle(KeepsakeStyle.ink)
                .lineLimit(2)

            Spacer(minLength: 0)

            Button(action: onToggleExpanded) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(KeepsakeStyle.ink)
                    .frame(width: 36, height: 36)
                    .background(KeepsakeStyle.cardFill, in: Circle())
                    .frame(width: KeepsakeStyle.minimumHitTarget, height: KeepsakeStyle.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse group details" : "Expand group details")
        }
    }

    private var actionRow: some View {
        HStack(spacing: 0) {
            ForEach(GroupAction.allCases) { action in
                Button {
                    onUnavailable(action.feature)
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 19, weight: .medium))
                            .frame(height: 22)
                        Text(action.title)
                            .font(.caption)
                            .lineLimit(1)
                    }
                    .foregroundStyle(KeepsakeStyle.ink)
                    .frame(maxWidth: .infinity, minHeight: 66)
                    .background(KeepsakeStyle.cardFill, in: RoundedRectangle(cornerRadius: 14))
                    .padding(.horizontal, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Not available in this build")
            }
        }
    }

    private var offlineBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "wifi.slash")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .accessibilityHidden(true)
            Text("You’re offline. The map and group details may be out of date.")
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Retry", action: onRetry)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.accent)
                .frame(minHeight: KeepsakeStyle.minimumHitTarget)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(KeepsakeStyle.cardFill, in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius))
    }

    private var todaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: "Today")
            GroupEmptyState(
                title: "No activity yet",
                message: "Keepsake doesn’t record or share group activity in this build."
            )
        }
    }

    private var membersSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: "Members · 1")

            GroupCardButton(action: onShowMember) {
                HStack(spacing: 12) {
                    GroupMonogram(name: "You", size: 40)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("You")
                            .font(.body.weight(.medium))
                            .foregroundStyle(KeepsakeStyle.ink)
                        Text("Owner")
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
            .accessibilityLabel("You, group owner")
            .accessibilityHint("Shows your member card")
        }
    }

    private var detailsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            GroupSectionHeader(title: "Group")

            VStack(spacing: 0) {
                detailRow("Created", value: group.createdAt.formatted(date: .abbreviated, time: .omitted))
                Divider().overlay(KeepsakeStyle.separator)
                detailRow("Privacy", value: "Private")
            }
            .padding(.horizontal, 16)
            .background(KeepsakeStyle.cardFill, in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius))
        }
    }

    private func detailRow(_ title: String, value: String) -> some View {
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

private enum GroupAction: String, CaseIterable, Identifiable {
    case chat, savedPlaces, manage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chat: "Chat"
        case .savedPlaces: "Saved Places"
        case .manage: "Manage"
        }
    }

    var symbol: String {
        switch self {
        case .chat: "bubble.left"
        case .savedPlaces: "mappin.and.ellipse"
        case .manage: "slider.horizontal.3"
        }
    }

    var feature: UnavailableFeature {
        switch self {
        case .chat: .chat
        case .savedPlaces: .savedPlaces
        case .manage: .manageGroup
        }
    }
}
