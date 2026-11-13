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

    @Test func multiMemberPagingWrapsAtBothEnds() {
        #expect(GroupMemberSelection.moved(first, by: -1, available: [first, second]) == second)
        #expect(GroupMemberSelection.moved(first, by: 1, available: [first, second]) == second)
        #expect(GroupMemberSelection.moved(second, by: 1, available: [first, second]) == first)
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
        let didResetSameGeneration = navigation.reset(for: first, generation: generation)
        #expect(!didResetSameGeneration)
        let didResetNewGeneration = navigation.reset(for: first, generation: UUID())
        #expect(didResetNewGeneration)
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

    @Test(arguments: [0, 1, 2])
    func initialViewportTargetsFirstMiddleAndLastCurrentSelections(index: Int) {
        let third = AccountID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!)
        let available = [first, second, third]
        #expect(GroupMemberSelection.initialViewportTarget(available[index], available: available) == available[index])
    }

    @Test func initialViewportDoesNotInventOrResurrectMissingSelections() {
        #expect(GroupMemberSelection.initialViewportTarget(nil, available: [first, second]) == nil)
        #expect(GroupMemberSelection.initialViewportTarget(second, available: [first]) == nil)
        #expect(GroupMemberSelection.initialViewportTarget(first, available: []) == nil)
    }

    @Test func reentryViewportReadsCurrentSelectionMembershipAndAccountLifetime() {
        var navigation = GroupsNavigation(accountID: first)
        navigation.selectMember(first, available: [first, second])
        #expect(GroupMemberSelection.initialViewportTarget(navigation.selectedMemberID, available: [first, second]) == first)
        navigation.selectMember(second, available: [first, second])
        #expect(GroupMemberSelection.initialViewportTarget(navigation.selectedMemberID, available: [second, first]) == second)
        #expect(GroupMemberSelection.initialViewportTarget(navigation.selectedMemberID, available: [first]) == nil)
        let reset = navigation.reset(for: first, generation: UUID())
        #expect(reset)
        #expect(GroupMemberSelection.initialViewportTarget(navigation.selectedMemberID, available: [first, second]) == nil)
        navigation.selectMember(first, available: [first])
        #expect(GroupMemberSelection.initialViewportTarget(navigation.selectedMemberID, available: [first]) == first)
    }

    @Test func cyclicMovementUsesCurrentOrderAndHandlesLargeOrMissingSelections() {
        let third = AccountID(rawValue: UUID())
        let available = [first, second, third]
        #expect(GroupMemberSelection.moved(first, by: -1, available: available) == third)
        #expect(GroupMemberSelection.moved(third, by: 1, available: available) == first)
        #expect(GroupMemberSelection.moved(second, by: -1, available: available) == first)
        #expect(GroupMemberSelection.moved(second, by: 1, available: available) == third)
        #expect(GroupMemberSelection.moved(first, by: -4, available: available) == third)
        #expect(GroupMemberSelection.moved(first, by: 3, available: available) == first)
        #expect(GroupMemberSelection.moved(first, by: 1, available: [third, first, second]) == second)
        #expect(GroupMemberSelection.moved(nil, by: -1, available: available) == first)
        #expect(GroupMemberSelection.moved(third, by: 1, available: [first, second]) == first)
        #expect(GroupMemberSelection.moved(first, by: Int.min, available: [first]) == first)
    }

    @Test(arguments: [CGFloat(-45), 785])
    func edgePullGeometryRequiresIntentionalHorizontalOverscroll(offset: CGFloat) {
        #expect(GroupMemberEdgeSwipe.isOutside(offset: offset, contentWidth: 1142, viewportWidth: 402, leadingInset: 12, trailingInset: 12))
        #expect(!GroupMemberEdgeSwipe.isOutside(offset: -44, contentWidth: 1142, viewportWidth: 402, leadingInset: 12, trailingInset: 12))
        #expect(!GroupMemberEdgeSwipe.isOutside(offset: 784, contentWidth: 1142, viewportWidth: 402, leadingInset: 12, trailingInset: 12))
        #expect(!GroupMemberEdgeSwipe.isOutside(offset: .nan, contentWidth: 1142, viewportWidth: 402, leadingInset: 12, trailingInset: 12))
        #expect(!GroupMemberEdgeSwipe.isOutside(offset: offset, contentWidth: 402, viewportWidth: 402, leadingInset: 12, trailingInset: 12))
    }

    @Test func edgeSwipeWrapsOnlyAfterInteractionAndKeepsTheReleaseIntent() throws {
        let groupID = GroupID(rawValue: UUID())
        var previous = try #require(GroupMemberEdgeSwipe(selection: first, groupID: groupID, members: [first, second]))
        previous.recordOutside(true)
        #expect(previous.target(selection: first, groupID: groupID, members: [first, second]) == nil)
        previous.isInteracting = false
        previous.recordOutside(false)
        #expect(previous.target(selection: first, groupID: groupID, members: [first, second]) == second)
        var next = try #require(GroupMemberEdgeSwipe(selection: second, groupID: groupID, members: [first, second]))
        next.recordOutside(true)
        next.isInteracting = false
        #expect(next.target(selection: second, groupID: groupID, members: [first, second]) == first)
    }

    @Test func edgeSwipeCancelsReturnedPullAndStaleSelectionMembershipOrGroup() throws {
        let groupID = GroupID(rawValue: UUID())
        var swipe = try #require(GroupMemberEdgeSwipe(selection: first, groupID: groupID, members: [first, second]))
        swipe.recordOutside(true)
        swipe.recordOutside(false)
        swipe.isInteracting = false
        #expect(swipe.target(selection: first, groupID: groupID, members: [first, second]) == nil)
        swipe.isInteracting = true
        swipe.recordOutside(true)
        swipe.isInteracting = false
        #expect(swipe.target(selection: second, groupID: groupID, members: [first, second]) == nil)
        #expect(swipe.target(selection: nil, groupID: groupID, members: [first, second]) == nil)
        #expect(swipe.target(selection: first, groupID: groupID, members: [second, first]) == nil)
        #expect(swipe.target(selection: first, groupID: groupID, members: [first]) == nil)
        #expect(swipe.target(selection: first, groupID: GroupID(rawValue: UUID()), members: [first, second]) == nil)
        #expect(GroupMemberEdgeSwipe(selection: nil, groupID: groupID, members: [first, second]) == nil)
        #expect(GroupMemberEdgeSwipe(selection: first, groupID: groupID, members: []) == nil)
        #expect(GroupMemberEdgeSwipe(selection: first, groupID: groupID, members: [first]) == nil)
        #expect(GroupMemberEdgeSwipe(selection: second, groupID: groupID, members: [first, second, AccountID(rawValue: UUID())]) == nil)
    }
}
