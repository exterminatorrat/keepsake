import Foundation

protocol LocalCaptureHistoryReading: Sendable {
    func readPage(
        interval: CapturePageInterval,
        now: Date,
        limit: Int,
        cursor: CapturePageCursor?
    ) async throws -> CapturePage
}

extension RouteStore: LocalCaptureHistoryReading {}
