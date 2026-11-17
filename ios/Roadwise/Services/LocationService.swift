import Foundation
import CoreLocation

struct Fix {
    var coordinate: Coord
    var accuracy: Double
    var speed: Double      // m/s
    var heading: Double    // degrees, course when moving, compass when still
    var time: Date
}

/// GPS + compass. Keeps running in the background while navigating (UIBackgroundModes: location).
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var fix: Fix?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    /// Called for every new fix (real or simulated).
    var onFix: ((Fix) -> Void)?
    /// While true, real GPS updates are ignored (preview drive).
    var simulating = false

    private let manager = CLLocationManager()
    private var compass: Double?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.activityType = .automotiveNavigation
        manager.headingFilter = 3
        authorization = manager.authorizationStatus
    }

    func start() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
    }

    /// Navigation mode: best accuracy and keep going when the screen is off.
    func setNavigating(_ on: Bool) {
        manager.desiredAccuracy = on ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyBest
        manager.pausesLocationUpdatesAutomatically = !on
        if manager.authorizationStatus == .authorizedAlways || manager.authorizationStatus == .authorizedWhenInUse {
            manager.allowsBackgroundLocationUpdates = on
            manager.showsBackgroundLocationIndicator = on
        }
    }

    func inject(_ f: Fix) {
        fix = f
        onFix?(f)
    }

    private func handle(_ loc: CLLocation) {
        guard !simulating, loc.horizontalAccuracy >= 0 else { return }
        var speed = loc.speed >= 0 ? loc.speed : 0
        if loc.speed < 0, let prev = fix {
            let dt = max(0.5, loc.timestamp.timeIntervalSince(prev.time))
            speed = min(60, Geo.dist(prev.coordinate, loc.coordinate) / dt)
        }
        let course = loc.course >= 0 && speed > 1.5 ? loc.course : (compass ?? fix?.heading ?? 0)
        inject(Fix(coordinate: loc.coordinate, accuracy: loc.horizontalAccuracy, speed: speed, heading: course, time: loc.timestamp))
    }

    // MARK: CLLocationManagerDelegate (called on the main thread because the manager was created there)

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.handle(last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        let h = newHeading.trueHeading >= 0 ? newHeading.trueHeading : newHeading.magneticHeading
        Task { @MainActor in
            self.compass = h
            if var f = self.fix, f.speed < 1.5, !self.simulating {
                f.heading = h
                self.fix = f
            }
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.manager.startUpdatingLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
