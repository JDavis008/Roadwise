import XCTest
@testable import Roadwise

/// Offline maps end to end on a simulator: unpack a real state-style pack (a small Cedar Rapids,
/// Iowa build made by tools/ios-offline), then plan a route with the on-phone Valhalla engine
/// and search the offline index. No network is used.
final class OfflineTests: XCTestCase {
    private static var data: OfflineData!
    private static let state = OfflineState(id: "test", name: "Cedar Rapids", abbr: "CR", bbox: [41.95, -91.72, 42.02, -91.62],
                                            url: "", bytes: 0, unpackedBytes: 0, sha256: "", tiles: 0)
    private static var pack: URL { Bundle(for: OfflineTests.self).url(forResource: "cedar-rapids", withExtension: "tar.xz")! }

    override class func setUp() {
        super.setUp()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-test-\(UUID().uuidString)")
        let d = OfflineData(root: root, configName: "test-valhalla.json")
        do { try d.install(packFile: pack, state: state, verify: false) } catch { XCTFail("install: \(error)") }
        data = d
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: data.root)
        super.tearDown()
    }

    func testPackIsIntactAndUnpacks() throws {
        XCTAssertEqual(try OfflineData.sha256(Self.pack), "9b6405919db07d11b9de98193f235075c09537970e937eb12e47b27708e360ac")
        let files = Self.data.installed["test"]?.files ?? []
        XCTAssertTrue(files.contains("places/iowa.sqlite"))
        XCTAssertEqual(files.filter { $0.hasSuffix(".gph") }.count, 6)
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.data.root.appendingPathComponent("valhalla_tiles/2/000/759/233.gph").path))
        XCTAssertTrue(Self.data.covers(Coord(latitude: 41.98, longitude: -91.67)))
        XCTAssertFalse(Self.data.covers(Coord(latitude: 40.0, longitude: -83.0)))
    }

    func testPlansARouteOnThePhone() async throws {
        let from = Coord(latitude: 41.977, longitude: -91.668), to = Coord(latitude: 42.005, longitude: -91.645)
        let routes = try await RoutingService.offlineRoutes(from: from, to: to, mode: .drive, options: RouteOptions(), data: Self.data)
        let r = try XCTUnwrap(routes.first)
        XCTAssertGreaterThan(r.distance, 2500)
        XCTAssertLessThan(r.distance, 12000)
        XCTAssertGreaterThan(r.duration, 60)
        XCTAssertGreaterThanOrEqual(r.maneuvers.count, 3)
        XCTAssertEqual(r.maneuvers.last?.turn, .arrive)
        XCTAssertTrue(r.maneuvers.contains { !($0.street ?? "").isEmpty }, "turns should name streets")
        XCTAssertLessThan(Geo.dist(r.points.last!, to), 300)
    }

    func testWalkingAndBikeRoutesWorkOffline() async throws {
        let from = Coord(latitude: 41.977, longitude: -91.668), to = Coord(latitude: 41.985, longitude: -91.66)
        for mode in [TravelMode.walk, .bike] {
            let r = try await RoutingService.offlineRoutes(from: from, to: to, mode: mode, options: RouteOptions(), data: Self.data)
            XCTAssertFalse(r.isEmpty, "\(mode)")
        }
    }

    func testSearchFindsStreetsTownsAndPlaces() {
        let near = Coord(latitude: 41.98, longitude: -91.66)
        let coe = Self.data.search.search("coe rd", near: near)
        XCTAssertTrue(coe.contains { $0.name.lowercased().contains("coe") }, "\(coe.map(\.name))")
        let city = Self.data.search.search("cedar rapids", near: near)
        XCTAssertEqual(city.first?.name, "Cedar Rapids")
        let food = Self.data.search.nearby(label: "Food", emoji: "🍔", near: near)
        XCTAssertGreaterThan(food.count, 5)
        XCTAssertEqual(food.first?.emoji, "🍔")
        XCTAssertNotNil(Self.data.search.reverse(Coord(latitude: 41.977, longitude: -91.668)))
        XCTAssertTrue(Self.data.search.search("zzqqxx", near: near).isEmpty)
    }

    func testRemovingAStateDeletesItsFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("offline-rm-\(UUID().uuidString)")
        let d = OfflineData(root: root, configName: "test-rm.json")
        try d.install(packFile: Self.pack, state: Self.state, verify: false)
        XCTAssertTrue(d.hasData)
        try d.remove("test")
        XCTAssertFalse(d.hasData)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("places/iowa.sqlite").path))
        XCTAssertTrue(d.search.isEmpty)
        try? FileManager.default.removeItem(at: root)
    }

    func testStateMapSizeEstimate() {
        // Iowa-sized box at zoom 0-14: tens of thousands of tiles.
        let n = OfflineStore.tileCount([40.37, -96.64, 43.5, -90.14], maxZoom: 14)
        XCTAssertGreaterThan(n, 50_000)
        XCTAssertLessThan(n, 200_000)
    }
}
