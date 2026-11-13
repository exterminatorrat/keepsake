import SwiftUI

@MainActor
struct GroupMonogram: View {
    let name: String
    var size: CGFloat = 44

    private var initial: String {
        name.first.map { String($0).uppercased() } ?? "•"
    }

    var body: some View {
        Text(initial)
            .font(.system(size: size * 0.4, weight: .semibold))
            .foregroundStyle(KeepsakeStyle.accent)
            .frame(width: size, height: size)
            .background(KeepsakeStyle.accent.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
    }
}

@MainActor
struct GroupScreenHeader: View {
    let title: String
    var onBack: (() -> Void)?
    var backSymbol = "chevron.left"
    var backLabel = "Back"

    var body: some View {
        ZStack {
            Text(title)
                .font(.title3.weight(.semibold))
                .foregroundStyle(KeepsakeStyle.ink)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)

            if let onBack {
                HStack {
                    Button(action: onBack) {
                        Image(systemName: backSymbol)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(KeepsakeStyle.ink)
                            .frame(width: 44, height: 44)
                            .background(KeepsakeStyle.surface, in: Circle())
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(backLabel)
                    Spacer(minLength: 0)
                }
            }
        }
        .frame(minHeight: KeepsakeStyle.minimumHitTarget)
        .padding(.horizontal, KeepsakeStyle.margin)
    }
}

@MainActor
struct GroupPrimaryButton: View {
    let title: String
    var isWorking = false
    var isEnabled = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if isWorking {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .tint(.white)
                }
                Text(title)
                    .font(.body.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(KeepsakeStyle.ink, in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius))
            .opacity(isEnabled ? (isWorking ? 0.7 : 1) : 0.35)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isWorking || !isEnabled)
    }
}

@MainActor
struct GroupSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(KeepsakeStyle.ink)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

@MainActor
struct GroupEmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(KeepsakeStyle.ink)
            Text(message)
                .font(.footnote)
                .foregroundStyle(KeepsakeStyle.secondaryInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(KeepsakeStyle.cardFill, in: RoundedRectangle(cornerRadius: KeepsakeStyle.controlRadius))
    }
}

@MainActor
struct GroupListRow: View {
    let title: String
    let symbol: String
    var detail: String?
    var showsDisclosure = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 18) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(KeepsakeStyle.secondaryInk)
                    .frame(width: 32)
                    .accessibilityHidden(true)

                Text(title)
                    .font(.body)
                    .foregroundStyle(KeepsakeStyle.ink)

                Spacer(minLength: 8)

                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(KeepsakeStyle.secondaryInk)
                }

                if showsDisclosure {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(KeepsakeStyle.secondaryInk.opacity(0.7))
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 52)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

@MainActor
struct GroupCardButton<Content: View>: View {
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        Button(action: action) {
            content()
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(KeepsakeStyle.surface, in: RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius))
                .overlay {
                    RoundedRectangle(cornerRadius: KeepsakeStyle.cardRadius)
                        .strokeBorder(KeepsakeStyle.separator, lineWidth: 1)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
