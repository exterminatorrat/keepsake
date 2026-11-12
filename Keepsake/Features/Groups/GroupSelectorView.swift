import SwiftUI

@MainActor
struct GroupSelectorView: View {
    let group: SoloGroup
    let onSelectGroup: () -> Void
    let onCreateGroup: () -> Void
    let onJoinGroup: () -> Void
    let width: CGFloat
    let maximumHeight: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            menuContent
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    contentHeight = height
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: width)
        .frame(height: min(maximumHeight, contentHeight > 0 ? contentHeight : maximumHeight))
        .background(KeepsakeStyle.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(KeepsakeStyle.separator, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.12), radius: 24, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAction(.escape, onSelectGroup)
    }

    private var menuContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onSelectGroup) {
                HStack(spacing: 6) {
                    if !dynamicTypeSize.isAccessibilitySize {
                        GroupMonogram(name: group.name, size: 28)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.name)
                            .font(dynamicTypeSize.isAccessibilitySize ? .body.weight(.semibold) : .caption.weight(.semibold))
                            .foregroundStyle(KeepsakeStyle.ink)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("1 member")
                            .font(.caption)
                            .foregroundStyle(KeepsakeStyle.secondaryInk)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(KeepsakeStyle.accent)
                        .frame(width: 14)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
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
