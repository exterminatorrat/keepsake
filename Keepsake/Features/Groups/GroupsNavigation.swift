import Foundation

struct GroupsNavigation: Equatable, Sendable {
    enum SheetDetent: Equatable, Sendable {
        case collapsed, expanded
    }

    private(set) var accountID: AccountID
    private(set) var accountGeneration: UUID?
    private(set) var selectedMemberID: AccountID?
    private(set) var tab: AppTab
    private(set) var presentation: GroupPresentation
    private(set) var isSelectorOpen: Bool
    private(set) var detent: SheetDetent

    init(
        accountID: AccountID,
        accountGeneration: UUID? = nil,
        tab: AppTab = .groups,
        presentation: GroupPresentation = .groupCollapsed,
        isSelectorOpen: Bool = false
    ) {
        self.accountID = accountID
        self.accountGeneration = accountGeneration
        self.selectedMemberID = presentation == .memberCollapsed || presentation == .memberExpanded ? accountID : nil
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
        selectedMemberID = nil
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

    mutating func showMemberCard(memberID: AccountID? = nil) {
        guard isShowingGroupSheet else { return }
        selectedMemberID = memberID ?? accountID
        presentation = .memberCollapsed
        isSelectorOpen = false
    }

    mutating func selectMember(_ memberID: AccountID?, available: [AccountID]) {
        guard let memberID, available.contains(memberID) else { return }
        selectedMemberID = memberID
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
            selectedMemberID = nil
            presentation = detentPresentation
            isSelectorOpen = false
            return
        }
    }

    @discardableResult
    mutating func reset(for newAccountID: AccountID, generation: UUID? = nil) -> Bool {
        guard newAccountID != accountID || generation != accountGeneration else { return false }
        accountID = newAccountID
        accountGeneration = generation
        selectedMemberID = nil
        tab = .groups
        detent = .collapsed
        presentation = .groupCollapsed
        isSelectorOpen = false
        return true
    }
}
