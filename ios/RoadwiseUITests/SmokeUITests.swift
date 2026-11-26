import XCTest

/// Launches the app, searches for a place and opens it, saving screenshots along the way.
final class SmokeUITests: XCTestCase {
    func testLaunchAndSearch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ROADWISE_TEST_ORIGIN"] = "39.9612,-82.9988"   // downtown Columbus, OH
        app.launch()

        // Allow the location prompt if it appears.
        addUIInterruptionMonitor(withDescription: "Location") { alert in
            for label in ["Allow While Using App", "Allow Once", "OK"] where alert.buttons[label].exists {
                alert.buttons[label].tap(); return true
            }
            return false
        }

        let search = app.textFields["Search Roadwise"]
        XCTAssertTrue(search.waitForExistence(timeout: 20), "Search bar should appear")
        attach(app, "1-home")

        search.tap()
        search.typeText("Ohio Stadium")
        let directions = app.buttons["Directions"]
        let firstResult = app.buttons.containing(NSPredicate(format: "label CONTAINS[c] %@", "Ohio Stadium")).firstMatch
        if firstResult.waitForExistence(timeout: 20) {
            attach(app, "2-results")
            firstResult.tap()
            XCTAssertTrue(directions.waitForExistence(timeout: 10), "Place card should show Directions")
            attach(app, "3-place")

            // Plan a route and drive it in preview mode.
            directions.tap()
            let preview = app.buttons["Preview"]
            XCTAssertTrue(preview.waitForExistence(timeout: 30), "Routes should load")
            let enabled = NSPredicate(format: "isEnabled == true")
            expectation(for: enabled, evaluatedWith: preview)
            waitForExpectations(timeout: 30)
            attach(app, "4-routes")
            preview.tap()
            XCTAssertTrue(app.buttons["End"].waitForExistence(timeout: 10), "Navigation should start")
            sleep(8)
            attach(app, "5-navigation")
            app.buttons["End"].tap()
        } else {
            attach(app, "2-no-results")
        }

        // Settings > Offline maps lists the downloadable states.
        let settings = app.buttons["Settings"]
        if settings.waitForExistence(timeout: 10) {
            settings.tap()
            let offline = app.buttons["Offline maps"]
            XCTAssertTrue(offline.waitForExistence(timeout: 10), "Settings should have Offline maps")
            offline.tap()
            XCTAssertTrue(app.navigationBars["Offline maps"].waitForExistence(timeout: 10))
            _ = app.staticTexts["Iowa"].waitForExistence(timeout: 20)
            attach(app, "6-offline-maps")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
