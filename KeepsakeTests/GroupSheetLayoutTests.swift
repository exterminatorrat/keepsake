import Foundation
import Testing
@testable import Keepsake

@Suite("Reference sheet layout")
struct GroupSheetLayoutTests {
    @Test func referenceViewportHasContentIndependentEnvelopes() {
        #expect(GroupSheetLayout.height(in: 720, pose: .collapsed) == 328)
        #expect(GroupSheetLayout.height(in: 720, pose: .expanded) == 548)
        #expect(GroupSheetLayout.height(in: 720, pose: .selector) == 198)
    }

    @Test(arguments: [CGFloat(0), 120, 240, 480, 720, 1024])
    func detentsFitTheViewport(viewport: CGFloat) {
        let compact = GroupSheetLayout.height(in: viewport, pose: .selector)
        let resting = GroupSheetLayout.height(in: viewport, pose: .collapsed)
        let expanded = GroupSheetLayout.height(in: viewport, pose: .expanded)
        #expect(0 <= compact && compact <= resting && resting <= expanded)
        #expect(expanded <= viewport)
    }

    @Test(arguments: GroupSheetLayout.Pose.allCases)
    func accessibilityUsesScrollableSpaceWithoutCoveringHeader(pose: GroupSheetLayout.Pose) {
        #expect(GroupSheetLayout.height(in: 720, pose: pose, accessibility: true, headerClearance: 192) == 528)
    }

    @Test func selectorSharesBoundedPillWidth() {
        #expect(GroupSheetLayout.selectorWidth(in: 370, preferred: 182, accessibility: false) == 182)
        #expect(GroupSheetLayout.selectorWidth(in: 288, preferred: 182, accessibility: false) == 136)
        #expect(GroupSheetLayout.selectorWidth(in: 288, preferred: 364, accessibility: true) == 288)
        #expect(GroupSheetLayout.selectorWidth(in: 0, preferred: 182, accessibility: false) == 0)
    }
}
