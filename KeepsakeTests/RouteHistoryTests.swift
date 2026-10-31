import Foundation
import Testing
@testable import Keepsake

struct RouteHistoryTests {
    @Test func dayGroupingUsesTheInjectedLocalTimeZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: -7 * 60 * 60)!
        let beforeLocalMidnight = makeSample(seconds: "2026-05-02T06:30:00Z")
        let localMidnight = makeSample(seconds: "2026-05-02T07:00:00Z")
        let afterLocalMidnight = makeSample(seconds: "2026-05-02T07:30:00Z")
        let mayFirst = calendar.date(from: DateComponents(year: 2026, month: 5, day: 1))!
        let maySecond = calendar.date(from: DateComponents(year: 2026, month: 5, day: 2))!

        #expect(RouteHistory.samples(on: mayFirst, in: calendar, from: [afterLocalMidnight, localMidnight, beforeLocalMidnight]) == [beforeLocalMidnight])
        #expect(RouteHistory.samples(on: maySecond, in: calendar, from: [beforeLocalMidnight, localMidnight, afterLocalMidnight]) == [localMidnight, afterLocalMidnight])
    }

    @Test func routeSegmentsSplitAtLongGapsLowAccuracyAndRecordingBoundaries() {
        let firstSession = UUID()
        let secondSession = UUID()
        let samples = [
            makeSample(sessionID: firstSession, seconds: 0),
            makeSample(sessionID: firstSession, seconds: 60),
            makeSample(sessionID: firstSession, seconds: 400),
            makeSample(sessionID: secondSession, seconds: 420),
            makeSample(sessionID: secondSession, seconds: 450, accuracy: 150),
            makeSample(sessionID: secondSession, seconds: 480)
        ]

        let route = RouteHistory.segments(from: samples)

        #expect(route.segments.map { $0.samples.map(\.observedAt.timeIntervalSince1970) } == [[0, 60], [400], [420], [480]])
        #expect(route.gaps.map(\.reason) == [.missingFix, .lowAccuracy])
    }

    @Test func shortGapsStayConnectedAndAStationaryFixRemainsStored() {
        let sessionID = UUID()
        let samples = [
            makeSample(sessionID: sessionID, seconds: 0),
            makeSample(sessionID: sessionID, seconds: 300, stationary: true)
        ]

        let route = RouteHistory.segments(from: samples)

        #expect(route.segments.count == 1)
        #expect(route.segments[0].samples.map(\.isStationary) == [false, true])
        #expect(route.gaps.isEmpty)
    }

    @Test func lowAccuracyCoverageIsReportedWithoutReliablePointsAndAcrossRuns() {
        let sessionID = UUID()
        let lowAccuracyOnly = [
            makeSample(sessionID: sessionID, seconds: 0, accuracy: 150),
            makeSample(sessionID: sessionID, seconds: 60, accuracy: 150)
        ]

        let noReliableRoute = RouteHistory.segments(from: lowAccuracyOnly)

        #expect(noReliableRoute.segments.isEmpty)
        #expect(noReliableRoute.gaps == [CoverageGap(start: lowAccuracyOnly[0].observedAt, end: lowAccuracyOnly[1].observedAt, reason: .lowAccuracy)])

        let reliableRun = [
            makeSample(sessionID: sessionID, seconds: 120),
            makeSample(sessionID: sessionID, seconds: 180, accuracy: 150),
            makeSample(sessionID: sessionID, seconds: 240, accuracy: 150),
            makeSample(sessionID: sessionID, seconds: 300)
        ]
        let interruptedRoute = RouteHistory.segments(from: reliableRun)

        #expect(interruptedRoute.gaps == [CoverageGap(start: reliableRun[0].observedAt, end: reliableRun[3].observedAt, reason: .lowAccuracy)])
    }

    @Test func retainedHistoryKeepsTheCutoffAndDropsOlderSamples() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let cutoff = now.addingTimeInterval(-90 * 24 * 60 * 60)
        let expired = makeSample(seconds: cutoff.timeIntervalSince1970 - 1)
        let boundary = makeSample(seconds: cutoff.timeIntervalSince1970)
        let recent = makeSample(seconds: now.timeIntervalSince1970 - 86_400)

        #expect(RouteHistory.retainedSamples([expired, boundary, recent], after: cutoff) == [boundary, recent])
    }

    @Test func routeViewportReturnsNilForEmptyHistory() {
        #expect(RouteHistory.viewport(for: []) == nil)
    }

    @Test func routeViewportKeepsSinglePointCenteredAtValidCoordinates() throws {
        let viewport = try #require(RouteHistory.viewport(for: [
            makeSample(seconds: 0, latitude: 90, longitude: 180)
        ]))

        #expect(viewport.centerLatitude == 90)
        #expect(viewport.centerLongitude == -180)
        #expect(viewport.latitudeSpan == 0.01)
        #expect(viewport.longitudeSpan == 0.01)
    }

    @Test func routeViewportPadsOrdinaryBounds() throws {
        let viewport = try #require(RouteHistory.viewport(for: [
            makeSample(seconds: 0, latitude: 10, longitude: -122),
            makeSample(seconds: 60, latitude: 14, longitude: -120)
        ]))

        #expect(viewport.centerLatitude == 12)
        #expect(viewport.centerLongitude == -121)
        #expect(viewport.latitudeSpan == 6)
        #expect(viewport.longitudeSpan == 3)
    }

    @Test func routeViewportUsesTheShortArcAcrossTheAntimeridian() throws {
        let viewport = try #require(RouteHistory.viewport(for: [
            makeSample(seconds: 0, latitude: 10, longitude: 179.9),
            makeSample(seconds: 60, latitude: 20, longitude: -179.9)
        ]))

        #expect(viewport.centerLatitude == 15)
        #expect(abs(abs(viewport.centerLongitude) - 180) < 0.000_001)
        #expect(viewport.latitudeSpan == 15)
        #expect(abs(viewport.longitudeSpan - 0.3) < 0.000_001)
    }

    @Test func routeViewportBoundsGlobalSpansAndCenter() throws {
        let viewport = try #require(RouteHistory.viewport(for: [
            makeSample(seconds: 0, latitude: -90, longitude: 0),
            makeSample(seconds: 60, latitude: 90, longitude: 120),
            makeSample(seconds: 120, latitude: 0, longitude: -120)
        ]))

        #expect((-90...90).contains(viewport.centerLatitude))
        #expect((-180..<180).contains(viewport.centerLongitude))
        #expect(viewport.latitudeSpan == 180)
        #expect(viewport.longitudeSpan == 360)
    }
}

private func makeSample(
    sessionID: UUID = UUID(),
    seconds: TimeInterval,
    latitude: Double? = nil,
    longitude: Double = -122.0090,
    accuracy: Double = 8,
    stationary: Bool = false
) -> RouteSample {
    RouteSample(
        recordingID: sessionID,
        observedAt: Date(timeIntervalSince1970: seconds),
        latitude: latitude ?? 37.3349 + seconds / 1_000_000,
        longitude: longitude,
        horizontalAccuracy: accuracy,
        speed: stationary ? 0 : 1.2,
        course: 90,
        isStationary: stationary
    )
}

private func makeSample(seconds: String) -> RouteSample {
    let date = ISO8601DateFormatter().date(from: seconds)!
    return RouteSample(
        recordingID: UUID(),
        observedAt: date,
        latitude: 37.3349,
        longitude: -122.0090,
        horizontalAccuracy: 8,
        isStationary: false
    )
}
