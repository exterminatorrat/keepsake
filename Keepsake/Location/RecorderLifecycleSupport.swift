import CoreLocation
import Foundation
import Synchronization

protocol RecorderRepository: Sendable {
    func load() async throws -> RouteLoadResult
    func append(_ sample: RouteSample, now: Date) async throws -> SampleIngestResult
    func clear() async throws
}

struct RouteRepositoryAdapter: RecorderRepository {
    let repository: RouteRepository

    func load() async throws -> RouteLoadResult {
        try await repository.load()
    }

    func append(_ sample: RouteSample, now: Date) async throws -> SampleIngestResult {
        try await repository.append(sample, now: now)
    }

    func clear() async throws {
        try await repository.clear()
    }
}

struct RecorderLocationUpdate {
    let location: CLLocation?
    let stationary: Bool
    let authorizationDenied: Bool
    let authorizationDeniedGlobally: Bool
    let locationUnavailable: Bool

    init(
        location: CLLocation?,
        stationary: Bool,
        authorizationDenied: Bool = false,
        authorizationDeniedGlobally: Bool = false,
        locationUnavailable: Bool = false
    ) {
        self.location = location
        self.stationary = stationary
        self.authorizationDenied = authorizationDenied
        self.authorizationDeniedGlobally = authorizationDeniedGlobally
        self.locationUnavailable = locationUnavailable
    }

    init(_ update: CLLocationUpdate) {
        self.init(
            location: update.location,
            stationary: update.stationary,
            authorizationDenied: update.authorizationDenied,
            authorizationDeniedGlobally: update.authorizationDeniedGlobally,
            locationUnavailable: update.locationUnavailable
        )
    }
}

struct RecorderServiceDiagnostic: Sendable {
    let alwaysAuthorizationDenied: Bool
    let authorizationRequestInProgress: Bool
}

@MainActor
protocol RecorderBackgroundActivityHandle: AnyObject {
    func invalidate()
}

@MainActor
protocol RecorderServiceSessionHandle: AnyObject {
    func collectDiagnostics(_ receive: @escaping @MainActor (RecorderServiceDiagnostic) async -> Void) async throws
    func invalidate()
}

@MainActor
protocol RecorderRuntimePlatform {
    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle
    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle
}

final class RecorderTaskLifetime: Sendable {
    private let tasks = Mutex<[UUID: Task<Void, Never>]>([:])

    func retain(_ task: Task<Void, Never>, for generation: UUID) {
        tasks.withLock { $0[generation] = task }
    }

    func finish(_ generation: UUID) {
        _ = tasks.withLock { $0.removeValue(forKey: generation) }
    }

    func cancelAll() {
        let activeTasks = tasks.withLock { tasks in
            defer { tasks.removeAll() }
            return Array(tasks.values)
        }
        activeTasks.forEach { $0.cancel() }
    }
}

@MainActor
struct CoreLocationRecorderRuntimePlatform: RecorderRuntimePlatform {
    func makeBackgroundActivityHandle() -> any RecorderBackgroundActivityHandle {
        CoreLocationBackgroundActivityHandle()
    }

    func makeServiceSessionHandle() -> any RecorderServiceSessionHandle {
        CoreLocationServiceSessionHandle()
    }
}

@MainActor
private final class CoreLocationBackgroundActivityHandle: RecorderBackgroundActivityHandle {
    private let session = CLBackgroundActivitySession()
    private var isInvalidated = false

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        session.invalidate()
    }
}

@MainActor
private final class CoreLocationServiceSessionHandle: RecorderServiceSessionHandle {
    private let session = CLServiceSession(authorization: .always)
    private var isInvalidated = false

    func collectDiagnostics(
        _ receive: @escaping @MainActor (RecorderServiceDiagnostic) async -> Void
    ) async throws {
        for try await diagnostic in session.diagnostics {
            await receive(RecorderServiceDiagnostic(
                alwaysAuthorizationDenied: diagnostic.alwaysAuthorizationDenied,
                authorizationRequestInProgress: diagnostic.authorizationRequestInProgress
            ))
        }
    }

    func invalidate() {
        guard !isInvalidated else {
            return
        }
        isInvalidated = true
        session.invalidate()
    }
}

@MainActor
protocol RecorderLocationUpdateSource {
    func collect(_ receive: @escaping @MainActor (RecorderLocationUpdate) async -> Bool) async throws
}

@MainActor
struct LiveRecorderLocationUpdateSource: RecorderLocationUpdateSource {
    func collect(_ receive: @escaping @MainActor (RecorderLocationUpdate) async -> Bool) async throws {
        for try await update in CLLocationUpdate.liveUpdates(.default) {
            guard await receive(RecorderLocationUpdate(update)) else {
                return
            }
        }
    }
}

@MainActor
protocol RecorderAuthorizationObservation: AnyObject {
    var capabilities: LocationCapabilities { get }
    var onChange: (() -> Void)? { get set }
    func refreshServicesEnabled()
    func requestWhenInUseAuthorization()
}
