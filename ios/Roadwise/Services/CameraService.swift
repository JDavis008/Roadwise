import Foundation

struct SpeedCamera {
    let id: String
    let coordinate: Coord
    /// Posted limit at the camera in km/h, 0 = unknown.
    let maxspeedKmh: Int
}

/// Fixed speed cameras mapped in OpenStreetMap (highway=speed_camera), fetched through Overpass.
enum CameraService {
    static let servers = [
        "https://overpass-api.de/api/interpreter",
        "https://overpass.private.coffee/api/interpreter",
        "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
    ]

    /// Cameras inside the route's bounding box. Very long trips are skipped rather than overloading Overpass.
    static func cameras(near points: [Coord]) async -> [SpeedCamera] {
        guard let first = points.first else { return [] }
        var minLat = first.latitude, maxLat = first.latitude, minLon = first.longitude, maxLon = first.longitude
        for p in points {
            minLat = min(minLat, p.latitude); maxLat = max(maxLat, p.latitude)
            minLon = min(minLon, p.longitude); maxLon = max(maxLon, p.longitude)
        }
        guard (maxLat - minLat) * (maxLon - minLon) <= 16 else { return [] }
        let query = "[out:json][timeout:20];node[highway=speed_camera](\(minLat - 0.01),\(minLon - 0.01),\(maxLat + 0.01),\(maxLon + 0.01));out 500;"
        for server in servers {
            guard let url = URL(string: server),
                  let json = try? await Net.postForm(url, fields: ["data": query], timeout: 15) else { continue }
            return json.arr("elements").map { e in
                let raw = (e.obj("tags")?["maxspeed"] as? String) ?? ""
                let n = Int(raw.prefix { $0.isNumber }) ?? 0
                let kmh = raw.lowercased().contains("mph") ? Int((Double(n) * 1.609344).rounded()) : n
                return SpeedCamera(id: "cam-\(e.int("id"))", coordinate: Coord(latitude: e.num("lat"), longitude: e.num("lon")), maxspeedKmh: kmh)
            }
        }
        return []
    }
}
