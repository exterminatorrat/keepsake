import Foundation

struct GroupsNavigation: Equatable, Sendable {
    enum SheetDetent: Equatable, Sendable {
        case collapsed, expanded
    }

    private(set) var accountID: AccountID
    private(set) var tab: AppTab
    private(set) var presentation: GroupPresentation
    private(set) var isSelectorOpen: Bool
    private(set) var detent: SheetDetent

    init(
        accountID: AccountID,
        tab: AppTab = .groups,
        presentation: GroupPresentation = .groupCollapsed,
        isSelectorOpen: Bool = false
    ) {
        self.accountID = accountID
        self.tab = tab
        self.presentation = presentation
        self.isSelectorOpen = isSelectorOpen
        self.detent = presentation == .groupExpanded ? .expanded : .collapsed
    }

    var isShowingGroupSheet: Bool {
        presentation == .groupCollapsed || presentation == .groupExpanded
    }

    private var detentPresentation: GroupPresentation {
        detent == .expanded ? .groupExpanded : .groupCollapsed
    }

    mutating func select(tab newTab: AppTab) {
        guard newTab != tab else { return }
        tab = newTab
        presentation = detentPresentation
        isSelectorOpen = false
    }

    mutating func setSheetDetent(_ newDetent: SheetDetent) {
        guard isShowingGroupSheet else { return }
        detent = newDetent
        presentation = detentPresentation
        isSelectorOpen = false
    }

    mutating func toggleSheetDetent() {
        guard isShowingGroupSheet else { return }
        setSheetDetent(detent == .collapsed ? .expanded : .collapsed)
    }

    mutating func toggleSelector() {
        guard isShowingGroupSheet else { return }
        isSelectorOpen.toggle()
    }

    mutating func closeSelector() {
        isSelectorOpen = false
    }

    mutating func showMemberCard() {
        guard isShowingGroupSheet else { return }
        presentation = .memberCollapsed
        isSelectorOpen = false
    }

    mutating func expandMemberCard() {
        guard presentation == .memberCollapsed else { return }
        presentation = .memberExpanded
    }

    mutating func collapseMemberCard() {
        guard presentation == .memberExpanded else { return }
        presentation = .memberCollapsed
    }

    mutating func showSettings() {
        presentation = .settings
        isSelectorOpen = false
    }

    mutating func showAccount() {
        guard presentation == .settings else { return }
        presentation = .account
    }

    mutating func showGroupSummary() {
        guard presentation == .settings else { return }
        presentation = .groupSummary
    }

    mutating func goBack() {
        switch presentation {
        case .account, .groupSummary:
            presentation = .settings
        case .settings, .memberCollapsed, .memberExpanded:
            presentation = detentPresentation
        case .groupCollapsed, .groupExpanded:
            break
        }
        isSelectorOpen = false
    }

    mutating func sync(with state: GroupScreenState) {
        guard case .ready = state else {
            presentation = detentPresentation
            isSelectorOpen = false
            return
        }
    }

    @discardableResult
    mutating func reset(for newAccountID: AccountID) -> Bool {
        guard newAccountID != accountID else { return false }
        accountID = newAccountID
        tab = .groups
        detent = .collapsed
        presentation = .groupCollapsed
        isSelectorOpen = false
        return true
    }
}
