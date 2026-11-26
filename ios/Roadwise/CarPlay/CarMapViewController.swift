import MapLibre
import UIKit

/// The map on the CarPlay screen. Navigation apps draw their own map in the CarPlay window,
/// under the CPMapTemplate's buttons and guidance card. Same MapLibre/OpenFreeMap map as the
/// phone, so downloaded states work offline in the car too.
@MainActor
final class CarMapViewController: UIViewController, MLNMapViewDelegate {
    private(set) var map: MLNMapView!
    /// Keep the map centered on the car as it moves.
    var following = true
    private var satellite = false
    private let overlays = MapOverlays()
    private let me = PuckAnnotation()
    private var meShown = false
    private var heading: Double = 0
    private var pin: MLNPointAnnotation?
    private var routes: [Route] = []
    private var selected = 0

    override func viewDidLoad() {
        super.viewDidLoad()
        map = MLNMapView(frame: view.bounds, styleURL: style())
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        map.showsUserLocation = false
        map.compassView.compassVisibility = .hidden
        map.logoView.isHidden = true
        map.attributionButton.isHidden = true
        view.addSubview(map)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if previous?.userInterfaceStyle != traitCollection.userInterfaceStyle { map?.styleURL = style() }
    }

    private func style() -> URL { MapStyles.url(dark: traitCollection.userInterfaceStyle == .dark, satellite: satellite) }

    func setSatellite(_ on: Bool) {
        guard on != satellite else { return }
        satellite = on
        map?.styleURL = style()
    }

    func center(on c: Coord, distance: Double = 2500) {
        map.setCamera(MLNMapCamera(lookingAtCenter: c, acrossDistance: distance, pitch: 0, heading: 0), animated: false)
    }

    /// New GPS fix (or preview-drive fix). While navigating the map turns with the road.
    func update(fix: Fix, nav: NavEngine?) {
        let pos = nav?.state.snapped ?? fix.coordinate
        heading = nav?.state.bearing ?? fix.heading
        me.coordinate = pos
        if !meShown { map.addAnnotation(me); meShown = true }
        rotatePuck()
        guard following else { return }
        if let nav, !nav.state.arrived {
            let distance: Double = fix.speed > 25 ? 1400 : fix.speed > 15 ? 1000 : 650
            map.setCamera(MLNMapCamera(lookingAtCenter: pos, acrossDistance: distance, pitch: 45, heading: heading),
                          withDuration: 0.9, animationTimingFunction: CAMediaTimingFunction(name: .linear))
        } else {
            map.setCenter(pos, zoomLevel: max(map.zoomLevel, 13), direction: 0, animated: true)
        }
    }

    func showRoutes(_ routes: [Route], selected: Int, destination: Coord?) {
        self.routes = routes
        self.selected = selected
        overlays.setRoutes(routes, selected: selected)
        if let pin { map.removeAnnotation(pin) }
        pin = nil
        if let destination {
            let p = MLNPointAnnotation()
            p.coordinate = destination
            map.addAnnotation(p)
            pin = p
        }
    }

    func clearRoutes() { showRoutes([], selected: 0, destination: nil) }

    /// Fit the routes inside the part of the screen the trip-preview card doesn't cover.
    func fit(_ routes: [Route]) {
        var pts: [Coord] = []
        for r in routes { for (i, p) in r.points.enumerated() where i % 5 == 0 || i == r.points.count - 1 { pts.append(p) } }
        guard let b = MapOverlays.bounds(pts) else { return }
        following = false
        let s = view.safeAreaInsets
        map.setVisibleCoordinateBounds(b, edgePadding: UIEdgeInsets(top: s.top + 30, left: s.left + 30, bottom: s.bottom + 30, right: s.right + 30),
                                       animated: true, completionHandler: nil)
    }

    func zoom(by factor: Double) {
        following = false
        map.setZoomLevel(map.zoomLevel - log2(factor), animated: true)
    }

    /// Panning from the car's pan buttons: a quarter screen per press.
    func pan(dx: CGFloat, dy: CGFloat) {
        following = false
        let size = map.bounds.size
        let target = CGPoint(x: size.width / 2 + dx * size.width / 4, y: size.height / 2 + dy * size.height / 4)
        map.setCenter(map.convert(target, toCoordinateFrom: map), animated: true)
    }

    private func rotatePuck() {
        guard let v = map.view(for: me) else { return }
        v.transform = CGAffineTransform(rotationAngle: CGFloat((heading - map.direction) * .pi / 180))
    }

    // MARK: MLNMapViewDelegate

    nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
        MainActor.assumeIsolated {
            overlays.install(on: style, satellite: satellite)
            overlays.setRoutes(routes, selected: selected)
        }
    }

    nonisolated func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
        MainActor.assumeIsolated {
            annotation is PuckAnnotation ? (mapView.dequeueReusableAnnotationView(withIdentifier: "puck") ?? .puck(annotation)) : nil
        }
    }

    nonisolated func mapViewRegionIsChanging(_ mapView: MLNMapView) {
        MainActor.assumeIsolated { rotatePuck() }
    }

    nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
        MainActor.assumeIsolated { rotatePuck() }
    }
}
