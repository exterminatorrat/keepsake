import Foundation
import Testing

@testable import Keepsake

struct GroupsNavigationTests {
    private let account = AccountIdentity(id: AccountID(rawValue: UUID()), email: nil)

    @Test func startsOnTheCollapsedGroupSheet() {
        let navigation = GroupsNavigation(accountID: account.id)

        #expect(navigation.tab == .groups)
        #expect(navigation.presentation == .groupCollapsed)
        #expect(navigation.detent == .collapsed)
        #expect(navigation.isSelectorOpen == false)
        #expect(navigation.isShowingGroupSheet)
    }

    @Test func sheetDetentTogglesAndSurvivesSettings() {
        var navigation = GroupsNavigation(accountID: account.id)

        navigation.toggleSheetDetent()
        #expect(navigation.detent == .expanded)
        #expect(navigation.presentation == .groupExpanded)

        navigation.showSettings()
        #expect(navigation.presentation == .settings)

        navigation.goBack()
        #expect(navigation.presentation == .groupExpanded)
        #expect(navigation.detent == .expanded)

        navigation.setSheetDetent(.collapsed)
        #expect(navigation.presentation == .groupCollapsed)
    }

    @Test func selectorOnlyOpensOnTheSheetAndClosesWhenLeaving() {
        var navigation = GroupsNavigation(accountID: account.id)
        #expect(navigation.isSelectorOpen == false)

        navigation.toggleSelector()
        #expect(navigation.isSelectorOpen)

        navigation.toggleSelector()
        #expect(navigation.isSelectorOpen == false)

        navigation.toggleSelector()
        navigation.showSettings()
        #expect(navigation.presentation == .settings)
        #expect(navigation.isSelectorOpen == false)

        navigation.showAccount()
        #expect(navigation.presentation == .account)

        navigation.toggleSelector()
        #expect(navigation.isSelectorOpen == false)

        navigation.setSheetDetent(.expanded)
        #expect(navigation.detent == .collapsed)
    }

    @Test func memberCardExpandsAndReturnsToTheSheet() {
        var navigation = GroupsNavigation(accountID: account.id, presentation: .groupExpanded)
        #expect(navigation.detent == .expanded)

        navigation.showMemberCard()
        #expect(navigation.presentation == .memberCollapsed)

        navigation.expandMemberCard()
        #expect(navigation.presentation == .memberExpanded)

        navigation.collapseMemberCard()
        #expect(navigation.presentation == .memberCollapsed)

        navigation.goBack()
        #expect(navigation.presentation == .groupExpanded)
        #expect(navigation.isShowingGroupSheet)
    }

    @Test func memberTransitionsStayOrdered() {
        var navigation = GroupsNavigation(accountID: account.id)

        navigation.expandMemberCard()
        #expect(navigation.presentation == .groupCollapsed)

        navigation.collapseMemberCard()
        #expect(navigation.presentation == .groupCollapsed)

        navigation.showMemberCard()
        #expect(navigation.presentation == .memberCollapsed)

        navigation.showSettings()
        #expect(navigation.presentation == .settings)

        navigation.showGroupSummary()
        #expect(navigation.presentation == .groupSummary)

        navigation.goBack()
        #expect(navigation.presentation == .settings)

        navigation.goBack()
        #expect(navigation.presentation == .groupCollapsed)
    }

    @Test func settingsStacksThroughAccountAndGroupSummary() {
        var navigation = GroupsNavigation(accountID: account.id)
        navigation.toggleSheetDetent()

        navigation.showSettings()
        #expect(navigation.presentation == .settings)

        navigation.showAccount()
        #expect(navigation.presentation == .account)

        navigation.goBack()
        #expect(navigation.presentation == .settings)

        navigation.showGroupSummary()
        #expect(navigation.presentation == .groupSummary)

        navigation.goBack()
        #expect(navigation.presentation == .settings)

        navigation.goBack()
        #expect(navigation.presentation == .groupExpanded)
    }

    @Test func tabSelectionDismissesOverlaysAndKeepsTheDetent() {
        var navigation = GroupsNavigation(accountID: account.id)
        navigation.toggleSheetDetent()
        navigation.showSettings()

        navigation.select(tab: .explore)
        #expect(navigation.tab == .explore)
        #expect(navigation.presentation == .groupExpanded)
        #expect(navigation.isSelectorOpen == false)

        navigation.select(tab: .camera)
        navigation.select(tab: .groups)
        #expect(navigation.tab == .groups)
        #expect(navigation.presentation == .groupExpanded)

        navigation.select(tab: .groups)
        #expect(navigation.tab == .groups)
    }

    @Test func nonReadyStateReturnsToTheSheet() {
        var navigation = GroupsNavigation(accountID: account.id, presentation: .account)
        navigation.sync(with: .noGroup)
        #expect(navigation.presentation == .groupCollapsed)

        navigation.select(tab: .friends)
        navigation.sync(with: .failed(message: "Offline", offline: true))
        #expect(navigation.presentation == .groupCollapsed)
        #expect(navigation.tab == .friends)

        navigation.select(tab: .groups)
        navigation.sync(with: .ready(SoloGroup(id: GroupID(rawValue: UUID()), ownerID: account.id, name: "Yunnan Trip", createdAt: .now), offline: false))
        #expect(navigation.presentation == .groupCollapsed)
    }

    @Test func accountChangeResetsLocalState() {
        var navigation = GroupsNavigation(accountID: account.id, presentation: .account)
        navigation.select(tab: .memories)

        let resetForTheSameAccount = navigation.reset(for: account.id)
        #expect(resetForTheSameAccount == false)
        #expect(navigation.tab == .memories)
        #expect(navigation.presentation == .groupCollapsed)

        let otherAccount = AccountIdentity(id: AccountID(rawValue: UUID()), email: "person@example.com")
        let resetForANewAccount = navigation.reset(for: otherAccount.id)
        #expect(resetForANewAccount)
        #expect(navigation.accountID == otherAccount.id)
        #expect(navigation.tab == .groups)
        #expect(navigation.presentation == .groupCollapsed)
        #expect(navigation.detent == .collapsed)
        #expect(navigation.isSelectorOpen == false)
    }

    @Test func injectedInitialPresentationIsHonored() {
        let navigation = GroupsNavigation(
            accountID: account.id,
            presentation: .groupExpanded,
            isSelectorOpen: true
        )

        #expect(navigation.presentation == .groupExpanded)
        #expect(navigation.detent == .expanded)
        #expect(navigation.isSelectorOpen)
    }
}
