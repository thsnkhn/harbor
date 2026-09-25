import XCTest
@testable import Harbor

@MainActor
final class DownloadTagTests: XCTestCase {
    func testNormalizationAndBatchTags() {
        XCTAssertEqual(DownloadTags.normalized([" #Work ", "work", "", "client-work", "two words", "#", "Café", "Cafe\u{301}"]),
                       ["Work", "client-work", "Café"])
        let requests = AddDownloadRequest.batch(
            from: [URL(string: "https://example.test/a")!, URL(string: "magnet:?xt=urn:btih:abcdef")!],
            destinationFolder: URL(fileURLWithPath: "/tmp"), shouldStartImmediately: false,
            tags: ["#Work", "work"]
        )
        XCTAssertEqual(requests.map(\.tags), [["Work"], ["Work"]])
    }

    func testRecordRoundTripAndOldHistory() throws {
        let item = makeItem(tags: ["Work"])
        let data = try JSONEncoder().encode(item.makeRecord())
        let restored = DownloadItem(record: try JSONDecoder().decode(DownloadRecord.self, from: data))
        XCTAssertEqual(restored.tags, ["Work"])
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "tags")
        let oldData = try JSONSerialization.data(withJSONObject: legacy)
        XCTAssertEqual(try JSONDecoder().decode(DownloadRecord.self, from: oldData).tags, [])
    }

    func testTransferRollbackPreservesNewerTagEdits() {
        let item = makeItem(tags: ["Work"])
        let snapshot = item.makeRecord()
        item.tags = ["Personal"]
        item.status = .completed
        item.restorePersistedState(from: snapshot)
        XCTAssertEqual(item.status, .paused)
        XCTAssertEqual(item.makeRecord().tags, ["Personal"])
    }

    func testStatusSearchAndTagIntersectionPrunesSelection() {
        let center = makeCenter()
        let first = makeItem(tags: ["Work", "video"])
        let second = makeItem(tags: ["Work"], status: .completed)
        center.downloads = [first, second]
        center.selectedDownloadID = second.id
        center.selectedTags = ["video"]
        XCTAssertEqual(center.filteredDownloads.map(\.id), [first.id])
        XCTAssertTrue(center.selectedDownloadIDs.isEmpty)
        center.selectedTags = ["work", "video"]
        XCTAssertEqual(center.filteredDownloads.map(\.id), [first.id])
        center.matchesAllTags = false
        XCTAssertEqual(center.filteredDownloads.count, 2)
        center.selectedFilter = .completed
        center.searchText = "#WORK"
        XCTAssertEqual(center.filteredDownloads.map(\.id), [second.id])
        center.searchText = "missing"
        XCTAssertTrue(center.filteredDownloads.isEmpty)
    }

    func testRenameMergeDeleteAndCanonicalCasing() {
        let center = makeCenter()
        let first = makeItem(tags: ["Work", "home"])
        let second = makeItem(tags: ["home"])
        center.downloads = [first, second]
        center.setTags(["work", "#video"], for: second.id)
        XCTAssertEqual(second.tags, ["Work", "video"])
        center.selectedTags = ["work"]
        center.renameTag("Work", to: "home")
        XCTAssertEqual(first.tags, ["home"])
        XCTAssertEqual(second.tags, ["home", "video"])
        XCTAssertEqual(center.selectedTags, ["home"])
        center.deleteTag("home")
        XCTAssertEqual(first.tags, [])
        XCTAssertEqual(center.availableTags, ["video"])
        XCTAssertTrue(center.selectedTags.isEmpty)
    }

    private func makeItem(tags: [String], status: DownloadStatus = .paused) -> DownloadItem {
        DownloadItem(sourceURL: URL(string: "https://example.test/file.zip")!, sourceKind: .directURL,
                     backend: .urlSession, preferredFilename: nil, destinationFolderPath: "/tmp",
                     status: status, tags: tags)
    }

    private func makeCenter() -> DownloadCenter {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborTagTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return DownloadCenter(settings: HarborTestFixtures.makeSettings(),
                              persistence: DownloadPersistence(directoryURL: root),
                              recordSaveOperation: { _, _, _ in })
    }
}
