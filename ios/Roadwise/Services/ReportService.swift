import Foundation

/// Waze-style crowd reports. Always stored on the phone; shared through the Roadwise server when one is set.
/// Same server API as reports/ReportRepo.kt in the Android app.
@MainActor
final class ReportService: ObservableObject {
    @Published private(set) var reports: [Report] = []
    @Published private(set) var status = ""

    private var local: [Report] = []
    private var remote: [Report] = []
    private let settings: AppSettings
    private var syncing = false
    private var lastSync: (Coord, Date)?
    private let storeKey = "reports"

    init(settings: AppSettings) {
        self.settings = settings
        if let data = UserDefaults.standard.data(forKey: storeKey), let saved = try? JSONDecoder().decode([Report].self, from: data) {
            local = saved
        }
        rebuild()
    }

    private func persist() {
        local.removeAll { $0.expires < Date() }
        if let data = try? JSONEncoder().encode(local) { UserDefaults.standard.set(data, forKey: storeKey) }
    }

    private func rebuild() {
        let now = Date()
        let remoteIds = Set(remote.map(\.id))
        reports = (remote + local.filter { $0.serverId == nil || !remoteIds.contains($0.serverId!) })
            .filter { $0.expires > now && !($0.down >= 2 && $0.down > $0.up) }
    }

    func add(_ type: ReportType, at c: Coord, heading: Double) {
        let now = Date()
        local.append(Report(id: "l-\(UUID().uuidString)", serverId: nil, type: type.key, lat: c.latitude, lon: c.longitude,
                            heading: heading, note: "", created: now, expires: now.addingTimeInterval(Double(type.ttlMinutes) * 60),
                            up: 0, down: 0, by: settings.nickname.isEmpty ? "Me" : settings.nickname, mine: true))
        persist(); rebuild()
        Task { await sync(around: c, force: true) }
    }

    func vote(_ r: Report, stillThere: Bool) {
        if !stillThere && (r.mine || r.serverId == nil && r.id.hasPrefix("l-")) {
            local.removeAll { $0.id == r.id || $0.serverId == r.id }
            remote.removeAll { $0.id == r.id && r.mine }
        } else if let i = remote.firstIndex(where: { $0.id == r.id }) {
            if stillThere { remote[i].up += 1 } else { remote[i].down += 1 }
        }
        persist(); rebuild()
        let sid = r.serverId ?? (r.id.hasPrefix("l-") ? nil : r.id)
        guard let server = settings.serverURL, let id = sid, let url = URL(string: "\(server)/api/reports/\(id)/vote") else { return }
        Task {
            _ = try? await Net.post(url, body: ["vote": stillThere ? "up" : "down", "clientId": settings.clientId])
            await sync(around: r.coordinate, force: true)
        }
    }

    /// Pushes reports made on this phone and pulls everyone's reports within ~80 km.
    func sync(around c: Coord, force: Bool = false) async {
        guard let server = settings.serverURL else {
            status = "Reports stay on this phone (no server set)"
            return
        }
        if syncing { return }
        if !force, let last = lastSync, Geo.dist(last.0, c) < 20_000, Date().timeIntervalSince(last.1) < 60 { return }
        syncing = true
        defer { syncing = false; rebuild() }
        do {
            for p in local where p.serverId == nil {
                let body: JSON = [
                    "type": p.type, "lat": p.lat, "lon": p.lon, "heading": p.heading, "note": p.note,
                    "by": settings.nickname, "clientId": settings.clientId,
                ]
                let res = try await Net.post(URL(string: "\(server)/api/reports")!, body: body)
                // Look the report up again: the list may have changed while we waited.
                if let i = local.firstIndex(where: { $0.id == p.id }) {
                    local[i].serverId = res.str("id")
                    if res["expires"] != nil { local[i].expires = Date(timeIntervalSince1970: res.num("expires") / 1000) }
                }
            }
            persist()
            let b = Geo.bbox(around: c, meters: 80_000)
            guard let url = URL(string: "\(server)/api/reports?bbox=\(b.0),\(b.1),\(b.2),\(b.3)") else { return }
            let json = try await Net.get(url)
            remote = json.arr("reports").map { o in
                Report(id: o.str("id"), serverId: o.str("id"), type: o.str("type"), lat: o.num("lat"), lon: o.num("lon"),
                       heading: o.num("heading"), note: o.str("note"),
                       created: Date(timeIntervalSince1970: o.num("created") / 1000), expires: Date(timeIntervalSince1970: o.num("expires") / 1000),
                       up: o.int("up"), down: o.int("down"), by: o.str("by"), mine: o.str("clientId") == settings.clientId)
            }
            lastSync = (c, Date())
            status = "Live reports synced"
        } catch {
            status = "Report server unreachable"
        }
    }

    /// Closure reports between two points, so routes can steer around them.
    func closures(between a: Coord, and b: Coord) -> [Coord] {
        let minLat = min(a.latitude, b.latitude) - 0.05, maxLat = max(a.latitude, b.latitude) + 0.05
        let minLon = min(a.longitude, b.longitude) - 0.05, maxLon = max(a.longitude, b.longitude) + 0.05
        return reports.filter { $0.type == "closure" && (minLat...maxLat).contains($0.lat) && (minLon...maxLon).contains($0.lon) }
            .prefix(20).map(\.coordinate)
    }

    static func testServer(_ url: String) async -> String {
        let base = url.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        guard let u = URL(string: "\(base)/api/health") else { return "That doesn't look like a web address" }
        do {
            let j = try await Net.get(u, timeout: 8)
            return "Connected - \(j.int("active")) active reports on the server"
        } catch {
            return "Couldn't connect: \(error.localizedDescription)"
        }
    }
}
