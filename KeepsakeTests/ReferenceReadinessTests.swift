import Foundation
import Testing

@Suite("Reference capture readiness")
struct ReferenceReadinessTests {
    @Test func appearanceAndStableFramesAreRequired() {
        var state = ReferenceReadiness(map: .notRequired)
        state.recordLayout(stable: true)
        state.recordLayout(stable: true)
        #expect(!state.isReady)
        state.appeared = true
        #expect(state.isReady)
        state.recordLayout(stable: false)
        #expect(!state.isReady)
    }

    @Test func elapsedFramesDoNotProveMapReadiness() {
        var state = ReferenceReadiness(appeared: true, map: .pending)
        for _ in 0..<120 { state.recordLayout(stable: true) }
        #expect(!state.isReady)
        state.renderingFinished(fullyRendered: false)
        #expect(!state.isReady)
        state.renderingFinished(fullyRendered: true)
        #expect(!state.isReady)
        state.recordLayout(stable: true)
        state.recordLayout(stable: true)
        #expect(state.isReady)
        state.renderingStarted()
        #expect(!state.isReady)
    }

    @Test(arguments: [ReferenceReadiness.MapState.unavailable, .unobservable, .pending])
    func incompleteMapCannotPass(map: ReferenceReadiness.MapState) {
        let state = ReferenceReadiness(appeared: true, stableLayoutFrames: 2, map: map)
        #expect(!state.isReady)
    }

    @Test func deadlineIsFailureEvenWithPreviouslyRenderedMap() {
        let state = ReferenceReadiness(
            appeared: true, stableLayoutFrames: 2, map: .fullyRendered, deadlineExpired: true
        )
        #expect(!state.isReady)
    }

    @Test(arguments: [0, 1, 2])
    func memberReadinessRequiresTheExpectedVisibleCard(index: Int) {
        let ids = [
            UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            UUID(uuidString: "00000000-0000-0000-0000-000000000004")!
        ]
        let viewport = CGRect(x: 0, y: 0, width: 402, height: 190)
        let cards = ids.enumerated().map { offset, id in
            ReferenceMemberViewport.Card(id: id, frame: CGRect(x: 12 + CGFloat(offset) * 382, y: 0, width: 378, height: 190))
        }
        let stale = ReferenceMemberViewport(expectedID: ids[index], viewport: viewport, cards: cards)
        #expect(stale.centeredID == ids[0])
        #expect(stale.isReady == (index == 0))
        let settled = ReferenceMemberViewport(
            expectedID: ids[index], viewport: viewport,
            cards: cards.map { .init(id: $0.id, frame: $0.frame.offsetBy(dx: -CGFloat(index) * 382, dy: 0)) }
        )
        #expect(settled.centeredID == ids[index])
        #expect(settled.isReady)
    }

    @Test func memberViewportFailsClosedForMissingAmbiguousAndInvalidGeometry() {
        let id = UUID()
        let other = UUID()
        let viewport = CGRect(x: 0, y: 0, width: 402, height: 190)
        let card = ReferenceMemberViewport.Card(id: id, frame: CGRect(x: 12, y: 0, width: 378, height: 190))
        let invalid = [
            ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: []),
            ReferenceMemberViewport(expectedID: other, viewport: viewport, cards: [card]),
            ReferenceMemberViewport(expectedID: id, viewport: .zero, cards: [card]),
            ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [card, card]),
            ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [card, .init(id: other, frame: card.frame)]),
            ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [.init(id: id, frame: card.frame.offsetBy(dx: 2, dy: 0))]),
            ReferenceMemberViewport(expectedID: id, viewport: CGRect(x: 0, y: 0, width: 402, height: 100), cards: [card]),
            ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [.init(id: id, frame: CGRect(x: CGFloat.nan, y: 0, width: 378, height: 190))])
        ]
        for snapshot in invalid {
            #expect(!snapshot.isReady)
        }
    }

    @Test func memberMovementResetsStableFramesAndDeadlineStillFailsClosed() {
        let id = UUID()
        let viewport = CGRect(x: 0, y: 0, width: 402, height: 190)
        let card = ReferenceMemberViewport.Card(id: id, frame: CGRect(x: 12, y: 0, width: 378, height: 190))
        let centered = ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [card])
        let moving = ReferenceMemberViewport(expectedID: id, viewport: viewport, cards: [.init(id: id, frame: card.frame.offsetBy(dx: 1, dy: 0))])
        var state = ReferenceReadiness(appeared: true, map: .notRequired)
        for _ in 0..<3 { state.recordLayout(stable: true, memberViewport: centered) }
        #expect(state.isReady)
        state.recordLayout(stable: true, memberViewport: moving)
        #expect(state.stableLayoutFrames == 0)
        #expect(!state.isReady)
        for _ in 0..<3 { state.recordLayout(stable: true, memberViewport: centered) }
        #expect(state.isReady)
        state.recordLayout(stable: true)
        #expect(!state.isReady)
        #expect(state.memberViewport?.expectedID == id)
        for _ in 0..<3 { state.recordLayout(stable: true, memberViewport: centered) }
        #expect(state.isReady)
        state.deadlineExpired = true
        #expect(!state.isReady)
    }

    @Test func diagnosticScrollRequiresCompleteEvidenceWithoutRequiringHealthyScrolling() {
        var scroll = ReferenceMemberScroll()
        #expect(!scroll.isObservable)
        scroll.cardProbeCount = 3
        scroll.ownerCount = 1
        scroll.allCardsShareOwner = true
        scroll.ownerToken = "fixture-owner"
        scroll.bounds = .zero
        scroll.windowFrame = .zero
        scroll.contentSize = .zero
        scroll.contentOffset = .zero
        scroll.contentInset = .init(.zero)
        scroll.adjustedContentInset = .init(.zero)
        scroll.isScrollEnabled = false
        scroll.isTracking = false
        scroll.isDragging = false
        scroll.isDecelerating = false
        #expect(scroll.isObservable)
        var state = ReferenceReadiness(appeared: true, map: .notRequired)
        for _ in 0..<3 { state.recordLayout(stable: true, memberScroll: scroll) }
        #expect(state.isReady)
        state.recordLayout(stable: true)
        #expect(!state.isReady)
        for _ in 0..<3 { state.recordLayout(stable: true, memberScroll: scroll) }
        #expect(state.isReady)
        scroll.ownerCount = 2
        #expect(!scroll.isObservable)
        state.recordLayout(stable: true, memberScroll: scroll)
        #expect(!state.isReady)
        scroll.ownerCount = 1
        scroll.contentOffset = nil
        #expect(!scroll.isObservable)
        scroll.contentOffset = CGPoint(x: CGFloat.nan, y: 0)
        #expect(!scroll.isObservable)
    }

    @Test(arguments: [ReferenceReadiness.MapState.unavailable, .unobservable])
    func terminalMapFailureCannotBeOverwritten(map: ReferenceReadiness.MapState) {
        var state = ReferenceReadiness(appeared: true, stableLayoutFrames: 2, map: map)
        state.renderingStarted()
        state.renderingFinished(fullyRendered: true)
        #expect(state.map == map)
        #expect(!state.isReady)
    }
}
