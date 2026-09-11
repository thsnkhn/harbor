import XCTest

@MainActor
final class HarborMediaTorrentUITests: HarborUITestCase {
    func testLocalMediaPreviewAndDownloadUseBundledRuntime() throws {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(fixtureURL("/media/page").absoluteString)

        let tryMedia = app.buttons["add-download.try-as-media"].firstMatch
        XCTAssertTrue(tryMedia.waitForExistence(timeout: 5))
        tryMedia.click()
        let mediaMetadata = app.descendants(matching: .any)["add-download.media-metadata"].firstMatch
        XCTAssertTrue(mediaMetadata.waitForExistence(timeout: 120))
        XCTAssertTrue(
            mediaMetadata.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", "Harbor Synthetic Media", "Harbor Synthetic Media")
            ).firstMatch.exists
        )

        let submit = app.buttons["add-download.submit"].firstMatch
        XCTAssertTrue(submit.isEnabled)
        let existingDownloads = downloadReferences()
        submit.click()
        let download = waitForNewDownload(excluding: existingDownloads)
        waitForStatus("Completed", download: download, timeout: 120)
        let mediaFile = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: downloadsURL, includingPropertiesForKeys: nil)
                .first { $0.pathExtension.lowercased() == "mp4" }
        )
        XCTAssertEqual(
            try sha256(of: mediaFile),
            ProcessInfo.processInfo.environment["HARBOR_FIXTURE_MEDIA_SHA256"]
        )
    }

    func testRemoteTorrentPreviewSupportsPartialSelection() {
        launchHarbor()
        openAddSheet()

        let source = app.textFields["add-download.source"].firstMatch
        source.click()
        source.typeText(fixtureURL("/torrents/multi.torrent").absoluteString)
        let preview = app.buttons["add-download.preview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()

        let torrent = HarborTorrentPreviewPage(app: app)
        XCTAssertTrue(torrent.add.waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label == %@ OR value == %@", "Harbor UI Fixture", "Harbor UI Fixture")
            ).firstMatch.exists
        )
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS '2 files' OR value CONTAINS '2 files'")
            ).firstMatch.exists
        )
        torrent.selectNone.click()
        XCTAssertFalse(torrent.add.isEnabled)
        torrent.selectAll.click()
        XCTAssertTrue(torrent.add.isEnabled)
    }

    func testMagnetPersistsAsPausedDownload() {
        guard let magnet = URL(string: "magnet:?xt=urn:btih:0000000000000000000000000000000000000000&dn=HarborUITestMagnet") else {
            return XCTFail("Invalid fixture magnet")
        }
        launchHarbor()
        let download = addLink(magnet, startImmediately: false)
        waitForStatus("Paused", download: download)
        XCTAssertTrue(app.staticTexts["HarborUITestMagnet"].exists)

        app.terminate()
        launchHarbor()
        waitForStatus("Paused", download: download)
        XCTAssertTrue(app.staticTexts["HarborUITestMagnet"].exists)
    }

    func testHTMLResponseOffersBrowserContinuation() {
        launchHarbor()
        let download = addLink(fixtureURL("/errors/html.bin"))
        waitForStatus("Browser Session Required", download: download, timeout: 30)
        selectDownload(named: "html.bin")
        XCTAssertTrue(app.buttons["Continue"].waitForExistence(timeout: 5))
        app.buttons["Continue"].click()
        let browser = HarborBrowserPage(app: app)
        XCTAssertTrue(browser.sheet.waitForExistence(timeout: 15))
        let fixtureDownloadLink = app.links["Download fixture"].firstMatch
        XCTAssertTrue(fixtureDownloadLink.waitForExistence(timeout: 15))
        fixtureDownloadLink.click()
        waitForStatus("Completed", download: download, timeout: 30)
        XCTAssertFalse(browser.sheet.waitForExistence(timeout: 2))
    }

    func testCheckFilesVerifiesExistingTorrentWithoutChangingPayload() throws {
        launchHarbor()
        let download = addLink(fixtureURL("/torrents/webseed.torrent"))
        waitForStatus("Completed", download: download, timeout: 60)

        let file = torrentDownloadsURL.appendingPathComponent("harbor-webseed.bin")
        let originalHash = try sha256(of: file)
        XCTAssertEqual(originalHash, "c057102af0d868b2e267e418e9ccbdb821f265a8860d949d9ae2179963bd2cea")
        let originalModificationDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let originalPayloadRequests = try fixtureRequests(for: "/direct/small.bin").count

        func assertPayloadUnchanged() throws {
            XCTAssertEqual(try sha256(of: file), originalHash)
            XCTAssertEqual(
                try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                originalModificationDate,
                "Checking must not modify the existing payload."
            )
            XCTAssertEqual(
                try fixtureRequests(for: "/direct/small.bin").count,
                originalPayloadRequests,
                "Checking must not download payload pieces."
            )
        }

        downloadTablePage.name("harbor-webseed.bin").rightClick()
        let checkFiles = app.menuItems["Check Files…"].firstMatch
        XCTAssertTrue(checkFiles.waitForExistence(timeout: 5))
        checkFiles.click()

        let sheet = app.descendants(matching: .any)["torrent.checkSheet"].firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", file.path, file.path)
        ).firstMatch.exists, "The known payload location must be selected without a file dialog.")

        let check = app.buttons["torrent.beginCheck"].firstMatch
        XCTAssertTrue(check.waitForExistence(timeout: 5))
        let checkReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: check)
        wait(for: [checkReady], timeout: 15)
        check.click()

        XCTAssertTrue(app.staticTexts["All Pieces Verified"].waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["torrent.checkAgain"].exists)
        XCTAssertFalse(app.buttons["torrent.downloadMissingPieces"].exists)
        app.buttons["torrent.checkKeepStopped"].click()
        waitForStatus("Completed", download: download)

        try assertPayloadUnchanged()
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: sheet)], timeout: 5)

        // Re-import the retained payload through normal Add Download to cover collision detection.
        downloadTablePage.name("harbor-webseed.bin").rightClick()
        let remove = app.menuItems["Remove from List"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        remove.click()
        let oldRow = app.descendants(matching: .any)["downloads.row.\(download.id)"].firstMatch
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: oldRow)], timeout: 10)
        try assertPayloadUnchanged()

        let existingDownloads = downloadReferences()
        openAddSheet()
        addDownloadPage.source.click()
        addDownloadPage.source.typeText(fixtureURL("/torrents/webseed.torrent").absoluteString)
        let startToggle = addDownloadPage.startImmediately
        if startToggle.value as? Int != 1 { startToggle.click() }
        addDownloadPage.submit.click()

        let checkExisting = app.buttons["torrent.checkExistingFiles"].firstMatch
        XCTAssertTrue(checkExisting.waitForExistence(timeout: 15), "Normal add must offer Check when the payload already exists.")
        XCTAssertTrue(checkExisting.isEnabled)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label == %@ OR value == %@", file.path, file.path)
        ).firstMatch.exists)
        XCTAssertEqual(downloadReferences(), existingDownloads, "Collision review must precede queueing the torrent.")
        try assertPayloadUnchanged()
        checkExisting.click()

        let importedDownload = waitForNewDownload(excluding: existingDownloads)
        XCTAssertTrue(sheet.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["All Pieces Verified"].waitForExistence(timeout: 60))
        XCTAssertFalse(app.buttons["torrent.downloadMissingPieces"].exists)
        let startSeeding = app.sheets.firstMatch.buttons["Start Seeding"].firstMatch
        XCTAssertTrue(startSeeding.waitForExistence(timeout: 5))
        wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: startSeeding)], timeout: 15)
        startSeeding.click()
        waitForStatus("Seeding", download: importedDownload, timeout: 60)
        try assertPayloadUnchanged()
    }

    func testWebseedTorrentCompletesWithExpectedPayload() throws {
        launchHarbor()
        openAddSheet()
        addDownloadPage.source.click()
        addDownloadPage.source.typeText(fixtureURL("/torrents/webseed.torrent").absoluteString)
        addDownloadPage.preview.click()
        let torrent = HarborTorrentPreviewPage(app: app)
        XCTAssertTrue(torrent.add.waitForExistence(timeout: 15))
        let existingDownloads = downloadReferences()
        torrent.add.click()
        let download = waitForNewDownload(excluding: existingDownloads)
        waitForStatus("Completed", download: download, timeout: 60)
        let file = torrentDownloadsURL.appendingPathComponent("harbor-webseed.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(
            try sha256(of: file),
            "c057102af0d868b2e267e418e9ccbdb821f265a8860d949d9ae2179963bd2cea"
        )
    }
}
