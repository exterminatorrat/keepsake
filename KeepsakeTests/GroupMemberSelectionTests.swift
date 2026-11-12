import Foundation
import Testing
@testable import Keepsake

struct GroupMemberSelectionTests {
    private let first = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)
    private let second = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!)

    @Test func productionPresentationUsesTheRealSelfIdentity() {
        let member = GroupMemberPresentation.selfMember(account: AccountIdentity(id: first, email: nil))
        #expect(member.id == first)
        #expect(member.isSelf)
        #expect(member.displayName == "You")
    }

    @Test func soloSelectionDoesNotInventNeighborsOrWrap() {
        #expect(GroupMemberSelection.moved(first, by: -1, available: [first]) == first)
        #expect(GroupMemberSelection.moved(first, by: 1, available: [first]) == first)
        #expect(GroupMemberSelection.moved(first, by: 1, available: []) == nil)
    }

    @Test func stableSelectionSurvivesReorderingAndDropsMissingMembers() {
        #expect(GroupMemberSelection.reconciled(second, available: [second, first]) == second)
        #expect(GroupMemberSelection.reconciled(second, available: [first]) == first)
        #expect(GroupMemberSelection.reconciled(second, available: []) == nil)
    }

    @Test func multiMemberPagingStopsAtBothEnds() {
        #expect(GroupMemberSelection.moved(first, by: -1, available: [first, second]) == first)
        #expect(GroupMemberSelection.moved(first, by: 1, available: [first, second]) == second)
        #expect(GroupMemberSelection.moved(second, by: 1, available: [first, second]) == second)
    }

    @Test func rowPagerAndDetailShareNavigationSelection() {
        var navigation = GroupsNavigation(accountID: first)
        navigation.showMemberCard(memberID: first)
        navigation.selectMember(second, available: [first, second])
        navigation.expandMemberCard()
        #expect(navigation.presentation == .memberExpanded)
        #expect(navigation.selectedMemberID == second)
        navigation.collapseMemberCard()
        #expect(navigation.selectedMemberID == second)
        navigation.selectMember(AccountID(rawValue: UUID()), available: [first, second])
        #expect(navigation.selectedMemberID == second)
    }

    @Test func newGenerationOfTheSameAccountResetsMemberAndSurfaceState() {
        let generation = UUID()
        var navigation = GroupsNavigation(accountID: first, accountGeneration: generation)
        navigation.showMemberCard(memberID: first)
        navigation.expandMemberCard()
        #expect(!navigation.reset(for: first, generation: generation))
        #expect(navigation.reset(for: first, generation: UUID()))
        #expect(navigation.selectedMemberID == nil)
        #expect(navigation.presentation == .groupCollapsed)
        #expect(!navigation.isSelectorOpen)
    }

    @Test(arguments: [CGFloat(0), 20, 288, 402, 768])
    func narrowEvenGuttersFitAvailableWidth(viewport: CGFloat) {
        let width = GroupMemberLayout.cardWidth(in: viewport)
        #expect(width >= 0)
        #expect(width <= max(0, viewport))
        #expect(GroupMemberLayout.sideInset >= 8 && GroupMemberLayout.sideInset <= 12)
        #expect(GroupMemberLayout.spacing < GroupMemberLayout.sideInset)
        #expect(GroupMemberLayout.headerTopInset >= 0 && GroupMemberLayout.headerTopInset < 10)
    }
}
