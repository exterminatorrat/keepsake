import Foundation

struct RouteSegment: Equatable, Identifiable, Sendable {
    let samples: [RouteSample]

    var id: UUID {
        samples[0].id
    }
}

enum CoverageGapReason: Equatable, Sendable {
    case missingFix
    case lowAccuracy
}

struct CoverageGap: Equatable, Sendable {
    let start: Date
    let end: Date
    let reason: CoverageGapReason

    var duration: TimeInterval {
        end.timeIntervalSince(start)
    }
}

struct SegmentedRoute: Equatable, Sendable {
    let segments: [RouteSegment]
    let gaps: [CoverageGap]
}

struct RouteViewport: Equatable, Sendable {
    let centerLatitude: Double
    let centerLongitude: Double
    let latitudeSpan: Double
    let longitudeSpan: Double
}

enum RouteHistory {
    static let maximumGap: TimeInterval = 5 * 60
    static let maximumRouteAccuracy: Double = 100

    static func samples(on day: Date, in calendar: Calendar, from samples: [RouteSample]) -> [RouteSample] {
        guard let interval = calendar.dateInterval(of: .day, for: day) else {
            return []
        }

        return samples
            .filter { $0.observedAt >= interval.start && $0.observedAt < interval.end }
            .sorted { $0.observedAt < $1.observedAt }
    }

    static func retainedSamples(_ samples: [RouteSample], after cutoff: Date) -> [RouteSample] {
        samples.filter { $0.observedAt >= cutoff }
    }

    static func viewport(for samples: [RouteSample]) -> RouteViewport? {
        let validSamples = samples.filter(\.isValid)
        guard let minimumLatitude = validSamples.map(\.latitude).min(),
              let maximumLatitude = validSamples.map(\.latitude).max() else {
            return nil
        }

        let longitudes = validSamples.map { sample in
            let longitude = sample.longitude.truncatingRemainder(dividingBy: 360)
            return longitude < 0 ? longitude + 360 : longitude
        }.sorted()

        var largestGap = 0.0
        var largestGapEndIndex = 0
        for index in longitudes.indices {
            let nextIndex = (index + 1) % longitudes.count
            let nextLongitude = longitudes[nextIndex] + (nextIndex == 0 ? 360 : 0)
            let gap = nextLongitude - longitudes[index]
            if gap > largestGap {
                largestGap = gap
                largestGapEndIndex = index
            }
        }

        let longitudeArc = 360 - largestGap
        let arcStart = longitudes[(largestGapEndIndex + 1) % longitudes.count]
        let centerLongitude = (arcStart + longitudeArc / 2 + 180)
            .truncatingRemainder(dividingBy: 360) - 180
        let latitudeRange = maximumLatitude - minimumLatitude

        return RouteViewport(
            centerLatitude: min(90, max(-90, (minimumLatitude + maximumLatitude) / 2)),
            centerLongitude: centerLongitude,
            latitudeSpan: min(180, max(0.01, latitudeRange * 1.5)),
            longitudeSpan: min(360, max(0.01, longitudeArc * 1.5))
        )
    }

    static func availableDays(in calendar: Calendar, from samples: [RouteSample]) -> [Date] {
        Array(Set(samples.map { calendar.startOfDay(for: $0.observedAt) })).sorted(by: >)
    }

    static func segments(
        from samples: [RouteSample],
        maximumGap: TimeInterval = maximumGap,
        maximumAccuracy: Double = maximumRouteAccuracy
    ) -> SegmentedRoute {
        let ordered = samples.sorted { $0.observedAt < $1.observedAt }
        var segments: [RouteSegment] = []
        var gaps: [CoverageGap] = []
        var current: [RouteSample] = []
        var previousReliable: RouteSample?
        var lowAccuracyStart: Date?
        var lowAccuracyEnd: Date?
        var recordingID: UUID?

        func finishSegment() {
            if !current.isEmpty {
                segments.append(RouteSegment(samples: current))
                current.removeAll(keepingCapacity: true)
            }
        }

        func finishLowAccuracyGap(through end: Date? = nil) {
            guard let start = lowAccuracyStart, let last = lowAccuracyEnd else {
                return
            }

            gaps.append(CoverageGap(start: start, end: end ?? last, reason: .lowAccuracy))
            lowAccuracyStart = nil
            lowAccuracyEnd = nil
        }

        for sample in ordered {
            if let recordingID, recordingID != sample.recordingID {
                finishSegment()
                finishLowAccuracyGap()
                previousReliable = nil
            }
            recordingID = sample.recordingID

            guard sample.isValid else {
                finishSegment()
                finishLowAccuracyGap()
                previousReliable = nil
                continue
            }

            guard sample.horizontalAccuracy <= maximumAccuracy else {
                if lowAccuracyStart == nil {
                    lowAccuracyStart = previousReliable?.observedAt ?? sample.observedAt
                }

                lowAccuracyEnd = sample.observedAt
                finishSegment()
                continue
            }

            if let previous = previousReliable {
                if lowAccuracyStart != nil {
                    finishLowAccuracyGap(through: sample.observedAt)
                    finishSegment()
                } else {
                    let interval = sample.observedAt.timeIntervalSince(previous.observedAt)
                    if interval > maximumGap {
                        gaps.append(CoverageGap(start: previous.observedAt, end: sample.observedAt, reason: .missingFix))
                        finishSegment()
                    } else if interval <= 0 {
                        finishSegment()
                    }
                }
            } else if lowAccuracyStart != nil {
                finishLowAccuracyGap(through: sample.observedAt)
            }

            current.append(sample)
            previousReliable = sample
        }

        finishSegment()
        finishLowAccuracyGap()
        return SegmentedRoute(segments: segments, gaps: gaps)
    }
}
