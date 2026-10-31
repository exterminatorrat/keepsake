import CoreLocation
import Foundation

@MainActor
protocol LocationAuthorizationClient: AnyObject {
    var authorization: LocationAuthorization { get }
    var fullAccuracy: Bool { get }
    var onChange: (() -> Void)? { get set }
    func requestWhenInUseAuthorization()
}

protocol LocationServicesStatusSource: Sendable {
    func servicesEnabled() async -> Bool
}

struct SystemLocationServicesStatusSource: LocationServicesStatusSource {
    func servicesEnabled() async -> Bool {
        await Task.detached {
            CLLocationManager.locationServicesEnabled()
        }.value
    }
}

@MainActor
private final class CoreLocationAuthorizationClient: NSObject, CLLocationManagerDelegate, LocationAuthorizationClient {
    private let manager = CLLocationManager()
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
    }

    var authorization: LocationAuthorization {
        LocationAuthorization(manager.authorizationStatus)
    }

    var fullAccuracy: Bool {
        manager.accuracyAuthorization == .fullAccuracy
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onChange?()
        }
    }
}

@MainActor
final class LocationAuthorizationObserver: RecorderAuthorizationObservation {
    private let authorizationClient: any LocationAuthorizationClient
    private let servicesStatusSource: any LocationServicesStatusSource
    private(set) var servicesEnabled = false
    var onChange: (() -> Void)?
    private var servicesRefreshRevision = 0
    private var servicesRefreshTask: Task<Void, Never>?

    convenience init() {
        self.init(
            authorizationClient: CoreLocationAuthorizationClient(),
            servicesStatusSource: SystemLocationServicesStatusSource()
        )
    }

    init(
        authorizationClient: any LocationAuthorizationClient,
        servicesStatusSource: any LocationServicesStatusSource
    ) {
        self.authorizationClient = authorizationClient
        self.servicesStatusSource = servicesStatusSource
        authorizationClient.onChange = { [weak self] in
            self?.refreshServicesEnabled()
            self?.onChange?()
        }
        refreshServicesEnabled()
    }

    var capabilities: LocationCapabilities {
        LocationCapabilities(
            servicesEnabled: servicesEnabled,
            authorization: authorizationClient.authorization,
            fullAccuracy: authorizationClient.fullAccuracy
        )
    }

    func refreshServicesEnabled() {
        servicesRefreshRevision += 1
        guard servicesRefreshTask == nil else {
            return
        }

        servicesRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            await self.refreshServicesUntilCurrent()
        }
    }

    func requestWhenInUseAuthorization() {
        authorizationClient.requestWhenInUseAuthorization()
    }

    private func refreshServicesUntilCurrent() async {
        while !Task.isCancelled {
            let revision = servicesRefreshRevision
            let enabled = await servicesStatusSource.servicesEnabled()
            guard !Task.isCancelled else {
                break
            }
            guard revision == servicesRefreshRevision else {
                continue
            }

            servicesRefreshTask = nil
            setServicesEnabled(enabled)
            return
        }

        servicesRefreshTask = nil
    }

    private func setServicesEnabled(_ enabled: Bool) {
        guard servicesEnabled != enabled else {
            return
        }

        servicesEnabled = enabled
        onChange?()
    }
}

private extension LocationAuthorization {
    init(_ status: CLAuthorizationStatus) {
        switch status {
        case .notDetermined:
            self = .notDetermined
        case .authorizedWhenInUse:
            self = .whileInUse
        case .authorizedAlways:
            self = .always
        case .denied:
            self = .denied
        case .restricted:
            self = .restricted
        @unknown default:
            self = .restricted
        }
    }
}
