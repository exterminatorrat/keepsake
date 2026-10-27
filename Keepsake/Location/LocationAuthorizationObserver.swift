import CoreLocation
import Foundation

@MainActor
final class LocationAuthorizationObserver: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private(set) var servicesEnabled = false
    var onChange: (() -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        refreshServicesEnabled()
    }

    var capabilities: LocationCapabilities {
        LocationCapabilities(
            servicesEnabled: servicesEnabled,
            authorization: LocationAuthorization(manager.authorizationStatus),
            fullAccuracy: manager.accuracyAuthorization == .fullAccuracy
        )
    }

    func refreshServicesEnabled() {
        Task.detached { [weak self] in
            let enabled = CLLocationManager.locationServicesEnabled()
            await self?.setServicesEnabled(enabled)
        }
    }

    func requestWhenInUseAuthorization() {
        manager.requestWhenInUseAuthorization()
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor [weak self] in
            self?.onChange?()
        }
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
