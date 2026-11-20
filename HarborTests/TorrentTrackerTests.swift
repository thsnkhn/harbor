import Foundation
import XCTest
@testable import Harbor

final class TorrentTrackerTests: XCTestCase {
    func testDecodesAria2NextTrackerStatus() throws {
        let tracker = try XCTUnwrap(
            JSONDecoder().decode(
                [TorrentTracker].self,
                from: Data(
                    #"[{"url":"https://tracker.example/announce","source":"magnet","tier":"2","status":"working","failures":"0","seeders":"12","leechers":"3","downloads":"20","nextAnnounce":"45","minAnnounce":"30","updating":"false","verified":"true","endpoints":[]}]"#.utf8
                )
            ).first
        )

        XCTAssertEqual(tracker.url, "https://tracker.example/announce")
        XCTAssertEqual(tracker.tierNumber, 2)
        XCTAssertEqual(tracker.tierText, "Tier 2")
        XCTAssertFalse(tracker.isRemovable)
        XCTAssertEqual(tracker.statusText, "Working")
        XCTAssertEqual(tracker.peerCountText, "12 seeders, 3 leechers")
        XCTAssertEqual(tracker.failureCountText, "0 failures")
        XCTAssertEqual(tracker.nextAnnounceText, "Next announce in 45 seconds")
        XCTAssertNil(tracker.message)

        let addedTracker = try JSONDecoder().decode(
            [TorrentTracker].self,
            from: Data(
                #"[{"url":"udp://tracker.example:6969/announce","source":"global","tier":"3","status":"working","seeders":"-1","leechers":"-1","updating":"false"}]"#.utf8
            )
        )[0]
        XCTAssertTrue(addedTracker.isRemovable)
    }

    func testTrackerURLValidationAcceptsSupportedSchemes() throws {
        for url in [
            "https://tracker.example/announce",
            "http://tracker.example/announce",
            "udp://tracker.example:6969/announce"
        ] {
            XCTAssertEqual(try TorrentTrackerError.normalizedURL(" \(url) "), url)
        }
    }

    func testTrackerURLValidationRejectsUnsupportedOrIncompleteURLs() {
        for url in ["tracker.example", "ftp://tracker.example", "https:///announce"] {
            XCTAssertThrowsError(try TorrentTrackerError.normalizedURL(url)) { error in
                XCTAssertEqual(error as? TorrentTrackerError, .invalidURL)
            }
        }
    }

    func testTrackerListParserSkipsBlankLinesCommentsAndInvalidURLs() {
        let text = """
        # Trackers
        udp://tracker.example:6969/announce

        https://tracker.example/announce # primary
          http://tracker.example:80/announce  \r
        not a tracker
        ftp://tracker.example/announce
        udp://tracker.example:6969/announce
        #udp://commented.example:1337/announce
        """

        XCTAssertEqual(
            TorrentTrackerListParser.trackers(from: text),
            [
                "udp://tracker.example:6969/announce",
                "https://tracker.example/announce",
                "http://tracker.example:80/announce"
            ]
        )
    }

    func testTrackerListParserRejectsInvalidData() {
        XCTAssertThrowsError(try TorrentTrackerListParser.trackers(from: Data([0xFF, 0xFE]))) { error in
            XCTAssertEqual(error as? TorrentTrackerListError, .invalidEncoding)
        }
        XCTAssertThrowsError(
            try TorrentTrackerListParser.trackers(
                from: Data(count: TorrentTrackerListParser.maximumBytes + 1)
            )
        ) { error in
            XCTAssertEqual(error as? TorrentTrackerListError, .tooLarge)
        }
    }

    func testTrackerFileImportRejectsMoreThanOneMegabyte() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data("https://tracker.example/announce\n#".utf8)
        data.append(Data(repeating: 0x20, count: 1_000_000 - data.count))
        try data.write(to: file)
        XCTAssertEqual(try TorrentTrackerListLoader.trackers(fromFileAt: file), ["https://tracker.example/announce"])

        data.append(0x20)
        try data.write(to: file)
        XCTAssertThrowsError(try TorrentTrackerListLoader.trackers(fromFileAt: file)) { error in
            XCTAssertEqual(error as? TorrentTrackerListError, .tooLarge)
        }
    }

    @MainActor
    func testTrackerListsStayDisjointAndPersist() throws {
        let suiteName = "HarborTests.TorrentTrackerLists.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let first = "udp://one.example:6969/announce"
        let second = "https://two.example/announce"
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.addTorrentTrackers([first, second], to: .added)
        settings.addTorrentTrackers([first], to: .added)
        settings.addTorrentTrackers([second], to: .excluded)

        XCTAssertEqual(settings.torrentAddedTrackers, [first])
        XCTAssertEqual(settings.torrentExcludedTrackers, [second])

        settings.removeTorrentTrackers([first], from: .added)
        let reloaded = AppSettingsStore(userDefaults: userDefaults)
        XCTAssertEqual(reloaded.torrentAddedTrackers, [])
        XCTAssertEqual(reloaded.torrentExcludedTrackers, [second])
    }

    func testDownloadOptionsIncludeTrackerListsOnlyWhenPresent() {
        let options = Aria2TorrentService.downloadOptions(
            destinationFolderPath: "/tmp/downloads",
            transferSettings: .default,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: false,
                addedTrackers: ["udp://one.example:6969/announce", "https://two.example/announce"],
                excludedTrackers: ["udp://bad.example:1337/announce"]
            )
        )
        XCTAssertEqual(options["bt-tracker"], "udp://one.example:6969/announce,https://two.example/announce")
        XCTAssertEqual(options["bt-exclude-tracker"], "udp://bad.example:1337/announce")

        let defaultOptions = Aria2TorrentService.downloadOptions(
            destinationFolderPath: "/tmp/downloads",
            transferSettings: .default,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: false
            )
        )
        XCTAssertNil(defaultOptions["bt-tracker"])
        XCTAssertNil(defaultOptions["bt-exclude-tracker"])
    }
}
