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
}
