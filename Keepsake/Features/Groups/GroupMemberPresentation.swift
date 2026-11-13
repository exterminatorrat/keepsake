import Foundation

struct GroupMemberPresentation: Identifiable, Equatable, Sendable {
    let id: AccountID
    let displayName: String
    let role: String
    let isSelf: Bool

    static func selfMember(account: AccountIdentity) -> Self {
        Self(id: account.id, displayName: "You", role: "Owner", isSelf: true)
    }
}

enum GroupMemberLayout {
    static let sideInset: CGFloat = 12
    static let spacing: CGFloat = 4
    static let cornerRadius: CGFloat = 24
    static let headerTopInset: CGFloat = 2

    static func cardWidth(in viewport: CGFloat) -> CGFloat {
        max(0, viewport - 2 * sideInset)
    }
}

enum GroupMemberSelection {
    static func initialViewportTarget(_ selected: AccountID?, available: [AccountID]) -> AccountID? {
        guard let selected, available.contains(selected) else { return nil }
        return selected
    }

    static func reconciled(_ selected: AccountID?, available: [AccountID]) -> AccountID? {
        if let selected, available.contains(selected) { return selected }
        return available.first
    }

    static func moved(_ selected: AccountID?, by offset: Int, available: [AccountID]) -> AccountID? {
        guard !available.isEmpty else { return nil }
        let index = selected.flatMap { available.firstIndex(of: $0) } ?? 0
        return available[min(max(0, index + offset), available.count - 1)]
    }
}
