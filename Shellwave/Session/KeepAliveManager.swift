import CoreLocation
import Foundation

/// Hält die App im Hintergrund wach, solange eine Session mit Keep-alive läuft.
/// Dazu laufen grobe Standort-Updates (3 km Genauigkeit, wenig Akku); die Positionen
/// selbst werden verworfen. iOS zeigt dabei den blauen Standort-Hinweis.
@MainActor
final class KeepAliveManager: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var isActive = false
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined

    private let manager = CLLocationManager()

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
        manager.distanceFilter = CLLocationDistanceMax
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        authorization = manager.authorizationStatus
    }

    /// Aufrufen, sobald sich die Menge laufender Keep-alive-Sessions ändert.
    func update(needed: Bool) {
        if needed {
            start()
        } else {
            stop()
        }
    }

    private func start() {
        guard !isActive else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            return
        case .denied, .restricted:
            return
        default:
            break
        }
        manager.allowsBackgroundLocationUpdates = true
        manager.startUpdatingLocation()
        isActive = true
    }

    private func stop() {
        guard isActive else { return }
        manager.stopUpdatingLocation()
        manager.allowsBackgroundLocationUpdates = false
        isActive = false
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            self.onAuthorizationChange?()
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}

    /// Nach einer Freigabe erneut prüfen, ob Keep-alive gebraucht wird.
    var onAuthorizationChange: (() -> Void)?
}
