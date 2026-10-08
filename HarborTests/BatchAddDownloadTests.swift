import Foundation
import XCTest
@testable import Harbor

final class BatchAddDownloadTests: XCTestCase {
    func testSupportedURLsFromTextParsesOnePerLine() {
        let text = """
        https://example.com/a.zip
        https://example.com/b.dmg
        magnet:?xt=urn:btih:abcdef
        """

        let urls = DownloadSourceImportService.supportedURLs(fromText: text)

        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://example.com/a.zip",
                "https://example.com/b.dmg",
                "magnet:?xt=urn:btih:abcdef"
            ]
        )
    }

    func testSupportedURLsFromTextSkipsBlanksAndDuplicatesAndJunk() {
        let text = """
        https://example.com/a.zip

        not a url at all
        https://example.com/a.zip
        https://example.com/b.zip
        """

        let urls = DownloadSourceImportService.supportedURLs(fromText: text)

        XCTAssertEqual(
            urls.map(\.absoluteString),
            [
                "https://example.com/a.zip",
                "https://example.com/b.zip"
            ]
        )
    }

    func testTextEntriesKeepOneValidURLWhenOtherLinesAreSkipped() {
        let text = """
        https://example.com/a.zip
        not a url at all
        https://example.com/a.zip
        """

        let entries = DownloadSourceImportService.textEntries(from: text)

        XCTAssertEqual(entries.map(\.status), [.ready, .unsupported, .duplicate])
        XCTAssertEqual(
            entries.compactMap(\.url).map(\.absoluteString),
            ["https://example.com/a.zip"]
        )
    }

    func testSupportedURLsFromTextPreservesTorrentPathWithSpaces() {
        let path = "/tmp/Harbor Batch/My File.torrent"

        let urls = DownloadSourceImportService.supportedURLs(fromText: path)

        XCTAssertEqual(urls.count, 1)
        XCTAssertEqual(urls.first?.standardizedFileURL.path, path)
    }

    func testBatchRequestsShareDestinationAndStartBehavior() {
        let destination = URL(fileURLWithPath: "/tmp/harbor-batch", isDirectory: true)
        let urls = [
            URL(string: "https://example.com/a.zip")!,
            URL(string: "magnet:?xt=urn:btih:abcdef")!,
            URL(string: "https://example.com/linux.torrent")!
        ]
        let requestHeaders = [RequestHeader(name: "User-Agent", value: "Harbor")]

        let requests = AddDownloadRequest.batch(
            from: urls,
            destinationFolder: destination,
            shouldStartImmediately: false,
            requestHeaders: requestHeaders
        )

        XCTAssertEqual(requests.count, 3)
        XCTAssertTrue(requests.allSatisfy { $0.destinationFolder == destination })
        XCTAssertTrue(requests.allSatisfy { $0.shouldStartImmediately == false })
        XCTAssertTrue(requests.allSatisfy { $0.customFilename == nil })
        XCTAssertTrue(requests.allSatisfy { $0.requestHeaders == requestHeaders })

        XCTAssertEqual(requests[0].sourceKind, .directURL)
        XCTAssertEqual(requests[1].sourceKind, .magnetLink)
        XCTAssertEqual(requests[2].sourceKind, .torrentFile)
    }

    func testBatchKeepsEachResolvedMediaURLAndSkipsUnresolvedMedia() {
        let urls = DownloadSourceImportService.supportedURLs(fromText: """
        https://www.youtube.com/watch?v=first
        https://www.youtube.com/watch?v=second
        https://www.youtube.com/watch?v=unavailable
        https://example.com/archive.zip
        magnet:?xt=urn:btih:abcdef
        https://www.youtube.com/watch?v=first
        """)
        let metadata = makeMediaFormatTestFixture().metadata
        let requests = AddDownloadRequest.batch(
            from: urls,
            destinationFolder: URL(fileURLWithPath: "/tmp/harbor-batch"),
            shouldStartImmediately: false,
            tags: ["Research"],
            mediaMetadata: [urls[0]: metadata, urls[1]: metadata]
        )

        XCTAssertEqual(requests.map(\.sourceURL), [urls[0], urls[1], urls[3], urls[4]])
        XCTAssertEqual(requests.map(\.sourceKind), [.mediaURL, .mediaURL, .directURL, .magnetLink])
        XCTAssertEqual(requests.prefix(2).map(\.mediaFormatPreference), [.bestAvailable, .bestAvailable])
        XCTAssertTrue(requests.allSatisfy { !$0.shouldStartImmediately && $0.tags == ["Research"] })
    }

    func testBatchRequestsDropUnsupportedURLs() {
        let destination = URL(fileURLWithPath: "/tmp/harbor-batch", isDirectory: true)
        let urls = [
            URL(string: "https://example.com/a.zip")!,
            URL(string: "ftp://example.com/legacy")!
        ]

        let requests = AddDownloadRequest.batch(
            from: urls,
            destinationFolder: destination,
            shouldStartImmediately: true
        )

        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.sourceURL.absoluteString, "https://example.com/a.zip")
    }
}
