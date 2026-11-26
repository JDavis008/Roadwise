import Foundation
import SQLite3

/// Place search with no signal, over the per-state SQLite FTS5 indexes in `places/`
/// (built by tools/ios-offline/make_places.py): towns, named places, streets and addresses.
final class OfflineSearch: @unchecked Sendable {
    private let dir: URL
    private var dbs: [OpaquePointer] = []
    private var opened = false
    private let lock = NSLock()

    /// Nearby categories (Category.label) -> `kind` values in the index.
    static let kinds: [String: Set<String>] = [
        "Gas": ["gas station"], "Food": ["restaurant", "fast food"], "Coffee": ["cafe"], "Parking": ["parking"],
        "EV charging": ["EV charging"], "Groceries": ["supermarket", "grocery", "convenience store"],
        "Hotels": ["hotel", "motel"], "Hospitals": ["hospital"],
    ]

    init(dir: URL) { self.dir = dir }

    deinit { closeAll() }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        closeAll()
    }

    var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        openIfNeeded()
        return dbs.isEmpty
    }

    func search(_ query: String, near: Coord?, limit: Int = 15) -> [Place] {
        let tokens = query.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.prefix(6)
        guard !tokens.isEmpty else { return [] }
        let match = tokens.map { "\"\($0)\"*" }.joined(separator: " ")
        let first = tokens.joined(separator: " ")
        var scored: [(Place, Double)] = []
        rows("SELECT name, address, kind, emoji, lat, lon, boost, bm25(places, 4.0, 1.0) FROM places WHERE places MATCH ? ORDER BY bm25(places, 4.0, 1.0) LIMIT 150",
             [match]) { p, boost, bm25 in
            var score = -bm25 * (1 + boost / 3)
            if p.name.lowercased().hasPrefix(first) { score += 4 }
            if let near { score -= log10(1 + Geo.dist(near, p.coordinate) / 1000) * 2.5 }
            scored.append((p, score))
        }
        return Array(Self.dedupe(scored.sorted { $0.1 > $1.1 }.map(\.0)).prefix(limit))
    }

    /// Places of a nearby category, closest first.
    func nearby(label: String, emoji: String, near: Coord, radiusKm: Double = 25) -> [Place] {
        guard let kinds = Self.kinds[label], !kinds.isEmpty else { return [] }
        let dLat = radiusKm / 111.0, dLon = radiusKm / (111.0 * max(0.2, cos(near.latitude * .pi / 180)))
        let marks = kinds.map { _ in "?" }.joined(separator: ",")
        var found: [Place] = []
        rows("SELECT name, address, kind, emoji, lat, lon, boost, 0 FROM places WHERE kind IN (\(marks)) AND lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
             Array(kinds) + [near.latitude - dLat, near.latitude + dLat, near.longitude - dLon, near.longitude + dLon]) { p, _, _ in
            var p = p
            p.category = label
            p.emoji = emoji
            found.append(p)
        }
        return Array(Self.dedupe(found.sorted { Geo.dist(near, $0.coordinate) < Geo.dist(near, $1.coordinate) }).prefix(40))
    }

    /// The closest named thing to a point (for dropped pins), within about 200 m.
    func reverse(_ c: Coord) -> Place? {
        let d = 0.002
        var best: (Place, Double)?
        rows("SELECT name, address, kind, emoji, lat, lon, boost, 0 FROM places WHERE lat BETWEEN ? AND ? AND lon BETWEEN ? AND ?",
             [c.latitude - d, c.latitude + d, c.longitude - d * 1.4, c.longitude + d * 1.4]) { p, _, _ in
            let dist = Geo.dist(c, p.coordinate)
            if dist < 200, best == nil || dist < best!.1 { best = (p, dist) }
        }
        return best?.0
    }

    // MARK: SQLite

    private func rows(_ sql: String, _ args: [Any], _ each: (Place, Double, Double) -> Void) {
        lock.lock(); defer { lock.unlock() }
        openIfNeeded()
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for db in dbs {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }
            for (i, a) in args.enumerated() {
                let idx = Int32(i + 1)
                if let d = a as? Double { sqlite3_bind_double(stmt, idx, d) }
                else { sqlite3_bind_text(stmt, idx, String(describing: a), -1, transient) }
            }
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ i: Int32) -> String { sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" }
                let kind = text(2)
                let emoji = text(3)
                let p = Place(name: text(0), address: text(1), lat: sqlite3_column_double(stmt, 4), lon: sqlite3_column_double(stmt, 5),
                              category: kind, emoji: emoji.isEmpty ? nil : emoji)
                each(p, sqlite3_column_double(stmt, 6), sqlite3_column_double(stmt, 7))
            }
        }
    }

    private func openIfNeeded() {
        guard !opened else { return }
        opened = true
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for f in files where f.pathExtension == "sqlite" {
            var db: OpaquePointer?
            if sqlite3_open_v2(f.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db { dbs.append(db) }
            else if let db { sqlite3_close(db) }
        }
    }

    private func closeAll() {
        dbs.forEach { sqlite3_close($0) }
        dbs = []
        opened = false
    }

    private static func dedupe(_ list: [Place]) -> [Place] {
        var seen = Set<String>()
        return list.filter { seen.insert("\($0.name.lowercased())|\(Int($0.lat * 500))|\(Int($0.lon * 500))").inserted }
    }
}
