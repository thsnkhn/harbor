import XCTest

@MainActor
final class HarborLaunchUITests: HarborUITestCase {
    func testLaunchNavigationSearchAndAddSheet() {
        launchHarbor()

        XCTAssertEqual(app.windows.count, 1, "Harbor must open one window during UI tests")
        XCTAssertTrue(app.staticTexts["No Downloads Yet"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["toolbar.new-download"].exists)
        XCTAssertTrue(app.outlines["harbor.sidebar"].exists || app.otherElements["harbor.sidebar"].exists)

        openAddSheet()
        let sourceMode = app.descendants(matching: .any)["add-download.source-mode"].firstMatch
        XCTAssertTrue(sourceMode.waitForExistence(timeout: 5))
        XCTAssertTrue(sourceMode.isHittable)
        XCTAssertTrue(app.textFields["add-download.source"].exists)
        XCTAssertTrue(app.buttons["add-download.submit"].exists)
        app.buttons["add-download.cancel"].click()
        XCTAssertFalse(app.otherElements["add-download.sheet"].waitForExistence(timeout: 1))
    }

    func testBatchEntryShowsReadyDuplicateAndUnsupportedCounts() {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(fixtureURL("/direct/small.bin").absoluteString)
        source.typeKey(.return, modifierFlags: [.option])
        source.typeText("not-a-link")
        source.typeKey(.return, modifierFlags: [.option])
        source.typeText(fixtureURL("/direct/small.bin").absoluteString)

        let ready = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'Ready' OR value ==[c] 'Ready'")
        ).firstMatch
        let duplicate = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'Duplicate' OR value ==[c] 'Duplicate'")
        ).firstMatch
        let skipped = app.staticTexts.matching(
            NSPredicate(format: "label ==[c] 'Skipped' OR value ==[c] 'Skipped'")
        ).firstMatch

        XCTAssertTrue(ready.waitForExistence(timeout: 5))
        XCTAssertTrue(duplicate.waitForExistence(timeout: 5))
        XCTAssertTrue(skipped.waitForExistence(timeout: 5))
    }
}
