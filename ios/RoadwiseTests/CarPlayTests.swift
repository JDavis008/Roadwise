import XCTest
import CarPlay
@testable import Roadwise

/// Checks the CarPlay building blocks on a simulator (the car screen itself needs Xcode's
/// CarPlay window or a real car, which a cloud build can't open).
@MainActor
final class CarPlayTests: XCTestCase {

    private func route(label: String = "via Main Street", tolls: Bool = false) -> Route {
        let pts = [Coord(latitude: 39.9612, longitude: -82.9988),
                   Coord(latitude: 39.9650, longitude: -82.9988),
                   Coord(latitude: 39.9650, longitude: -82.9900)]
        let ms = [
            Maneuver(turn: .depart, text: "Head north on High Street", spoken: "Head north", street: "High Street", index: 0, exit: 0),
            Maneuver(turn: .right, text: "Turn right onto Main Street", spoken: "Turn right", street: "Main Street", index: 1, exit: 0),
            Maneuver(turn: .arrive, text: "You have arrived", spoken: "You have arrived", street: nil, index: 2, exit: 0),
        ]
        return Route(points: pts, maneuvers: ms, cumTime: [0, 40, 90], duration: 90, label: label,
                     tolls: tolls, ferry: false, mode: .drive, destination: pts[2])
    }

    func testTripHasOneChoicePerRouteTaggedWithItsIndex() {
        let place = Place(name: "Ohio Stadium", address: "Columbus", lat: 39.965, lon: -82.99)
        let trip = CarTemplates.trip(from: Coord(latitude: 39.96, longitude: -83.0), to: place,
                                     routes: [route(), route(label: "via Broad Street", tolls: true)], imperial: true)
        XCTAssertEqual(trip.routeChoices.count, 2)
        XCTAssertEqual(trip.routeChoices[0].userInfo as? Int, 0)
        XCTAssertEqual(trip.routeChoices[1].userInfo as? Int, 1)
        XCTAssertEqual(trip.routeChoices[1].summaryVariants?.first, "via Broad Street")
        XCTAssertTrue(trip.routeChoices[1].additionalInformationVariants?.first?.contains("Tolls") ?? false)
        XCTAssertEqual(trip.destination.name, "Ohio Stadium")
        XCTAssertEqual((trip.userInfo as? Place)?.name, "Ohio Stadium")
    }

    func testManeuverShowsInstructionArrowAndDistance() {
        let m = CarTemplates.maneuver(route().maneuvers[1], distance: 420, imperial: false)
        XCTAssertEqual(m.instructionVariants.first, "Turn right onto Main Street")
        XCTAssertNotNil(m.symbolImage)
        XCTAssertEqual(m.initialTravelEstimates?.distanceRemaining.unit, .meters)
        XCTAssertEqual(m.initialTravelEstimates?.distanceRemaining.value, 420)
    }

    func testDistancesUseTheDriversUnits() {
        XCTAssertEqual(CarTemplates.measurement(100, imperial: true).unit, .feet)
        XCTAssertEqual(CarTemplates.measurement(5000, imperial: true).unit, .miles)
        XCTAssertEqual(CarTemplates.measurement(5000, imperial: true).value, 3.1, accuracy: 0.001)
        XCTAssertEqual(CarTemplates.measurement(5000, imperial: false).unit, .kilometers)
        XCTAssertEqual(CarTemplates.measurement(-3, imperial: false).value, 0)
    }

    func testOfflineSearchFindsSavedAndRecentPlaces() {
        var saved = SavedPlaces()
        saved.home = Place(name: "Home", address: "403 Oak Lane", lat: 1, lon: 1)
        saved.recents = [Place(name: "Lakeview Park", address: "Solon", lat: 2, lon: 2),
                         Place(name: "Gas Stop", address: "Main St", lat: 3, lon: 3)]
        XCTAssertEqual(CarTemplates.localMatches("lake", saved: saved).map(\.name), ["Lakeview Park"])
        XCTAssertEqual(CarTemplates.localMatches("oak", saved: saved).map(\.name), ["Home"])
        XCTAssertEqual(CarTemplates.localMatches("", saved: saved).count, 3)
    }

    func testListRowsAndIconsBuild() {
        let p = Place(name: "Coffee Spot", address: "1 Bean Rd", lat: 39.97, lon: -83.0, emoji: "☕")
        let row = CarTemplates.placeItem(p, near: Coord(latitude: 39.96, longitude: -83.0), imperial: true)
        XCTAssertEqual(row.text, "Coffee Spot")
        XCTAssertTrue(row.detailText?.contains("mi") ?? false)
        XCTAssertEqual((row.userInfo as? Place)?.name, "Coffee Spot")
        XCTAssertEqual(CarTemplates.emoji("⛽").size.width, 64)
        let grid = CPGridTemplate(title: "Report", gridButtons: ReportType.all.prefix(8).map {
            CPGridButton(titleVariants: [$0.label], image: CarTemplates.emoji($0.emoji)) { _ in }
        })
        XCTAssertEqual(grid.gridButtons.count, 8)
    }

    func testCarScreenDelegateIsRegistered() {
        let manifest = Bundle.main.object(forInfoDictionaryKey: "UIApplicationSceneManifest") as? [String: Any]
        let configs = manifest?["UISceneConfigurations"] as? [String: Any]
        let car = (configs?["CPTemplateApplicationSceneSessionRoleApplication"] as? [[String: Any]])?.first
        XCTAssertEqual(car?["UISceneDelegateClassName"] as? String, "Roadwise.CarPlaySceneDelegate")
        XCTAssertNotNil(NSClassFromString("Roadwise.CarPlaySceneDelegate"))
    }
}
