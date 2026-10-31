import XCTest

@MainActor
final class HarborSettingsUITests: HarborUITestCase {
    func testSettingsNavigationAndPersistedDownloadControls() {
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])

        selectSettingsPane("downloads")
        let startImmediately = app.switches["settings.downloads.startImmediately"].firstMatch
        XCTAssertTrue(startImmediately.waitForExistence(timeout: 10))
        let originalValue = String(describing: startImmediately.value)
        startImmediately.click()

        let toggleChanged = XCTNSPredicateExpectation(
            predicate: NSPredicate { object, _ in
                guard let toggle = object as? XCUIElement else { return false }
                return String(describing: toggle.value) != originalValue
            },
            object: startImmediately
        )
        XCTAssertEqual(XCTWaiter.wait(for: [toggleChanged], timeout: 5), .completed)
        let toggledValue = String(describing: startImmediately.value)

        app.typeKey("w", modifierFlags: [.command])
        app.terminate()
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])
        let restoredControl = app.switches["settings.downloads.startImmediately"].firstMatch
        XCTAssertTrue(restoredControl.waitForExistence(timeout: 10), "Settings must reopen the last category")
        XCTAssertEqual(String(describing: restoredControl.value), toggledValue)

        for pane in ["general", "downloads", "media", "torrents", "bandwidth", "network", "extensions"] {
            selectSettingsPane(pane)
            XCTAssertTrue(app.scrollViews["settings.\(pane)"].firstMatch.waitForExistence(timeout: 5))
        }
        XCTAssertTrue(app.staticTexts["Extensions are experimental. More features are coming."].exists)
    }

    func testNetworkPaneOffersTorrentInterfaceBinding() {
        launchHarbor()
        app.typeKey(",", modifierFlags: [.command])

        selectSettingsPane("network")

        let interfacePicker = app.popUpButtons["settings.torrents.networkInterface"].firstMatch
        XCTAssertTrue(interfacePicker.waitForExistence(timeout: 10))
        XCTAssertEqual(String(describing: interfacePicker.value), "Automatic")
    }
    private func selectSettingsPane(_ name: String) {
        let item = app.toolbars.buttons[name.capitalized].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 10), "Missing settings category \(name)")
        item.click()
    }

}
