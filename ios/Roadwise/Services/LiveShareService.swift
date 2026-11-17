import Foundation

/// Live location sharing through the Roadwise server (same API as share/LiveShare.kt).
/// Friends open the link in any browser and watch you move on a map.
@MainActor
final class LiveShareService: ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var url = ""
    @Published private(set) var expires: Date?
    @Published private(set) var untilArrival = false
    @Published private(set) var error: String?

    private var id = ""
    private var token = ""
    private var loop: Task<Void, Never>?
    private var lastSent = Date.distantPast
    private let settings: AppSettings
    /// Supplies the latest position and trip details each time we post an update.
    var snapshot: () -> (fix: Fix?, nav: NavSnapshot?) = { (nil, nil) }

    init(settings: AppSettings) { self.settings = settings }

    func start(minutes: Int, untilArrival: Bool = false) async throws -> String {
        guard let server = settings.serverURL else { throw NetError(message: "Add a Roadwise server in Settings to share live location") }
        if active { await stop() }
        let res = try await Net.post(URL(string: "\(server)/api/live")!, body: [
            "name": settings.nickname.isEmpty ? "Someone" : settings.nickname,
            "minutes": untilArrival ? 1440 : minutes, "clientId": settings.clientId,
        ])
        id = res.str("id"); token = res.str("token")
        url = "\(server)/live/\(id)"
        expires = untilArrival ? nil : Date().addingTimeInterval(Double(minutes) * 60)
        self.untilArrival = untilArrival
        active = true
        error = nil
        loop?.cancel()
        loop = Task { [weak self] in
            while let self, !Task.isCancelled, self.active {
                await self.tick(server: server)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        return url
    }

    private func tick(server: String) async {
        let snap = snapshot()
        if let e = expires, Date() > e { await stop(); return }
        if untilArrival, snap.nav == nil { await stop(); return }
        let interval: TimeInterval = snap.nav != nil ? 8 : 15
        guard Date().timeIntervalSince(lastSent) >= interval else { return }
        await push(server: server, snap: snap, arrived: false)
    }

    func arrived() async {
        guard active, let server = settings.serverURL else { return }
        await push(server: server, snap: snapshot(), arrived: true)
        if untilArrival { await stop() }
    }

    private func push(server: String, snap: (fix: Fix?, nav: NavSnapshot?), arrived: Bool) async {
        lastSent = Date()
        var body: JSON = ["token": token, "arrived": arrived, "imperial": settings.imperial]
        if let f = snap.fix {
            body["lat"] = f.coordinate.latitude; body["lon"] = f.coordinate.longitude
            body["speed"] = f.speed; body["heading"] = f.heading; body["accuracy"] = f.accuracy
        }
        if let n = snap.nav {
            body["eta"] = Int(n.eta.timeIntervalSince1970 * 1000)
            body["remainingM"] = n.remaining
            body["destName"] = n.destination.name
            body["destLat"] = n.destination.lat
            body["destLon"] = n.destination.lon
        }
        do {
            _ = try await Net.post(URL(string: "\(server)/api/live/\(id)")!, body: body, timeout: 8)
            error = nil
        } catch {
            let msg = error.localizedDescription
            if msg.contains("ended") || msg.contains("forbidden") { await stop() } else { self.error = "Server unreachable - retrying" }
        }
    }

    func stop() async {
        guard active else { return }
        active = false
        loop?.cancel()
        let (sid, tok) = (id, token)
        id = ""; token = ""
        if let server = settings.serverURL, let u = URL(string: "\(server)/api/live/\(sid)/stop") {
            _ = try? await Net.post(u, body: ["token": tok], timeout: 6)
        }
    }
}

/// What live sharing needs to know about the current trip.
struct NavSnapshot {
    let destination: Place
    let eta: Date
    let remaining: Double
}

func mapLink(_ c: Coord) -> String { String(format: "https://maps.google.com/?q=%.6f,%.6f", c.latitude, c.longitude) }
