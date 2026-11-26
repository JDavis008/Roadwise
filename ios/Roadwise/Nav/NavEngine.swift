import Foundation

struct NavAlert: Identifiable {
    let id: String
    let emoji: String
    let title: String
    let detail: String
    let report: Report?
}

struct NavState {
    var remaining: Double = 0
    var remainingTime: Double = 0
    var eta = Date()
    var next: Maneuver?
    var nextIndex = 1
    var distToNext: Double = 0
    var then: Maneuver?
    var snapped: Coord?
    var bearing: Double?
    var speedLimit = 0
    var overSpeed = false
    var offRoute = false
    var rerouting = false
    var arrived = false
    var alert: NavAlert?
    /// Stops still ahead, in order, and the distance, time and arrival time to the next one.
    var stops: [Waypoint] = []
    var stopDist: Double = 0
    var stopTime: Double = 0
    var stopEta = Date()
    /// A short note under the banner ("Reached Speedway · next: Ohio Stadium").
    var message: String?
}

/// Turn-by-turn engine: snaps GPS to the route, tracks progress, speaks instructions,
/// warns about reports and speeding, and reroutes when you leave the route. Port of nav/NavEngine.kt.
@MainActor
final class NavEngine: ObservableObject {
    @Published private(set) var route: Route
    @Published private(set) var state = NavState()
    let destination: Place

    private let settings: AppSettings
    private let voice: Voice
    private let reports: ReportService
    private var seg = 0
    private var spoken: [Int: Int] = [:]
    private var postSpoken = Set<Int>()
    private var offCount = 0
    private var alerted = Set<String>()
    private var hazards: [(Report, Double)] = []
    /// Speed cameras on the route and their distance along it.
    private var cameras: [(SpeedCamera, Double)] = []
    /// Index of the route segment you're on (for drawing the driven part).
    var progressSegment: Int { seg }
    private var lastReroute = Date.distantPast
    private var overSince: Date?
    private var lastChime = Date.distantPast
    var onArrive: (() -> Void)?
    var onReroute: ((Route) -> Void)?
    /// How many of the current route's stops are behind us.
    private var stopsDone = 0
    /// The stop we last reached: GPS wandering around its parking lot isn't "off route".
    private var atStop: Coord?
    private var lastFix: Fix?

    init(route: Route, destination: Place, settings: AppSettings, voice: Voice, reports: ReportService) {
        self.route = route
        self.destination = destination
        self.settings = settings
        self.voice = voice
        self.reports = reports
        state.remaining = route.distance
        state.remainingTime = route.duration
        state.eta = Date().addingTimeInterval(route.duration)
        state.next = route.maneuvers.count > 1 ? route.maneuvers[1] : route.maneuvers.first
        state.stops = route.stops
        rebuildHazards()
        loadLimits()
        loadCameras()
        let first = route.maneuvers.first
        let stopsText = route.stops.isEmpty ? "" : route.stops.count == 1 ? ", stopping at \(route.stops[0].name)" : " with \(route.stops.count) stops"
        voice.speak("Starting route to \(destination.name)\(stopsText). \(Units.spoken(route.distance, imperial: settings.imperial)), about "
                    + Units.duration(route.duration).replacingOccurrences(of: "hr", with: "hours").replacingOccurrences(of: "min", with: "minutes")
                    + ". " + (first?.turn == .depart ? first!.spoken : ""), interrupt: true)
    }

    private func loadLimits() {
        let r = route
        Task {
            if let limits = await RoutingService.speedLimits(for: r), r === self.route { r.limits = limits }
        }
    }

    private func loadCameras() {
        let r = route
        cameras = []
        guard r.mode == .drive else { return }
        Task {
            let found = await CameraService.cameras(near: r.points)
            guard r === self.route else { return }
            self.cameras = found.compactMap { cam in self.along(cam.coordinate, maxOff: 35).map { (cam, $0) } }
        }
    }

    private func resetProgress() {
        seg = 0; spoken = [:]; postSpoken = []; offCount = 0; alerted = []
    }

    func rebuildHazards() {
        hazards = reports.reports.compactMap { rep in along(rep.coordinate, maxOff: 45).map { (rep, $0) } }
    }

