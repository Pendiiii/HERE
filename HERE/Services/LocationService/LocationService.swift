import CoreLocation
import Observation

@MainActor
@Observable
final class LocationService: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    var coordinate: CLLocationCoordinate2D?
    var authorizationStatus: CLAuthorizationStatus

    override init() {
        authorizationStatus = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    func requestWhenInUseAuthorization() {
        if authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorizationStatus = manager.authorizationStatus
        if authorizationStatus == .authorizedAlways || authorizationStatus == .authorizedWhenInUse {
            manager.requestLocation()
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        coordinate = locations.last?.coordinate
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        coordinate = nil
    }
}
