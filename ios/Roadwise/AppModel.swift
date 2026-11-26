import SwiftUI
import Combine
import UIKit
import MapKit

enum Screen: Equatable { case browse, place, routes, nav }

/// App-wide state: what's on screen, the selected place and routes, and the active trip.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let settings: AppSettings
    let location: LocationService
    let reports: ReportService
    let live: LiveShareService
    let voice = Voice()

    @Published var screen: Screen = .browse
    @Published var place: Place?
    @Published var routes: [Route] = []
    @Published var selected = 0
    @Published var routeError: String?
    @Published var loadingRoutes = false
    @Published var nav: NavEngine?
    @Published var camera: MapCameraPosition = .userLocation(fallback: .automatic)
    @Published var following = false
    @Published var simulating = false
    @Published var saved: SavedPlaces
    @Published var toast: String?
    /// The visible map center, used when there's no GPS fix yet.
    var mapCenter: Coord?

    private var simTask: Task<Void, Never>?
    private var cancellables: [AnyCancellable] = []

    init() {
        let s = AppSettings()
        settings = s
        location = LocationService()
        reports = ReportService(settings: s)
        live = LiveShareService(settings: s)
        saved = SavedPlaces.load()
        voice.enabled = s.voice
        location.onFix = { [weak self] f in self?.onFix(f) }
        live.snapshot = { [weak self] in (self?.location.fix, self?.nav?.snapshot) }
        // Keep child objects' changes flowing to views that observe this model.
        cancellables.append(s.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor in self?.voice.enabled = self?.settings.voice ?? true }
        })
        cancellables.append(reports.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
            Task { @MainActor in self?.nav?.rebuildHazards() }
        })
        cancellables.append(live.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        cancellables.append(location.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
    }

    var here: Coord? { location.fix?.coordinate }
    var origin: Coord? { here ?? Self.testOrigin }

    /// UI tests run on a simulator with no GPS fix; they pass a start point as "lat,lon".
    static let testOrigin: Coord? = {
        guard let s = ProcessInfo.processInfo.environment["ROADWISE_TEST_ORIGIN"] else { return nil }
        let p = s.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return p.count == 2 ? Coord(latitude: p[0], longitude: p[1]) : nil
    }()

    func show(_ message: String) {
        toast = message
        Task { try? await Task.sleep(nanoseconds: 2_600_000_000); if toast == message { toast = nil } }
    }

    // MARK: location

    private func onFix(_ f: Fix) {
        nav?.onFix(f)
        if following { moveCamera(f) }
        Task { await reports.sync(around: f.coordinate) }
    }

    func moveCamera(_ f: Fix? = nil) {
        guard let f = f ?? location.fix else { return }
        if screen == .nav, let n = nav {
            let center = n.state.snapped ?? f.coordinate
            let distance: Double = f.speed > 25 ? 1400 : f.speed > 15 ? 1000 : 650
            withAnimation(.linear(duration: 0.9)) {
                camera = .camera(MapCamera(centerCoordinate: center, distance: distance, heading: n.state.bearing ?? f.heading, pitch: 55))
            }
        } else {
            withAnimation { camera = .camera(MapCamera(centerCoordinate: f.coordinate, distance: 1800, heading: 0, pitch: 0)) }
        }
    }

    func locateMe() {
        location.start()
        following = true
        if location.fix != nil { moveCamera() } else { show("Finding your location…") }
    }

    // MARK: places

    func pick(_ p: Place) {
        saved.addRecent(p)
        place = p
        routes = []
        following = false
        withAnimation { camera = .region(MKCoordinateRegion(center: p.coordinate, latitudinalMeters: 1500, longitudinalMeters: 1500)) }
        screen = .place
    }

    func dropPin(_ c: Coord) {
        guard screen != .nav else { return }
        Task { pick(await SearchService.reverse(c)) }
    }

    func closePlace() {
        place = nil
        routes = []
        screen = .browse
    }

    // MARK: routes

    func planRoutes() async {
        guard let p = place else { return }
        screen = .routes
        routeError = nil
        routes = []
        selected = 0
        guard let from = origin ?? (location.authorization == .denied ? mapCenter : nil) else {
            location.start()
            routeError = "Waiting for your location… Allow location access for Roadwise in Settings if you haven't."
            return
        }
        loadingRoutes = true
        defer { loadingRoutes = false }
        do {
            let mode = settings.travelMode
            let avoid = mode == .drive ? reports.closures(between: from, and: p.coordinate) : []
            routes = try await RoutingService.routes(from: from, to: p.coordinate, mode: mode, options: settings.routeOptions,
                                                     heading: (location.fix?.speed ?? 0) > 2 ? location.fix?.heading : nil, avoid: avoid)
            fitRoutes()
        } catch {
            routeError = "Couldn't find a route (\(error.localizedDescription))."
        }
    }

    func fitRoutes() {
        guard !routes.isEmpty else { return }
        var rect = MKMapRect.null
        for r in routes { for (i, p) in r.points.enumerated() where i % 5 == 0 || i == r.points.count - 1 {
            let mp = MKMapPoint(p)
            rect = rect.union(MKMapRect(x: mp.x, y: mp.y, width: 1, height: 1))
        } }
        let padded = rect.insetBy(dx: -rect.width * 0.15, dy: -rect.height * 0.35)
        withAnimation { camera = .rect(padded) }
    }

    // MARK: navigation

    func startNav(preview: Bool) {
        guard routes.indices.contains(selected), let dest = place else { return }
        let r = routes[selected]
        let engine = NavEngine(route: r, destination: dest, settings: settings, voice: voice, reports: reports)
        engine.onArrive = { [weak self] in Task { await self?.live.arrived() } }
        engine.onReroute = { [weak self] nr in self?.routes = [nr]; self?.selected = 0 }
        cancellables.append(engine.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() })
        nav = engine
        routes = [r]
        selected = 0
        screen = .nav
        following = true
        UIApplication.shared.isIdleTimerDisabled = true
        location.setNavigating(true)
        if preview { simulate(r) } else { location.start(); moveCamera() }
    }

    func endNav() {
        simTask?.cancel()
        simulating = false
        location.simulating = false
        voice.stop()
        if live.untilArrival { Task { await live.stop() } }
        nav = nil
        routes = []
        place = nil
        screen = .browse
        following = false
        UIApplication.shared.isIdleTimerDisabled = false
        location.setNavigating(false)
        withAnimation { camera = .userLocation(fallback: .automatic) }
    }

    /// Drives the route with simulated GPS at about 3x real time.
    private func simulate(_ r: Route) {
        simTask?.cancel()
        simulating = true
        location.simulating = true
        simTask = Task { [weak self] in
            var t = 0.0
            let total = r.cumTime.last ?? 0
            while let self, !Task.isCancelled, t < total, !(self.nav?.state.arrived ?? true) {
                t = min(total, t + 3)
                let i = max(1, r.cumTime.firstIndex { $0 > t } ?? (r.points.count - 1))
                let a = r.points[i - 1], b = r.points[i], segT = r.cumTime[i] - r.cumTime[i - 1]
                let frac = segT > 0 ? min(1, (t - r.cumTime[i - 1]) / segT) : 1
                let speed = segT > 0 ? Geo.dist(a, b) / segT : 10
                self.location.inject(Fix(coordinate: Geo.lerp(a, b, frac), accuracy: 5, speed: speed, heading: Geo.bearing(a, b), time: Date()))
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            self?.simulating = false
            self?.location.simulating = false
        }
    }

    // MARK: reports

    func report(_ type: ReportType) {
        guard let c = here ?? mapCenter else { show("Waiting for your location"); return }
        reports.add(type, at: c, heading: location.fix?.heading ?? 0)
        show("\(type.emoji) \(type.label) reported\(settings.serverURL == nil ? " on this phone" : "") — thanks!")
    }
}

/// Home, Work, favorites and recent places, saved on the phone.
struct SavedPlaces: Codable {
    var home: Place?
    var work: Place?
    var favorites: [Place] = []
    var recents: [Place] = []

    static func load() -> SavedPlaces {
        guard let d = UserDefaults.standard.data(forKey: "saved"), let s = try? JSONDecoder().decode(SavedPlaces.self, from: d) else { return SavedPlaces() }
        return s
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: "saved") }
    }

    mutating func addRecent(_ p: Place) {
        recents.removeAll { $0 == p }
        recents.insert(p, at: 0)
        recents = Array(recents.prefix(12))
        save()
    }
}
