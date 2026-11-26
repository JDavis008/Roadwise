import MapKit
import UIKit

/// The map on the CarPlay screen. Navigation apps draw their own map in the CarPlay window,
/// under the CPMapTemplate's buttons and guidance card.
@MainActor
final class CarMapViewController: UIViewController, MKMapViewDelegate {
    let map = MKMapView()
    /// Keep the map centered on the car as it moves.
    var following = true
    private let me = MKPointAnnotation()
    private var meShown = false
    private var heading: Double = 0
    private var pin: MKPointAnnotation?

    override func viewDidLoad() {
        super.viewDidLoad()
        map.frame = view.bounds
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        map.delegate = self
        map.showsCompass = false
        map.showsUserLocation = false   // our own puck, so preview drives and snapped positions show too
        map.isPitchEnabled = true
        view.addSubview(map)
    }

    func setSatellite(_ on: Bool) { map.mapType = on ? .hybrid : .standard }

    func center(on c: Coord, distance: Double = 2500) {
        map.setCamera(MKMapCamera(lookingAtCenter: c, fromDistance: distance, pitch: 0, heading: 0), animated: false)
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
            map.setCamera(MKMapCamera(lookingAtCenter: pos, fromDistance: distance, pitch: 45, heading: heading), animated: true)
        } else {
            let distance = map.camera.pitch > 1 ? 2500 : max(400, min(map.camera.centerCoordinateDistance, 60_000))
            map.setCamera(MKMapCamera(lookingAtCenter: pos, fromDistance: distance, pitch: 0, heading: 0), animated: true)
        }
    }

    func showRoutes(_ routes: [Route], selected: Int, destination: Coord?) {
        map.removeOverlays(map.overlays)
        for (i, r) in routes.enumerated() where i != selected {
            let line = MKPolyline(coordinates: r.points, count: r.points.count)
            line.title = "alt"
            map.addOverlay(line, level: .aboveRoads)
        }
        if routes.indices.contains(selected) {
            let r = routes[selected]
            let line = MKPolyline(coordinates: r.points, count: r.points.count)
            line.title = "main"
            map.addOverlay(line, level: .aboveRoads)
        }
        if let pin { map.removeAnnotation(pin) }
        pin = nil
        if let destination {
            let p = MKPointAnnotation()
            p.coordinate = destination
            map.addAnnotation(p)
            pin = p
        }
    }

    func clearRoutes() {
        map.removeOverlays(map.overlays)
        if let pin { map.removeAnnotation(pin) }
        pin = nil
    }

    /// Fit the routes inside the part of the screen the trip-preview card doesn't cover.
    func fit(_ routes: [Route]) {
        var rect = MKMapRect.null
        for r in routes {
            for (i, p) in r.points.enumerated() where i % 5 == 0 || i == r.points.count - 1 {
                let mp = MKMapPoint(p)
                rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
            }
        }
        guard !rect.isNull else { return }
        following = false
        let s = view.safeAreaInsets
        map.setVisibleMapRect(rect, edgePadding: UIEdgeInsets(top: s.top + 30, left: s.left + 30, bottom: s.bottom + 30, right: s.right + 30), animated: true)
    }

    func zoom(by factor: Double) {
        following = false
        let cam = map.camera.copy() as! MKMapCamera
        cam.centerCoordinateDistance = max(150, min(cam.centerCoordinateDistance * factor, 20_000_000))
        map.setCamera(cam, animated: true)
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
        v.transform = CGAffineTransform(rotationAngle: CGFloat((heading - map.camera.heading) * .pi / 180))
    }

    // MARK: MKMapViewDelegate

    nonisolated func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        MainActor.assumeIsolated {
            guard let line = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
            let r = MKPolylineRenderer(polyline: line)
            let main = line.title == "main"
            r.strokeColor = main ? UIColor.systemBlue : UIColor.systemGray.withAlphaComponent(0.8)
            r.lineWidth = main ? 9 : 6
            r.lineCap = .round
            r.lineJoin = .round
            return r
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
        MainActor.assumeIsolated {
            if annotation === me {
                let v = mapView.dequeueReusableAnnotationView(withIdentifier: "me") ?? MKAnnotationView(annotation: annotation, reuseIdentifier: "me")
                v.annotation = annotation
                v.image = Self.puck
                v.zPriority = .max
                v.collisionMode = .circle
                return v
            }
            let v = mapView.dequeueReusableAnnotationView(withIdentifier: "pin") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "pin")
            v.annotation = annotation
            v.markerTintColor = .systemRed
            v.glyphImage = UIImage(systemName: "flag.checkered")
            return v
        }
    }

    nonisolated func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
        MainActor.assumeIsolated { rotatePuck() }
    }

    /// Blue navigation arrow in a white ring.
    private static let puck: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { ctx in
        let c = ctx.cgContext
        c.setShadow(offset: .zero, blur: 4, color: UIColor.black.withAlphaComponent(0.4).cgColor)
        UIColor.white.setFill()
        c.fillEllipse(in: CGRect(x: 4, y: 4, width: 36, height: 36))
        c.setShadow(offset: .zero, blur: 0, color: nil)
        UIColor.systemBlue.setFill()
        c.fillEllipse(in: CGRect(x: 7, y: 7, width: 30, height: 30))
        let arrow = UIBezierPath()
        arrow.move(to: CGPoint(x: 22, y: 11))
        arrow.addLine(to: CGPoint(x: 31, y: 31))
        arrow.addLine(to: CGPoint(x: 22, y: 26))
        arrow.addLine(to: CGPoint(x: 13, y: 31))
        arrow.close()
        UIColor.white.setFill()
        arrow.fill()
    }
}
