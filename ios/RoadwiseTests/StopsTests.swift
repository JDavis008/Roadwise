import XCTest
@testable import Roadwise

/// Stops on the way: marking them on a route, calling them out, and moving past them.
/// Same cases as the Android StopsTest.
@MainActor
final class StopsTests: XCTestCase {
    private let dest = Place(name: "Ohio Stadium", address: "411 Woody Hayes Dr, Columbus", lat: 40.0, lon: -83.0)
    private let gas = Waypoint(coordinate: Coord(latitude: 39.9750, longitude: -82.9998), name: "Speedway")   // beside point 15

    /// Straight north, 40 points about 111 m apart, with a right turn at point 20.
    private func route() -> Route {
        let pts = (0...40).map { Coord(latitude: 39.96 + Double($0) * 0.001, longitude: -83.0) }
        let ms = [
            Maneuver(turn: .depart, text: "Head north on High Street", spoken: "Head north on High Street", street: "High Street", index: 0, exit: 0),
            Maneuver(turn: .right, text: "Turn right onto Rich Street", spoken: "Turn right onto Rich Street", street: "Rich Street", index: 20, exit: 0),
            Maneuver(turn: .arrive, text: "Arrive at Ohio Stadium", spoken: "Arrive at Ohio Stadium", street: nil, index: 40, exit: 0),
        ]
        return Route(points: pts, maneuvers: ms, cumTime: (0...40).map { Double($0) * 8 }, duration: 320, label: "via High Street",
                     tolls: false, ferry: false, mode: .drive, destination: pts.last!)
    }

    private func fix(_ lat: Double, _ lon: Double = -83.0) -> Fix {
        Fix(coordinate: Coord(latitude: lat, longitude: lon), accuracy: 5, speed: 13, heading: 0, time: Date())
    }

    private func engine(_ r: Route) -> NavEngine {
        let s = AppSettings()
        s.voice = false
        return NavEngine(route: r, destination: dest, settings: s, voice: Voice(), reports: ReportService(settings: s))
    }

    func testStopsAreMarkedInOrderWithAnArrivalInstruction() {
        let second = Waypoint(coordinate: Coord(latitude: 39.99, longitude: -83.0001), name: "Tim Hortons")
        let r = route().withStops([gas, second])
        XCTAssertEqual(r.stopIndex, [15, 30])
        XCTAssertEqual(r.maneuvers.map(\.text), ["Head north on High Street", "Arrive at Speedway", "Turn right onto Rich Street",
                                                 "Arrive at Tim Hortons", "Arrive at Ohio Stadium"])
        XCTAssertEqual(r.maneuvers.map(\.index), [0, 15, 20, 30, 40])
        XCTAssertEqual(r.distance, route().distance, accuracy: 0.01)
        let plain = route()
        XCTAssertTrue(plain.withStops([]) === plain)
    }

    func testDrivingPastAStopCountsItAndMovesOn() {
        let nav = engine(route().withStops([gas]))
        XCTAssertEqual(nav.state.stops.map(\.name), ["Speedway"])

        nav.onFix(fix(39.97))   // point 10: the stop is next, about 555 m ahead
        XCTAssertEqual(nav.state.next?.text, "Arrive at Speedway")
        XCTAssertEqual(nav.state.stopDist, 555, accuracy: 15)
        XCTAssertEqual(nav.state.stopTime, 40, accuracy: 1)

        nav.onFix(fix(39.9762))   // just past it
        XCTAssertTrue(nav.state.stops.isEmpty)
        XCTAssertTrue(nav.state.message?.hasPrefix("Reached Speedway") ?? false)
        XCTAssertEqual(nav.state.next?.text, "Turn right onto Rich Street")
        XCTAssertFalse(nav.state.arrived)

        nav.onFix(fix(39.9999))
        XCTAssertTrue(nav.state.arrived)
    }

    func testPullingIntoTheStopReachesItWithoutGoingOffRoute() {
        let nav = engine(route().withStops([gas]))
        // In the gas station lot, 60 m off the road: reached, and not "off route".
        for _ in 0..<5 { nav.onFix(fix(39.9751, -82.9993)) }
        XCTAssertTrue(nav.state.stops.isEmpty)
        XCTAssertFalse(nav.state.offRoute)
        XCTAssertFalse(nav.state.rerouting)
        nav.onFix(fix(39.9765))
        XCTAssertEqual(nav.state.next?.text, "Turn right onto Rich Street")
    }
}
