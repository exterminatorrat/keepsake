import SwiftUI

@MainActor
struct GroupTabBar: View {
    let selection: AppTab
    let onSelect: (AppTab) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                Button {
                    onSelect(tab)
                } label: {
                    GroupTabItem(tab: tab, isSelected: tab == selection)
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title)
                .accessibilityHint(tab == .groups ? "" : "Not available in this build")
                .accessibilityAddTraits(tab == selection ? .isSelected : [])
            }
        }
        .padding(.horizontal, 4)
        .padding(.top, 8)
        .padding(.bottom, 4)
        .background(alignment: .top) {
            Rectangle()
                .fill(KeepsakeStyle.separator)
                .frame(height: 1)
        }
        .background(KeepsakeStyle.canvas)
    }
}

@MainActor
private struct GroupTabItem: View {
    let tab: AppTab
    let isSelected: Bool

    private var tint: Color {
        isSelected ? KeepsakeStyle.accent : KeepsakeStyle.secondaryInk
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if tab == .camera {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(KeepsakeStyle.cameraTile)
                        .frame(width: 44, height: 38)
                    Image(systemName: "camera")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 21, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(tint)
                }
            }
            .frame(height: 38)

            Text(tab.title)
                .font(.caption2)
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .frame(minHeight: KeepsakeStyle.minimumHitTarget)
        .accessibilityHidden(true)
    }

    private var symbol: String {
        switch tab {
        case .groups: isSelected ? "person.3.fill" : "person.3"
        case .explore: "magnifyingglass"
        case .camera: "camera"
        case .friends: "person.2"
        case .memories: "photo"
        }
    }
}