    /// Distance along the route of the point nearest to p, if p is within maxOff meters of it.
    private func along(_ p: Coord, maxOff: Double) -> Double? {
        let pts = route.points
        guard pts.count > 1 else { return nil }
        var best = Double.greatestFiniteMagnitude, at = 0.0
        for i in 0..<(pts.count - 1) {
            if abs(pts[i].latitude - p.latitude) > 0.05 || abs(pts[i].longitude - p.longitude) > 0.05 { continue }
            let pr = Geo.project(p, pts[i], pts[i + 1])
            if pr.d < best { best = pr.d; at = route.cumDist[i] + pr.t * (route.cumDist[i + 1] - route.cumDist[i]) }
        }
        return best <= maxOff ? at : nil
    }

    func onFix(_ f: Fix) {
        let r = route, pts = r.points
        guard !state.arrived, !state.rerouting, pts.count > 1 else { return }
        lastFix = f

        // Pulling into a stop (gas station, drive-through) can leave the road, so count it as
        // reached once we're close, and don't call that "off route" while we're there.
        if stopsDone < r.stops.count && Geo.dist(f.coordinate, r.stops[stopsDone].coordinate) < 45 { reachStop() }
        if let s = atStop, Geo.dist(f.coordinate, s) > 90 { atStop = nil }

        // Snap to the route, searching a window ahead of the last known segment.
        var bi = seg, bt = 0.0, bd = Double.greatestFiniteMagnitude
        for i in max(0, seg - 3)...min(seg + 120, pts.count - 2) {
            let pr = Geo.project(f.coordinate, pts[i], pts[i + 1])
            var score = pr.d
            if f.speed > 3 && Geo.angleDiff(Geo.bearing(pts[i], pts[i + 1]), f.heading) > 100 { score += 30 }
            if score < bd { bd = score; bi = i; bt = pr.t }
        }
        let offDist = Geo.project(f.coordinate, pts[bi], pts[bi + 1]).d
        let threshold = max(r.mode == .drive ? 45 : 30, f.accuracy * 1.3)
        if offDist > threshold && atStop != nil {
            offCount = 0
            state.offRoute = false
            return
        }
        if offDist > threshold {
            offCount += 1
            state.offRoute = offCount >= 3
            if offCount >= 3 { reroute(from: f) }
            return
        }
        offCount = 0
        seg = bi
        state.offRoute = false
        let progress = r.cumDist[bi] + bt * (r.cumDist[bi + 1] - r.cumDist[bi])
        state.snapped = Geo.lerp(pts[bi], pts[bi + 1], bt)
        state.bearing = Geo.bearing(pts[bi], pts[bi + 1])
        state.remaining = max(0, r.distance - progress)
        let timeAt = r.cumTime[bi] + (r.cumTime[bi + 1] - r.cumTime[bi]) * bt
        let total = max(1, r.cumTime.last ?? 1)
        state.remainingTime = max(0, total - timeAt) * (r.duration / total)
        state.eta = Date().addingTimeInterval(state.remainingTime)

        // Stops: passed, and how far to the next one.
        while stopsDone < r.stops.count && progress >= r.cumDist[r.stopIndex[stopsDone]] - 20 { reachStop() }
        if stopsDone < r.stopIndex.count {
            let at = r.stopIndex[stopsDone]
            state.stopDist = max(0, r.cumDist[at] - progress)
            state.stopTime = max(0, r.cumTime[at] - timeAt) * (r.duration / total)
            state.stopEta = Date().addingTimeInterval(state.stopTime)
        }
        let reachedAt = Set(r.stopIndex.prefix(stopsDone))
        let lastIndex = r.maneuvers.count - 1

        var ni = r.maneuvers.indices.first { i in
            let m = r.maneuvers[i]
            return r.cumDist[m.index] > progress + 8 && !(m.turn == .arrive && reachedAt.contains(m.index) && i != lastIndex)
        } ?? lastIndex
        ni = max(0, ni)
        let next = r.maneuvers[ni]
        state.next = next
        state.nextIndex = ni
        state.distToNext = max(0, r.cumDist[next.index] - progress)
        if ni + 1 < r.maneuvers.count, r.cumDist[r.maneuvers[ni + 1].index] - r.cumDist[next.index] < 250 {
            state.then = r.maneuvers[ni + 1]
        } else {
            state.then = nil
        }
        state.speedLimit = bi < r.limits.count ? r.limits[bi] : 0

        if state.remaining < 25 || (Geo.dist(f.coordinate, r.destination) < 30 && progress > r.distance * 0.8) {
            state.arrived = true
            state.remaining = 0
            state.remainingTime = 0
            state.next = r.maneuvers.last
            state.distToNext = 0
            voice.speak("You have arrived at \(destination.name)", interrupt: true)
            onArrive?()
            return
        }
        announce(ni, next, state.distToNext, f.speed, state.then)
        checkAlerts(progress, f.speed)
        checkSpeed(f.speed, state.speedLimit)
    }

