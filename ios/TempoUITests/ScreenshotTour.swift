import XCTest

/// Walks the app and photographs it.
///
/// The oldest constraint on this project is that nobody but David can see Tempo run — every
/// change ships as "compiles, tests pass, needs device check." A simulator pointed at the
/// staging backend (see `SupabaseConfig`) removes the backend half of that. This removes the
/// rest: a scripted tour that opens each screen and attaches a screenshot, so a UI change can
/// be reviewed by looking at it.
///
/// Deliberately in its own scheme (`TempoUI`). CI runs the `Tempo` scheme, and these need a
/// booted simulator and a live backend — neither belongs in the gate that guards every PR.
///
/// This is a tour, not an assertion suite. It fails only when a screen it expects to reach is
/// unreachable; it does not police pixels. Screenshots land in the .xcresult bundle:
///
///   xcodebuild -scheme TempoUI -destination '...' -resultBundlePath /tmp/tour.xcresult test
///   xcrun xcresulttool export attachments --path /tmp/tour.xcresult --output-path /tmp/shots
final class ScreenshotTour: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    func testTourTheApp() {
        let app = XCUIApplication()
        app.launch()

        // The launch sequence is two network round trips before anything renders.
        XCTAssertTrue(
            app.staticTexts["Today"].waitForExistence(timeout: 30),
            "Never reached the Today screen — the app is stuck on the splash or the launch error."
        )
        shoot(app, "01-today")

        tab(app, "Progress")
        shoot(app, "02-progress")

        // Progress → the archive. Two doorways exist; the footer link is the stable one.
        let doorway = app.staticTexts["Browse every run"]
        if doorway.waitForExistence(timeout: 5) {
            doorway.tap()
            XCTAssertTrue(app.staticTexts["History"].waitForExistence(timeout: 15), "History never appeared")
            shoot(app, "03-history-top")

            // Past the totals and the wall, into the archive itself.
            app.swipeUp()
            shoot(app, "04-history-records")
            app.swipeUp()
            app.swipeUp()
            shoot(app, "05-history-archive")
        } else {
            shoot(app, "03-history-doorway-missing")
        }

        tab(app, "Plan")
        shoot(app, "06-plan")
        tab(app, "You")
        shoot(app, "07-you")
    }

    // MARK: - Helpers

    /// The tab bar is a plain `HStack` of `Button`s, so each tab is addressable by its label.
    private func tab(_ app: XCUIApplication, _ name: String) {
        let button = app.buttons[name]
        if button.waitForExistence(timeout: 10) {
            button.tap()
        } else {
            app.staticTexts[name].firstMatch.tap()
        }
        sleep(2)   // let the screen settle before the shutter
    }

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways   // .deleteOnSuccess would throw away the whole point
        add(shot)
    }
}
