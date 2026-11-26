import MapLibre
import SwiftUI
import UIKit

/// The phone's map: MapLibre with OpenFreeMap tiles, which keep working offline in downloaded
/// states (Settings > Offline maps). Shows routes, the destination, reports and our own puck,
/// and carries out AppModel's camera commands.
struct RoadwiseMapView: UIViewRepresentable {
    @ObservedObject var app: AppModel
    var dark: Bool
    var satellite: Bool
    var onReport: (Report) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(app: app) }

    func makeUIView(context: Context) -> MLNMapView {
        let c = context.coordinator
        let map = MLNMapView(frame: .zero, styleURL: MapStyles.url(dark: dark, satellite: satellite))
        map.delegate = c
        map.showsUserLocation = false
        map.compassViewPosition = .bottomLeft
        map.compassViewMargins = CGPoint(x: 16, y: 150)
        map.logoViewPosition = .bottomLeft
        map.attributionButtonPosition = .bottomLeft
        map.logoViewMargins = CGPoint(x: 8, y: 8)
        map.attributionButtonMargins = CGPoint(x: 96, y: 8)
        if let f = app.location.fix { map.setCenter(f.coordinate, zoomLevel: 15, animated: false); c.centeredOnce = true }
        else if let m = app.mapCenter { map.setCenter(m, zoomLevel: 13, animated: false) }
        else { map.setCenter(Coord(latitude: 39.5, longitude: -98.35), zoomLevel: 3, animated: false) }
        let press = UILongPressGestureRecognizer(target: c, action: #selector(Coordinator.longPress(_:)))
        press.minimumPressDuration = 0.5
        map.addGestureRecognizer(press)
        c.map = map
        c.styleKey = "\(dark)-\(satellite)"
        c.lastCommand = app.cameraCommand?.id
        return map
    }

    func updateUIView(_ map: MLNMapView, context: Context) {
        let c = context.coordinator
        c.onReport = onReport
        c.satellite = satellite
        let key = "\(dark)-\(satellite)"
        if key != c.styleKey {
            c.styleKey = key
            map.styleURL = MapStyles.url(dark: dark, satellite: satellite)
        }
        c.sync()
    }

    @MainActor
    final class Coordinator: NSObject, MLNMapViewDelegate {
        let app: AppModel
        weak var map: MLNMapView?
        var styleKey = ""
        var satellite = false
        var centeredOnce = false
        var lastCommand: UUID?
        var onReport: (Report) -> Void = { _ in }
        private let overlays = MapOverlays()
        private let puck = PuckAnnotation()
        private var puckShown = false
        private var heading: Double = 0
        private var pin: MLNPointAnnotation?
        private var pinKey = ""
        private var reportPins: [String: ReportAnnotation] = [:]
        private var routeKey = ""

        init(app: AppModel) { self.app = app }

        /// Bring the map in line with the app state (called on every SwiftUI update).
        func sync() {
            guard let map else { return }
            // Position puck
            if let f = app.location.fix {
                puck.coordinate = app.nav?.state.snapped ?? f.coordinate
                heading = app.nav?.state.bearing ?? f.heading
                if !puckShown { map.addAnnotation(puck); puckShown = true }
                rotatePuck()
                if !centeredOnce && app.cameraCommand == nil {
                    centeredOnce = true
                    map.setCenter(f.coordinate, zoomLevel: 15, animated: true)
                }
            }
            // Routes
            if let n = app.nav, let snapped = n.state.snapped, n.route.points.count > 1 {
                let pts = n.route.points
                let i = max(0, min(n.progressSegment, pts.count - 2))
                overlays.setRoutes([], selected: 0, split: (Array(pts[0...i]) + [snapped], [snapped] + Array(pts[(i + 1)...])))
                routeKey = "nav"
            } else {
                let key = app.routes.map { $0.id.uuidString }.joined() + "|\(app.selected)"
                if key != routeKey {
                    routeKey = key
                    overlays.setRoutes(app.routes, selected: app.selected)
                }
            }
            // Destination pin
            let pk = app.place.map { "\($0.name)|\($0.lat)|\($0.lon)" } ?? ""
            if pk != pinKey {
                pinKey = pk
                if let pin { map.removeAnnotation(pin) }
                pin = nil
                if let p = app.place {
                    let a = MLNPointAnnotation()
                    a.coordinate = p.coordinate
                    a.title = p.name
                    map.addAnnotation(a)
                    pin = a
                }
            }
            // Reports
            let current = Dictionary(app.reports.reports.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            for (id, a) in reportPins where current[id] == nil { map.removeAnnotation(a); reportPins[id] = nil }
            for (id, r) in current where reportPins[id] == nil {
                let a = ReportAnnotation()
                a.coordinate = r.coordinate
                a.report = r
                map.addAnnotation(a)
                reportPins[id] = a
            }
            // Camera
            if let cmd = app.cameraCommand, cmd.id != lastCommand {
                lastCommand = cmd.id
                apply(cmd, on: map)
            }
        }

        private func apply(_ cmd: CameraCommand, on map: MLNMapView) {
            switch cmd.target {
            case let .look(center, distance, heading, pitch):
                let cam = MLNMapCamera(lookingAtCenter: center, acrossDistance: distance, pitch: pitch, heading: heading)
                let nav = pitch > 1
                map.contentInset = nav ? UIEdgeInsets(top: map.bounds.height * 0.35, left: 0, bottom: 0, right: 0) : .zero
                map.setCamera(cam, withDuration: nav ? 0.9 : 0.6,
                              animationTimingFunction: CAMediaTimingFunction(name: nav ? .linear : .easeInEaseOut))
            case let .fit(points):
                guard let b = MapOverlays.bounds(points) else { return }
                map.contentInset = .zero
                map.setVisibleCoordinateBounds(b, edgePadding: UIEdgeInsets(top: 80, left: 40, bottom: map.bounds.height * 0.45, right: 40),
                                               animated: true, completionHandler: nil)
            }
        }

        private func rotatePuck() {
            guard let v = map?.view(for: puck) else { return }
            v.transform = CGAffineTransform(rotationAngle: CGFloat((heading - (map?.direction ?? 0)) * .pi / 180))
        }

        @objc func longPress(_ g: UILongPressGestureRecognizer) {
            guard g.state == .began, let map else { return }
            app.dropPin(map.convert(g.location(in: map), toCoordinateFrom: map))
        }

        // MARK: MLNMapViewDelegate

        nonisolated func mapView(_ mapView: MLNMapView, didFinishLoading style: MLNStyle) {
            MainActor.assumeIsolated {
                overlays.install(on: style, satellite: satellite)
                routeKey = ""
                sync()
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionWillChangeWith reason: MLNCameraChangeReason, animated: Bool) {
            MainActor.assumeIsolated {
                let gestures: MLNCameraChangeReason = [.gesturePan, .gesturePinch, .gestureRotate, .gestureZoomIn, .gestureZoomOut, .gestureOneFingerZoom, .gestureTilt]
                if !reason.isDisjoint(with: gestures) && app.following { app.following = false }
            }
        }

        nonisolated func mapViewRegionIsChanging(_ mapView: MLNMapView) {
            MainActor.assumeIsolated { rotatePuck() }
        }

        nonisolated func mapView(_ mapView: MLNMapView, regionDidChangeAnimated animated: Bool) {
            MainActor.assumeIsolated {
                rotatePuck()
                let c = mapView.centerCoordinate
                app.mapCenter = c
                Task { await app.reports.sync(around: c) }
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, viewFor annotation: MLNAnnotation) -> MLNAnnotationView? {
            MainActor.assumeIsolated {
                if annotation is PuckAnnotation {
                    return mapView.dequeueReusableAnnotationView(withIdentifier: "puck") ?? .puck(annotation)
                }
                if let r = annotation as? ReportAnnotation { return .report(r) }
                return nil   // the destination uses the default red pin
            }
        }

        nonisolated func mapView(_ mapView: MLNMapView, annotationCanShowCallout annotation: MLNAnnotation) -> Bool { false }

        nonisolated func mapView(_ mapView: MLNMapView, didSelect annotation: MLNAnnotation) {
            MainActor.assumeIsolated {
                mapView.deselectAnnotation(annotation, animated: false)
                if let r = (annotation as? ReportAnnotation)?.report { onReport(r) }
            }
        }
    }
}
