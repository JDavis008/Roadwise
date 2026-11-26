import Foundation

/// Routing: the public Valhalla server (FOSSGIS) when there's signal, like routing/OnlineRouter.kt,
/// and the same Valhalla engine on the phone over downloaded states when there isn't
/// (Offline/OfflineRouter.swift). Both answer in the same JSON, parsed the same way.
enum RoutingService {
    static let base = "https://valhalla1.openstreetmap.de"

    static func routes(from: Coord, to: Coord, mode: TravelMode, options: RouteOptions,
                       heading: Double? = nil, avoid: [Coord] = [], alternates: Bool = true,
                       offline data: OfflineData = .shared) async throws -> [Route] {
        let canOffline = data.covers(from, to)
        if Connectivity.shared.online || !canOffline {
            do {
                return try trips(await online(request(from, to, mode, options, heading, avoid, alternates), avoid: avoid,
                                              fallback: request(from, to, mode, options, heading, [], alternates)), mode: mode, dest: to)
            } catch {
                guard canOffline else {
                    if !Connectivity.shared.online {
                        throw NetError(message: data.hasData ? "You're offline and this trip goes outside your downloaded states"
                                                             : "You're offline. Download your state in Settings > Offline maps to plan routes with no signal")
                    }
                    throw error
                }
            }
        }
        return try await offlineRoutes(from: from, to: to, mode: mode, options: options, heading: heading, avoid: avoid, alternates: alternates, data: data)
    }

    /// Plans on the phone only (tests and the fallback above).
    static func offlineRoutes(from: Coord, to: Coord, mode: TravelMode, options: RouteOptions, heading: Double? = nil,
                              avoid: [Coord] = [], alternates: Bool = true, data: OfflineData = .shared) async throws -> [Route] {
        let req = request(from, to, mode, options, heading, avoid, alternates)
        let plain = request(from, to, mode, options, heading, [], alternates)
        let json: JSON = try await Task.detached(priority: .userInitiated) {
            do { return try data.router.route(req) } catch {
                guard !avoid.isEmpty else { throw error }
                return try data.router.route(plain)
            }
        }.value
        return try trips(json, mode: mode, dest: to)
    }

    private static func online(_ req: JSON, avoid: [Coord], fallback: JSON) async throws -> JSON {
        do {
            return try await Net.post(URL(string: "\(base)/route")!, body: req, timeout: 25)
        } catch {
            // A closure point that can't be matched to a road makes Valhalla reject the whole request.
            guard !avoid.isEmpty else { throw error }
            return try await Net.post(URL(string: "\(base)/route")!, body: fallback, timeout: 25)
        }
    }

    private static func trips(_ json: JSON, mode: TravelMode, dest: Coord) throws -> [Route] {
        guard let trip = json.obj("trip") else { throw NetError(message: "No route found") }
        var out = [parse(trip, mode: mode, dest: dest)]
        for alt in json.arr("alternates") {
            if let t = alt.obj("trip") {
                let r = parse(t, mode: mode, dest: dest)
                if out.allSatisfy({ overlap(r, $0) < 0.85 }) { out.append(r) }
            }
        }
        return out
    }

    private static func request(_ from: Coord, _ to: Coord, _ mode: TravelMode, _ o: RouteOptions,
                                _ heading: Double?, _ avoid: [Coord], _ alternates: Bool) -> JSON {
        var start: JSON = ["lat": from.latitude, "lon": from.longitude]
        if let h = heading { start["heading"] = Int(h); start["heading_tolerance"] = 60 }
        var costing: JSON = [:]
        switch mode {
        case .drive: costing["auto"] = ["use_tolls": o.avoidTolls ? 0.0 : 0.5, "use_highways": o.avoidHighways ? 0.0 : 1.0, "use_ferry": o.avoidFerries ? 0.0 : 0.5]
        case .bike: costing["bicycle"] = ["bicycle_type": "hybrid"]
        case .walk: costing["pedestrian"] = JSON()
        }
        let end: JSON = ["lat": to.latitude, "lon": to.longitude]
        var req: JSON = [
            "locations": [start, end],
            "costing": mode.costing, "costing_options": costing,
            "units": "kilometers", "language": "en-US", "id": "roadwise",
        ]
        if !avoid.isEmpty { req["exclude_locations"] = avoid.map { ["lat": $0.latitude, "lon": $0.longitude] } }
        if alternates { req["alternates"] = 2 }
        return req
    }