    private func announce(_ ni: Int, _ m: Maneuver, _ d: Double, _ speed: Double, _ then: Maneuver?) {
        guard m.turn != .depart else { return }
        let r = route, imperial = settings.imperial
        let v = max(speed, r.mode == .drive ? 12 : r.mode == .bike ? 4 : 1.3)
        let far = min(2600, max(250, v * 50)), near = min(700, max(60, v * 15)), now = min(110, max(15, v * 4.5))
        let prevGap = ni > 0 ? r.cumDist[m.index] - r.cumDist[r.maneuvers[ni - 1].index] : .greatestFiniteMagnitude
        let stage = spoken[ni] ?? -1
        if d <= now && stage < 2 {
            spoken[ni] = 2
            let thenText = then.map { ", then \(lowerFirst($0.spoken))" } ?? ""
            voice.speak(m.spoken.prefix(1).uppercased() + m.spoken.dropFirst() + thenText)
        } else if d <= near && stage < 1 && d > now * 1.5 {
            spoken[ni] = 1
            voice.speak("In \(Units.spoken(d, imperial: imperial)), \(lowerFirst(m.spoken))")
        } else if d <= far && stage < 0 && d > near * 1.6 && prevGap > near * 2 {
            spoken[ni] = 0
            voice.speak("In \(Units.spoken(d, imperial: imperial)), \(lowerFirst(m.spoken))")
        } else if stage < 0 && d > far * 1.3 && ni > 1 && !postSpoken.contains(ni - 1) && d > 3000 {
            postSpoken.insert(ni - 1)
            let road = r.maneuvers[ni - 1].street?.components(separatedBy: " / ").first
            voice.speak("Continue \(road.map { "on \($0) " } ?? "")for \(Units.spoken(d, imperial: imperial))")
        }
    }

    private func lowerFirst(_ s: String) -> String {
        let chars = Array(s)
        guard chars.count > 1, chars[1].isLowercase else { return s }
        return chars[0].lowercased() + String(chars.dropFirst())
    }

    private func checkAlerts(_ progress: Double, _ speed: Double) {
        let look = route.mode == .drive ? min(1200, max(500, speed * 40)) : 200
        if settings.cameraAlerts && route.mode == .drive {
            for (cam, at) in cameras {
                let ahead = at - progress
                guard ahead >= 0, ahead <= look * 0.7, !alerted.contains(cam.id) else { continue }
                alerted.insert(cam.id)
                voice.speak("Speed camera ahead")
                let limit = cam.maxspeedKmh > 0 ? " · limit \(Units.limit(cam.maxspeedKmh, imperial: settings.imperial)) \(Units.speedUnit(settings.imperial))" : ""
                show(NavAlert(id: cam.id, emoji: "📷", title: "Speed camera",
                              detail: "\(Units.distance(ahead, imperial: settings.imperial)) ahead\(limit)", report: nil), seconds: 15)
                return
            }
        }
        guard settings.reportAlerts else { return }
        for (rep, at) in hazards {
            let ahead = at - progress
            if ahead >= 0 && ahead <= look && !alerted.contains(rep.id) {
                alerted.insert(rep.id)
                let t = rep.kind
                voice.speak(t.spoken)
                show(NavAlert(id: rep.id, emoji: t.emoji, title: t.label,
                              detail: "\(Units.distance(ahead, imperial: settings.imperial)) ahead" + (rep.by.isEmpty ? "" : " · by \(rep.by)"), report: rep), seconds: 20)
                return
            }
        }
    }

