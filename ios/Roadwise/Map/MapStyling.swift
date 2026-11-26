import MapLibre
import SwiftUI
import UIKit

/// OpenFreeMap styles (the same as the Android app). Downloaded states keep them working offline.
enum MapStyles {
    static let day = URL(string: "https://tiles.openfreemap.org/styles/liberty")!
    static let night = URL(string: "https://tiles.openfreemap.org/styles/dark")!
    static let satelliteTiles = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"

    /// Satellite uses the night style underneath, with its fills hidden (as on Android).
    static func url(dark: Bool, satellite: Bool) -> URL { dark || satellite ? night : day }
}

/// Route lines and satellite imagery drawn on a MapLibre style. Shared by the phone map and CarPlay.
@MainActor
final class MapOverlays {
    private var source: MLNShapeSource?
    private var shapes: [MLNPolylineFeature] = []

    /// Call from `didFinishLoading style`. Re-adds the route lines (a new style drops them).
    func install(on style: MLNStyle, satellite: Bool) {
        if satellite { Self.applySatellite(style) }
        let src = MLNShapeSource(identifier: "rw-routes", shape: nil, options: nil)
        style.addSource(src)
        source = src
        let firstLabels = style.layers.first { $0 is MLNSymbolStyleLayer }
        func add(_ id: String, kind: String, color: UIColor, width: Double, opacity: Double = 1) {
            let l = MLNLineStyleLayer(identifier: id, source: src)
            l.predicate = NSPredicate(format: "kind == %@", kind)
            l.lineColor = NSExpression(forConstantValue: color)
            l.lineWidth = NSExpression(forConstantValue: width)
            l.lineOpacity = NSExpression(forConstantValue: opacity)
            l.lineCap = NSExpression(forConstantValue: "round")
            l.lineJoin = NSExpression(forConstantValue: "round")
            if let firstLabels { style.insertLayer(l, below: firstLabels) } else { style.addLayer(l) }
        }
        add("rw-alt", kind: "alt", color: .systemGray, width: 6, opacity: 0.8)
        add("rw-done", kind: "done", color: .systemGray, width: 8, opacity: 0.85)
        add("rw-main-casing", kind: "main", color: UIColor(red: 0.05, green: 0.28, blue: 0.75, alpha: 1), width: 11)
        add("rw-main", kind: "main", color: .systemBlue, width: 7.5)
        source?.shape = MLNShapeCollectionFeature(shapes: shapes)
    }

    /// Route choices (selected one blue), or while navigating the driven part gray and the rest blue.
    func setRoutes(_ routes: [Route], selected: Int, split: (done: [Coord], rest: [Coord])? = nil) {
        var out: [MLNPolylineFeature] = []
        func line(_ pts: [Coord], _ kind: String) {
            guard pts.count > 1 else { return }
            let f = MLNPolylineFeature(coordinates: pts, count: UInt(pts.count))
            f.attributes = ["kind": kind]
            out.append(f)
        }
        if let split {
            line(split.done, "done")
            line(split.rest, "main")
        } else {
            for (i, r) in routes.enumerated() where i != selected { line(r.points, "alt") }
            if routes.indices.contains(selected) { line(routes[selected].points, "main") }
        }
        shapes = out
        source?.shape = MLNShapeCollectionFeature(shapes: out)
    }

    /// Hybrid view: imagery at the bottom, map fills hidden, roads faint, labels kept.
    static func applySatellite(_ style: MLNStyle) {
        guard style.source(withIdentifier: "rw-sat") == nil else { return }
        let attribution = MLNAttributionInfo(title: NSAttributedString(string: "Imagery © Esri, Maxar, Earthstar Geographics"), url: nil)
        let src = MLNRasterTileSource(identifier: "rw-sat", tileURLTemplates: [MapStyles.satelliteTiles], options: [
            .maximumZoomLevel: 19, .tileSize: 256, .attributionInfos: [attribution],
        ])
        style.addSource(src)
        for l in style.layers where !l.identifier.hasPrefix("rw-") {
            switch l {
            case is MLNFillStyleLayer, is MLNFillExtrusionStyleLayer, is MLNHillshadeStyleLayer, is MLNRasterStyleLayer, is MLNBackgroundStyleLayer:
                l.isVisible = false
            case let line as MLNLineStyleLayer:
                switch line.sourceLayerIdentifier {
                case "transportation": line.lineOpacity = NSExpression(forConstantValue: 0.35)
                case "boundary": break
                default: line.isVisible = false
                }
            case let sym as MLNSymbolStyleLayer:
                sym.textColor = NSExpression(forConstantValue: UIColor.white)
                sym.textHaloColor = NSExpression(forConstantValue: UIColor.black.withAlphaComponent(0.8))
                sym.textHaloWidth = NSExpression(forConstantValue: 1.6)
            default: break
            }
        }
        style.insertLayer(MLNRasterStyleLayer(identifier: "rw-sat", source: src), at: 0)
    }

    /// Blue navigation arrow in a white ring.
    static let puck: UIImage = UIGraphicsImageRenderer(size: CGSize(width: 44, height: 44)).image { ctx in
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

    static func bounds(_ pts: [Coord]) -> MLNCoordinateBounds? {
        guard let f = pts.first else { return nil }
        var s = f.latitude, n = f.latitude, w = f.longitude, e = f.longitude
        for p in pts { s = min(s, p.latitude); n = max(n, p.latitude); w = min(w, p.longitude); e = max(e, p.longitude) }
        return MLNCoordinateBounds(sw: Coord(latitude: s, longitude: w), ne: Coord(latitude: n, longitude: e))
    }
}

/// Our own position marker (so preview drives and road-snapped positions show too).
final class PuckAnnotation: MLNPointAnnotation {}

/// A hazard report on the map.
final class ReportAnnotation: MLNPointAnnotation {
    var report: Report?
}

extension MLNAnnotationView {
    static func puck(_ annotation: MLNAnnotation) -> MLNAnnotationView {
        let v = MLNAnnotationView(annotation: annotation, reuseIdentifier: "puck")
        v.frame = CGRect(x: 0, y: 0, width: 44, height: 44)
        let img = UIImageView(image: MapOverlays.puck)
        img.frame = v.bounds
        v.addSubview(img)
        return v
    }

    static func report(_ annotation: ReportAnnotation) -> MLNAnnotationView {
        let v = MLNAnnotationView(annotation: annotation, reuseIdentifier: nil)
        v.frame = CGRect(x: 0, y: 0, width: 32, height: 32)
        let kind = annotation.report?.kind
        v.backgroundColor = UIColor(kind?.color ?? .orange)
        v.layer.cornerRadius = 16
        v.layer.borderColor = UIColor.white.cgColor
        v.layer.borderWidth = 2
        let label = UILabel(frame: v.bounds)
        label.text = kind?.emoji
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 16)
        v.addSubview(label)
        return v
    }
}
