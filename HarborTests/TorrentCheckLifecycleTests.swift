import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentCheckLifecycleTests: XCTestCase {
    func testResumeCannotApproveMissingPieceDownload() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = DownloadCenter(settings: AppSettingsStore(userDefaults: defaults),
                                    persistence: DownloadPersistence(directoryURL: root))
        let item = makeTorrent(state: .incomplete)
        center.downloads = [item]
        center.resumeDownloads(ids: [item.id])
        XCTAssertEqual(center.checkingTorrentID, item.id)
        XCTAssertEqual(item.torrentCheckState, .incomplete)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.status, .paused)
        await center.shutdownForTermination()
    }

    func testSeedingCannotBypassIncompleteCheck() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let center = DownloadCenter(settings: AppSettingsStore(userDefaults: defaults),
                                    persistence: DownloadPersistence(directoryURL: root))
        let item = makeTorrent(state: .incomplete)
        item.finishedAt = .now
        center.downloads = [item]
        center.startSeeding(id: item.id)
        XCTAssertEqual(center.checkingTorrentID, item.id)
        XCTAssertFalse(item.shouldSeedAfterDownload)
        XCTAssertEqual(item.torrentCheckState, .incomplete)
        await center.shutdownForTermination()
    }

    func testCheckApprovalGateSurvivesRecordRoundTrip() throws {
        for state in [TorrentCheckState.pending, .checking, .complete, .incomplete, .error] {
            let item = makeTorrent(state: state)
            let data = try JSONEncoder().encode(item.makeRecord())
            let record = try JSONDecoder().decode(DownloadRecord.self, from: data)
            let restored = DownloadItem(record: record)
            XCTAssertEqual(restored.torrentCheckState, state)
            XCTAssertEqual(restored.torrentExistingDataPath, "/tmp/existing/payload")
        }
    }

    func testLegacyRecordDoesNotAcquireCheckGate() throws {
        let data = try JSONEncoder().encode(makeTorrent(state: .pending).makeRecord())
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "torrentCheckState")
        object.removeValue(forKey: "torrentExistingDataPath")
        let record = try JSONDecoder().decode(DownloadRecord.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(record.torrentCheckState)
        XCTAssertNil(record.torrentExistingDataPath)
    }

    private func makeTorrent(state: TorrentCheckState) -> DownloadItem {
        DownloadItem(sourceURL: URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!,
                     sourceKind: .magnetLink, backend: .aria2, preferredFilename: nil,
                     destinationFolderPath: "/tmp/existing", status: .paused,
                     torrentCheckState: state, torrentExistingDataPath: "/tmp/existing/payload",
                     shouldSeedAfterDownload: false)
    }
}
