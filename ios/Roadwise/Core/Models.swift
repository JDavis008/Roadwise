import Foundation
import CoreLocation
import SwiftUI

struct Place: Identifiable, Codable, Hashable {
    var id = UUID()
    var name: String
    var address: String
    var lat: Double
    var lon: Double
    var category: String = ""
    var emoji: String? = nil

    var coordinate: Coord { Coord(latitude: lat, longitude: lon) }

    static func == (a: Place, b: Place) -> Bool { a.name == b.name && abs(a.lat - b.lat) < 1e-5 && abs(a.lon - b.lon) < 1e-5 }
    func hash(into h: inout Hasher) { h.combine(name); h.combine(Int(lat * 1e4)); h.combine(Int(lon * 1e4)) }
}

enum TravelMode: String, CaseIterable, Identifiable, Codable {
    case drive, bike, walk
    var id: String { rawValue }
    var label: String { switch self { case .drive: "Drive"; case .bike: "Bike"; case .walk: "Walk" } }
    var symbol: String { switch self { case .drive: "car.fill"; case .bike: "bicycle"; case .walk: "figure.walk" } }
    var costing: String { switch self { case .drive: "auto"; case .bike: "bicycle"; case .walk: "pedestrian" } }
}

enum Turn: String {
    case depart, straight, slightLeft, left, sharpLeft, slightRight, right, sharpRight, uturn
    case keepLeft, keepRight, exitLeft, exitRight, rampLeft, rampRight, merge, roundabout, ferry, arrive

    static func valhalla(_ type: Int) -> Turn {
        switch type {
        case 1, 2, 3: .depart
        case 4, 5, 6: .arrive
        case 9: .slightRight
        case 10: .right
        case 11: .sharpRight
        case 12, 13: .uturn
        case 14: .sharpLeft
        case 15: .left
        case 16: .slightLeft
        case 18: .rampRight
        case 19: .rampLeft
        case 20: .exitRight
        case 21: .exitLeft
        case 23: .keepRight
        case 24: .keepLeft
        case 25, 37, 38: .merge
        case 26, 27: .roundabout
        case 28, 29: .ferry
        default: .straight
        }
    }

    /// SF Symbol for the turn arrow.
    var symbol: String {
        switch self {
        case .depart, .straight, .merge: "arrow.up"
        case .slightLeft, .keepLeft, .exitLeft, .rampLeft: "arrow.up.left"
        case .slightRight, .keepRight, .exitRight, .rampRight: "arrow.up.right"
        case .left, .sharpLeft: "arrow.turn.up.left"
        case .right, .sharpRight: "arrow.turn.up.right"
        case .uturn: "arrow.uturn.down"
        case .roundabout: "arrow.triangle.2.circlepath"
        case .ferry: "ferry.fill"
        case .arrive: "flag.checkered"
        }
    }
}

struct Maneuver {
    let turn: Turn
    /// Short banner text, e.g. "Turn right onto Main Street".
    let text: String
    /// Sentence to speak (without the distance prefix).
    let spoken: String
    let street: String?
    /// Index into the route's points where this maneuver happens.
    let index: Int
    let exit: Int
}

final class Route: Identifiable {
    let id = UUID()
    let points: [Coord]
    let maneuvers: [Maneuver]
    /// Seconds elapsed at each point.
    let cumTime: [Double]
    let cumDist: [Double]
    let duration: Double
    let label: String
    let tolls: Bool
    let ferry: Bool
    let mode: TravelMode
    let destination: Coord
    /// Stops before the destination, in driving order.
    let stops: [Waypoint]
    /// Index into `points` where each stop is reached (same count as `stops`).
    let stopIndex: [Int]
    /// Speed limit (km/h) for the segment starting at each point, 0 = unknown.
    var limits: [Int]

    var distance: Double { cumDist.last ?? 0 }

    init(points: [Coord], maneuvers: [Maneuver], cumTime: [Double], duration: Double, label: String, tolls: Bool, ferry: Bool,
         mode: TravelMode, destination: Coord, stops: [Waypoint] = [], stopIndex: [Int] = []) {
        self.points = points
        self.maneuvers = maneuvers
        self.cumTime = cumTime
        self.cumDist = Geo.cumulative(points)
        self.duration = duration
        self.label = label
        self.tolls = tolls
        self.ferry = ferry
        self.mode = mode
        self.destination = destination
        self.stops = stops
        self.stopIndex = stopIndex
        self.limits = [Int](repeating: 0, count: points.count)
    }

