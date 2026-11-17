import Foundation
import CoreLocation

typealias Coord = CLLocationCoordinate2D

/// Small geometry helpers (meters, degrees). Mirrors core/Geo.kt in the Android app.
enum Geo {
    static let earthRadius = 6_371_008.8
    private static let rad = Double.pi / 180

    static func dist(_ a: Coord, _ b: Coord) -> Double {
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let s = pow(sin(dLat / 2), 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * pow(sin(dLon / 2), 2)
        return 2 * earthRadius * asin(min(1, sqrt(s)))
    }

    static func bearing(_ a: Coord, _ b: Coord) -> Double {
        let y = sin((b.longitude - a.longitude) * rad) * cos(b.latitude * rad)
        let x = cos(a.latitude * rad) * sin(b.latitude * rad) - sin(a.latitude * rad) * cos(b.latitude * rad) * cos((b.longitude - a.longitude) * rad)
        return (atan2(y, x) / rad + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Projects p onto segment a-b. Returns the fraction along the segment and the distance from it in meters.
    static func project(_ p: Coord, _ a: Coord, _ b: Coord) -> (t: Double, d: Double) {
        let k = cos(a.latitude * rad) * earthRadius * rad, m = earthRadius * rad
        let bx = (b.longitude - a.longitude) * k, by = (b.latitude - a.latitude) * m
        let px = (p.longitude - a.longitude) * k, py = (p.latitude - a.latitude) * m
        let len = bx * bx + by * by
        let t = len > 0 ? max(0, min(1, (px * bx + py * by) / len)) : 0
        return (t, hypot(px - t * bx, py - t * by))
    }

    static func lerp(_ a: Coord, _ b: Coord, _ t: Double) -> Coord {
        Coord(latitude: a.latitude + (b.latitude - a.latitude) * t, longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    static func angleDiff(_ a: Double, _ b: Double) -> Double {
        let d = abs(a - b).truncatingRemainder(dividingBy: 360)
        return d > 180 ? 360 - d : d
    }

    static func cumulative(_ pts: [Coord]) -> [Double] {
        var c = [Double](repeating: 0, count: pts.count)
        if pts.count > 1 { for i in 1..<pts.count { c[i] = c[i - 1] + dist(pts[i - 1], pts[i]) } }
        return c
    }

    static func decodePolyline(_ s: String, precision: Int = 6) -> [Coord] {
        let bytes = Array(s.utf8)
        let factor = pow(10.0, Double(precision))
        var out: [Coord] = []
        var i = 0, lat = 0, lon = 0
        func next() -> Int? {
            var result = 0, shift = 0
            while i < bytes.count {
                let b = Int(bytes[i]) - 63
                i += 1
                result |= (b & 0x1f) << shift
                shift += 5
                if b < 0x20 { return (result & 1) != 0 ? ~(result >> 1) : (result >> 1) }
            }
            return nil
        }
        while i < bytes.count {
            guard let dLat = next(), let dLon = next() else { break }
            lat += dLat; lon += dLon
            out.append(Coord(latitude: Double(lat) / factor, longitude: Double(lon) / factor))
        }
        return out
    }

    static func encodePolyline(_ pts: [Coord], precision: Int = 6) -> String {
        let factor = pow(10.0, Double(precision))
        var out = ""
        var pLat = 0, pLon = 0
        func enc(_ v: Int) {
            var x = v < 0 ? ~(v << 1) : (v << 1)
            while x >= 0x20 {
                out.unicodeScalars.append(UnicodeScalar(UInt8((0x20 | (x & 0x1f)) + 63)))
                x >>= 5
            }
            out.unicodeScalars.append(UnicodeScalar(UInt8(x + 63)))
        }
        for p in pts {
            let la = Int((p.latitude * factor).rounded()), lo = Int((p.longitude * factor).rounded())
            enc(la - pLat); enc(lo - pLon)
            pLat = la; pLon = lo
        }
        return out
    }

    /// Bounding box around c, `meters` in each direction: (minLon, minLat, maxLon, maxLat).
    static func bbox(around c: Coord, meters: Double) -> (Double, Double, Double, Double) {
        let dLat = meters / 111_320, dLon = meters / (111_320 * max(0.01, cos(c.latitude * rad)))
        return (c.longitude - dLon, c.latitude - dLat, c.longitude + dLon, c.latitude + dLat)
    }
}

/// Formatting for distances, speeds and times.
enum Units {
    static func distance(_ m: Double, imperial: Bool) -> String {
        if imperial {
            let ft = m * 3.28084
            if ft < 1000 { return "\(max(10, Int((ft / 10).rounded()) * 10)) ft" }
            let mi = m / 1609.344
            return mi < 10 ? String(format: "%.1f mi", mi) : "\(Int(mi.rounded())) mi"
        }
        if m < 1000 { return "\(max(10, Int((m / 10).rounded()) * 10)) m" }
        let km = m / 1000
        return km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
    }

    static func spoken(_ m: Double, imperial: Bool) -> String {
        if imperial {
            let ft = m * 3.28084
            if ft < 900 { return "\(max(50, ft < 300 ? Int((ft / 50).rounded()) * 50 : Int((ft / 100).rounded()) * 100)) feet" }
            let mi = m / 1609.344
            if mi < 0.35 { return "a quarter mile" }
            if mi < 0.6 { return "half a mile" }
            if mi < 0.85 { return "three quarters of a mile" }
            if mi < 1.15 { return "1 mile" }
            let v = mi < 10 ? (mi * 2).rounded() / 2 : mi.rounded()
            return "\(clean(v)) miles"
        }
        if m < 950 { return "\(max(50, m < 300 ? Int((m / 50).rounded()) * 50 : Int((m / 100).rounded()) * 100)) meters" }
        let km = m / 1000
        let v = km < 10 ? (km * 2).rounded() / 2 : km.rounded()
        return "\(clean(v)) kilometer\(v == 1 ? "" : "s")"
    }

    private static func clean(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }

    static func duration(_ s: Double) -> String {
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(max(1, m)) min" }
        let h = m / 60, mm = m % 60
        return mm == 0 ? "\(h) hr" : "\(h) hr \(mm) min"
    }

    static func speed(_ mps: Double, imperial: Bool) -> Int { Int((imperial ? mps * 2.23694 : mps * 3.6).rounded()) }
    static func limit(_ kmh: Int, imperial: Bool) -> Int { imperial ? Int((Double(kmh) / 1.609344 / 5).rounded()) * 5 : kmh }
    static func speedUnit(_ imperial: Bool) -> String { imperial ? "mph" : "km/h" }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: date)
    }
}