    private static func parse(_ trip: JSON, mode: TravelMode, dest: Coord) -> Route {
        var points: [Coord] = []
        var maneuvers: [Maneuver] = []
        var times: [(Int, Int, Double)] = []
        let legs = trip.arr("legs")
        for (l, leg) in legs.enumerated() {
            let offset = points.isEmpty ? 0 : points.count - 1
            let shape = Geo.decodePolyline(leg.str("shape"), precision: 6)
            points += points.isEmpty ? shape : Array(shape.dropFirst())
            for m in leg.arr("maneuvers") {
                let type = m.int("type")
                let begin = m.int("begin_shape_index") + offset, end = m.int("end_shape_index") + offset
                times.append((begin, end, m.num("time")))
                if l > 0 && (1...3).contains(type) { continue }
                if l < legs.count - 1 && (4...6).contains(type) { continue }
                let streets = (m["begin_street_names"] as? [String]) ?? (m["street_names"] as? [String])
                let alert = m.str("verbal_transition_alert_instruction")
                let text = (alert.isEmpty ? m.str("instruction") : alert).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let pre = m.str("verbal_pre_transition_instruction")
                let spoken = (alert.isEmpty ? (pre.isEmpty ? text : pre) : alert).trimmingCharacters(in: CharacterSet(charactersIn: "."))
                maneuvers.append(Maneuver(turn: .valhalla(type), text: text, spoken: spoken,
                                          street: streets.map { $0.joined(separator: " / ") }.flatMap { $0.isEmpty ? nil : $0 },
                                          index: max(0, min(begin, points.count - 1)), exit: m.int("roundabout_exit_count")))
            }
        }
        // Spread each maneuver's time along its shape, proportional to length.
        var seg = [Double](repeating: 0, count: points.count)
        for (b, e, t) in times where e > b {
            let last = min(e, points.count - 1)
            guard b < last else { continue }
            var len = 0.0
            for i in b..<last { len += Geo.dist(points[i], points[i + 1]) }
            guard len > 0 else { continue }
            for i in b..<last { seg[i] = t * Geo.dist(points[i], points[i + 1]) / len }
        }
        var cumTime = [Double](repeating: 0, count: points.count)
        if points.count > 1 { for i in 1..<points.count { cumTime[i] = cumTime[i - 1] + seg[i - 1] } }
        let summary = trip.obj("summary") ?? [:]
        let duration = summary["time"] != nil ? summary.num("time") : (cumTime.last ?? 0)

        // Label the route with the road you spend the longest on.
        let cum = Geo.cumulative(points)
        var best = "", bestLen = -1.0
        for (i, m) in maneuvers.enumerated() {
            guard let st = m.street else { continue }
            let end = i + 1 < maneuvers.count ? maneuvers[i + 1].index : points.count - 1
            let len = cum[max(0, end)] - cum[m.index]
            if len > bestLen { bestLen = len; best = st.components(separatedBy: " / ").first ?? st }
        }
        return Route(points: points, maneuvers: maneuvers, cumTime: cumTime, duration: duration,
                     label: best.isEmpty ? "Fastest route" : "via \(best)", tolls: summary.bool("has_toll"),
                     ferry: summary.bool("has_ferry"), mode: mode, destination: dest)
    }

    /// Fraction of a's length that runs close to b.
    private static func overlap(_ a: Route, _ b: Route) -> Double {
        let step = max(1, a.points.count / 100), bStep = max(1, b.points.count / 500)
        let bs = stride(from: 0, to: b.points.count, by: bStep).map { b.points[$0] }
        var n = 0, near = 0
        for i in stride(from: 0, to: a.points.count, by: step) {
            n += 1
            let p = a.points[i]
            if bs.contains(where: { abs($0.latitude - p.latitude) < 0.002 && abs($0.longitude - p.longitude) < 0.0026 && Geo.dist(p, $0) < 120 }) { near += 1 }
        }
        return n > 0 ? Double(near) / Double(n) : 0
    }

    /// Fills per-segment speed limits using Valhalla's map matching of the route shape.
    static func speedLimits(for route: Route) async -> [Int]? {
        guard route.mode == .drive, route.points.count > 1, route.points.count < 15000 else { return nil }
        let body: JSON = [
            "encoded_polyline": Geo.encodePolyline(route.points), "shape_match": "edge_walk", "costing": "auto",
            "filters": ["attributes": ["edge.speed_limit", "edge.begin_shape_index", "edge.end_shape_index"], "action": "include"] as JSON,
        ]
        let json: JSON
        if Connectivity.shared.online, let j = try? await Net.post(URL(string: "\(base)/trace_attributes")!, body: body, timeout: 25) {
            json = j
        } else if let first = route.points.first, OfflineData.shared.covers(first, route.destination),
                  let j = try? await Task.detached(operation: { try OfflineData.shared.router.traceAttributes(body) }).value {
            json = j   // same answer from the downloaded tiles
        } else {
            return nil
        }
        var limits = [Int](repeating: 0, count: route.points.count)
        for e in json.arr("edges") {
            let lim = e.int("speed_limit")
            guard lim > 0, lim <= 200 else { continue }
            let b = max(0, e.int("begin_shape_index")), en = min(e.int("end_shape_index"), limits.count)
            if b < en { for k in b..<en { limits[k] = lim } }
        }
        return limits
    }
}