    /// The same route with `via` marked on it: where each stop is reached (in order), with an
    /// "Arrive at …" instruction there so turn-by-turn calls it out. Same as Route.withStops on Android.
    func withStops(_ via: [Waypoint]) -> Route {
        guard !via.isEmpty, !points.isEmpty else { return self }
        var idx: [Int] = []
        var from = 0
        for w in via {
            var best = from, bestD = Double.greatestFiniteMagnitude
            for i in from..<points.count {
                let d = Geo.dist(points[i], w.coordinate)
                if d < bestD { bestD = d; best = i }
            }
            idx.append(best)
            from = best
        }
        let arrivals = zip(via, idx).map { w, i in
            Maneuver(turn: .arrive, text: "Arrive at \(w.name)", spoken: "Arrive at \(w.name), your stop", street: nil, index: i, exit: 0)
        }
        // Merge by point index; a stop comes before a turn at the same point.
        var ms: [Maneuver] = []
        var a = 0, b = 0
        while a < arrivals.count || b < maneuvers.count {
            if b >= maneuvers.count || (a < arrivals.count && arrivals[a].index <= maneuvers[b].index) {
                ms.append(arrivals[a]); a += 1
            } else {
                ms.append(maneuvers[b]); b += 1
            }
        }
        let r = Route(points: points, maneuvers: ms, cumTime: cumTime, duration: duration, label: label, tolls: tolls, ferry: ferry,
                      mode: mode, destination: destination, stops: via, stopIndex: idx)
        r.limits = limits
        return r
    }
}

/// A stop on the way to the destination (gas, food, a friend's house…).
struct Waypoint: Equatable {
    let coordinate: Coord
    let name: String

    static func == (a: Waypoint, b: Waypoint) -> Bool {
        a.name == b.name && abs(a.coordinate.latitude - b.coordinate.latitude) < 1e-6 && abs(a.coordinate.longitude - b.coordinate.longitude) < 1e-6
    }
}

struct ReportType: Identifiable, Hashable {
    let key: String
    let label: String
    let emoji: String
    let color: Color
    let ttlMinutes: Int
    let spoken: String
    var id: String { key }

    static let all: [ReportType] = [
        .init(key: "police", label: "Police", emoji: "👮", color: Color(red: 0.12, green: 0.53, blue: 0.90), ttlMinutes: 120, spoken: "Police reported ahead"),
        .init(key: "accident", label: "Crash", emoji: "💥", color: Color(red: 0.90, green: 0.22, blue: 0.21), ttlMinutes: 180, spoken: "Crash reported ahead"),
        .init(key: "hazard", label: "Hazard", emoji: "⚠️", color: Color(red: 1.0, green: 0.63, blue: 0.0), ttlMinutes: 240, spoken: "Hazard on the road ahead"),
        .init(key: "jam", label: "Traffic", emoji: "🚗", color: Color(red: 0.85, green: 0.11, blue: 0.38), ttlMinutes: 60, spoken: "Heavy traffic reported ahead"),
        .init(key: "closure", label: "Closure", emoji: "⛔", color: Color(red: 0.43, green: 0.30, blue: 0.25), ttlMinutes: 1440, spoken: "Road closure reported ahead"),
        .init(key: "camera", label: "Speed trap", emoji: "📸", color: Color(red: 0.56, green: 0.14, blue: 0.67), ttlMinutes: 240, spoken: "Speed trap reported ahead"),
        .init(key: "construction", label: "Roadwork", emoji: "🚧", color: Color(red: 0.96, green: 0.32, blue: 0.12), ttlMinutes: 10080, spoken: "Roadwork reported ahead"),
        .init(key: "weather", label: "Weather", emoji: "🌧️", color: Color(red: 0.33, green: 0.43, blue: 0.48), ttlMinutes: 180, spoken: "Bad weather reported ahead"),
    ]

    static func of(_ key: String) -> ReportType { all.first { $0.key == key } ?? all[2] }
}

struct Report: Identifiable, Codable, Hashable {
    var id: String
    var serverId: String?
    var type: String
    var lat: Double
    var lon: Double
    var heading: Double
    var note: String
    var created: Date
    var expires: Date
    var up: Int
    var down: Int
    var by: String
    var mine: Bool

    var coordinate: Coord { Coord(latitude: lat, longitude: lon) }
    var kind: ReportType { ReportType.of(type) }
}

struct Category: Identifiable {
    let label: String
    let emoji: String
    let tags: [String]
    var id: String { label }

    static let all: [Category] = [
        .init(label: "Gas", emoji: "⛽", tags: ["amenity:fuel"]),
        .init(label: "Food", emoji: "🍔", tags: ["amenity:restaurant", "amenity:fast_food"]),
        .init(label: "Coffee", emoji: "☕", tags: ["amenity:cafe"]),
        .init(label: "Parking", emoji: "🅿️", tags: ["amenity:parking"]),
        .init(label: "EV charging", emoji: "🔌", tags: ["amenity:charging_station"]),
        .init(label: "Groceries", emoji: "🛒", tags: ["shop:supermarket", "shop:grocery", "shop:convenience"]),
        .init(label: "Hotels", emoji: "🛏️", tags: ["tourism:hotel", "tourism:motel"]),
        .init(label: "Hospitals", emoji: "🏥", tags: ["amenity:hospital"]),
    ]
}
