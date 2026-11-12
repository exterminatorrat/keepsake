import SwiftUI

@MainActor
struct GroupSelectorView: View {
    let group: SoloGroup
    let onSelectGroup: () -> Void
    let onCreateGroup: () -> Void
    let onJoinGroup: () -> Void

    @ScaledMetric(relativeTo: .body) private var width: CGFloat = 182

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelectGroup) {
                HStack(spacing: 12) {
                    GroupMonogram(name: group.name, size: 34)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(KeepsakeStyle.ink)
                            .lineLimit(1)
                        Text("1 member")
                            .font(.caption)
                            .foregroundStyle(KeepsakeStyle.secondaryInk)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KeepsakeStyle.accent)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: 60)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(group.name), 1 member, selected")

            Divider()
                .overlay(KeepsakeStyle.separator)

            GroupSelectorAction(title: "Create group", symbol: "plus", action: onCreateGroup)
            GroupSelectorAction(title: "Join group", symbol: "person.badge.plus", action: onJoinGroup)
        }
        .frame(maxWidth: width)
        .background(KeepsakeStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(KeepsakeStyle.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onSelectGroup)
    }
}

@MainActor
private struct GroupSelectorAction: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(KeepsakeStyle.accent)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(KeepsakeStyle.ink)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityHint("Not available in this build")
    }
}