    private func show(_ alert: NavAlert, seconds: UInt64) {
        state.alert = alert
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            if self?.state.alert?.id == alert.id { self?.state.alert = nil }
        }
    }

    func dismissAlert() { state.alert = nil }

    private func checkSpeed(_ speed: Double, _ limitKmh: Int) {
        guard settings.speedAlert, limitKmh > 0, route.mode == .drive else { overSince = nil; state.overSpeed = false; return }
        let over = Units.speed(speed, imperial: settings.imperial) > Units.limit(limitKmh, imperial: settings.imperial) + settings.tolerance
        state.overSpeed = over
        guard over else { overSince = nil; return }
        let now = Date()
        if overSince == nil { overSince = now }
        if let since = overSince, now.timeIntervalSince(since) > 2.5, now.timeIntervalSince(lastChime) > 30 {
            lastChime = now
            voice.chime()
        }
    }

    private func reroute(from f: Fix) {
        guard !state.rerouting, Date().timeIntervalSince(lastReroute) > 12 else { return }
        lastReroute = Date()
        voice.speak("Rerouting", interrupt: true)
        replan(from: f.coordinate, heading: f.speed > 2 ? f.heading : nil, via: Array(route.stops.dropFirst(stopsDone)), done: nil)
    }

    /// Plans a new route from `from` through `via` to the destination and switches to it.
    private func replan(from: Coord, heading: Double?, via: [Waypoint], done: String?) {
        guard !state.rerouting else { return }
        state.rerouting = true
        let mode = route.mode, dest = route.destination
        Task {
            defer { state.rerouting = false; state.offRoute = false }
            do {
                let avoid = mode == .drive ? reports.closures(between: from, and: dest) : []
                let rs = try await RoutingService.routes(from: from, to: dest, mode: mode, options: settings.routeOptions,
                                                         heading: heading, avoid: avoid, alternates: false, via: via)
                guard let nr = rs.first else { return }
                route = nr
                resetProgress()
                stopsDone = 0
                state.stops = nr.stops
                state.message = done
                if let done { voice.speak(done, interrupt: true) }
                rebuildHazards()
                loadLimits()
                loadCameras()
                onReroute?(nr)
            } catch {
                voice.speak("Couldn't reroute")
                state.message = "Couldn't reroute: \(error.localizedDescription)"
            }
        }
    }

    private func reachStop() {
        let r = route, k = stopsDone
        guard k < r.stops.count else { return }
        let w = r.stops[k]
        stopsDone += 1
        atStop = w.coordinate
        // Don't announce the stop again if "Arrive at …" was just spoken.
        let mi = r.maneuvers.firstIndex { $0.turn == .arrive && $0.index == r.stopIndex[k] }
        let alreadySaid = mi.map { (spoken[$0] ?? -1) >= 2 } ?? false
        if let mi { spoken[mi] = 2 }
        if !alreadySaid { voice.speak("You've reached \(w.name)", interrupt: true) }
        let next = stopsDone < r.stops.count ? r.stops[stopsDone].name : destination.name
        state.stops = Array(r.stops.dropFirst(stopsDone))
        state.message = "Reached \(w.name) · next: \(next)"
    }

    /// Adds a stop in driving order (before any stop that comes later along the route) and replans.
    func addStop(_ w: Waypoint) {
        let r = route
        var remaining = Array(r.stops.dropFirst(stopsDone))
        var at = 0, bestD = Double.greatestFiniteMagnitude
        for (i, p) in r.points.enumerated() { let d = Geo.dist(p, w.coordinate); if d < bestD { bestD = d; at = i } }
        let pos = remaining.indices.first { r.stopIndex[stopsDone + $0] > at } ?? remaining.count
        remaining.insert(w, at: pos)
        replan(from: lastFix?.coordinate ?? state.snapped ?? r.points[0], heading: (lastFix?.speed ?? 0) > 2 ? lastFix?.heading : nil,
               via: remaining, done: "Added stop: \(w.name)")
    }

    /// Drops a stop still ahead (0 = the next one) and replans.
    func removeStop(_ i: Int = 0) {
        var remaining = Array(route.stops.dropFirst(stopsDone))
        guard remaining.indices.contains(i) else { return }
        let gone = remaining.remove(at: i)
        replan(from: lastFix?.coordinate ?? state.snapped ?? route.points[0], heading: (lastFix?.speed ?? 0) > 2 ? lastFix?.heading : nil,
               via: remaining, done: "Skipping \(gone.name)")
    }

    func clearMessage() { state.message = nil }

    var snapshot: NavSnapshot { NavSnapshot(destination: destination, eta: state.eta, remaining: state.remaining) }
}
