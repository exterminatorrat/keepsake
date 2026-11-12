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

    @Test(arguments: [ReferenceReadiness.MapState.unavailable, .unobservable])
    func terminalMapFailureCannotBeOverwritten(map: ReferenceReadiness.MapState) {
        var state = ReferenceReadiness(appeared: true, stableLayoutFrames: 2, map: map)
        state.renderingStarted()
        state.renderingFinished(fullyRendered: true)
        #expect(state.map == map)
        #expect(!state.isReady)
    }
}
