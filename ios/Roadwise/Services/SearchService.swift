import Foundation

/// Place search: Photon (Komoot, OpenStreetMap data) when there's signal, like search/SearchRepo.kt,
/// and the downloaded state indexes (Offline/OfflineSearch.swift) when there isn't or Photon fails.
enum SearchService {
    static let base = "https://photon.komoot.io"

    static func search(_ query: String, near: Coord?, offline data: OfflineData = .shared) async throws -> [Place] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if let c = coordinates(q) { return [c] }
        if Connectivity.shared.online {
            do {
                let found = try await photon(q, near: near)
                if !found.isEmpty || data.search.isEmpty { return found }
            } catch {
                if data.search.isEmpty { throw error }
            }
        }
        return await Task.detached { data.search.search(q, near: near) }.value
    }

    private static func photon(_ q: String, near: Coord?) async throws -> [Place] {
        var params = ["q": q, "limit": "15", "lang": "en"]
        if let n = near {
            params["lat"] = String(format: "%.5f", n.latitude)
            params["lon"] = String(format: "%.5f", n.longitude)
            params["location_bias_scale"] = "0.3"
        }
        guard let url = Net.url("\(base)/api/", params) else { return [] }
        let json = try await Net.get(url, timeout: 9)
        return dedupe(json.arr("features").compactMap(place))
    }

    static func nearby(_ cat: Category, near: Coord, offline data: OfflineData = .shared) async throws -> [Place] {
        let local: () async -> [Place] = { await Task.detached { data.search.nearby(label: cat.label, emoji: cat.emoji, near: near) }.value }
        guard Connectivity.shared.online else { return await local() }
        do {
            let found = try await photonNearby(cat, near: near)
            if !found.isEmpty { return found }
            return await local()
        } catch {
            let found = await local()
            if found.isEmpty && data.search.isEmpty { throw error }
            return found
        }
    }

    private static func photonNearby(_ cat: Category, near: Coord) async throws -> [Place] {
        func fetch(_ radiusKm: Int) async throws -> [Place] {
            var c = URLComponents(string: "\(base)/reverse")!
            c.queryItems = [
                .init(name: "lat", value: String(near.latitude)), .init(name: "lon", value: String(near.longitude)),
                .init(name: "limit", value: "30"), .init(name: "radius", value: String(radiusKm)), .init(name: "lang", value: "en"),
            ] + cat.tags.map { URLQueryItem(name: "osm_tag", value: $0) }
            let json = try await Net.get(c.url!, timeout: 9)
            return json.arr("features").compactMap(place).filter { !$0.name.isEmpty }.map { var p = $0; p.category = cat.label; p.emoji = cat.emoji; return p }
        }
        var res = try await fetch(10)
        if res.count < 5, let more = try? await fetch(40) { res += more }
        return Array(dedupe(res).sorted { Geo.dist(near, $0.coordinate) < Geo.dist(near, $1.coordinate) }.prefix(40))
    }

    static func reverse(_ p: Coord, offline data: OfflineData = .shared) async -> Place {
        if Connectivity.shared.online,
           let url = Net.url("\(base)/reverse", ["lat": String(p.latitude), "lon": String(p.longitude), "lang": "en", "limit": "1"]),
           let json = try? await Net.get(url, timeout: 6), let first = json.arr("features").first, var pl = place(first) {
            pl.lat = p.latitude
            pl.lon = p.longitude
            return pl
        }
        if var pl = await Task.detached(operation: { data.search.reverse(p) }).value {
            pl.lat = p.latitude
            pl.lon = p.longitude
            return pl
        }
        return Place(name: "Dropped pin", address: String(format: "%.5f, %.5f", p.latitude, p.longitude), lat: p.latitude, lon: p.longitude, category: "pin")
    }

    private static func place(_ f: JSON) -> Place? {
        guard let p = f.obj("properties"), let coords = f.obj("geometry")?["coordinates"] as? [NSNumber], coords.count >= 2 else { return nil }
        let street = [p.str("housenumber"), p.str("street")].filter { !$0.isEmpty }.joined(separator: " ")
        let city = [p.str("city"), p.str("locality"), p.str("county")].first { !$0.isEmpty } ?? ""
        let country = p.str("country") == "United States" ? "" : p.str("country")
        var parts: [String] = []
        for s in [street, city, p.str("state"), country] where !s.isEmpty && !parts.contains(s) { parts.append(s) }
        let name = [p.str("name"), street, city].first { !$0.isEmpty } ?? "Place"
        let value = p.str("osm_value")
        let cat = (["yes", "no", ""].contains(value) ? p.str("osm_key") : value).replacingOccurrences(of: "_", with: " ")
        return Place(name: name, address: parts.joined(separator: ", "), lat: coords[1].doubleValue, lon: coords[0].doubleValue, category: cat)
    }

    private static func dedupe(_ list: [Place]) -> [Place] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0.name.lowercased())|\(Int($0.lat * 1000))|\(Int($0.lon * 1000))").inserted }
    }

    private static func coordinates(_ q: String) -> Place? {
        let parts = q.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, abs(parts[0]) <= 90, abs(parts[1]) <= 180 else { return nil }
        return Place(name: String(format: "%.5f, %.5f", parts[0], parts[1]), address: "Coordinates", lat: parts[0], lon: parts[1], category: "coords")
    }
}
