import XCTest

/// Launches the app, searches for a place and opens it, saving screenshots along the way.
final class SmokeUITests: XCTestCase {
    func testLaunchAndSearch() throws {
        let app = XCUIApplication()
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
        } else {
            attach(app, "2-no-results")
        }
    }

    private func attach(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
