import Foundation
import XCTest
@testable import Harbor

@MainActor
final class AutomaticDownloadCleanupTests: XCTestCase {
    func testAutomaticCleanupDoesNotReimportCompletedWatchedTorrent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborWatchedAutoCleanup-\(UUID())")
        let watch = root.appendingPathComponent("watch")
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "HarborTests.WatchedAutoCleanup.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettingsStore(userDefaults: defaults)
        settings.removeCompletedDownloadsAutomatically = true
        settings.torrentWatchFolderPath = watch.path
        settings.torrentWatchFolderEnabled = true
        let center = DownloadCenter(settings: settings,
            persistence: DownloadPersistence(directoryURL: root.appendingPathComponent("records")))
        let payload = root.appendingPathComponent("payload.bin")
        let torrent = watch.appendingPathComponent("completed.torrent")
        let source = Data("completed torrent source".utf8)
        let bytes = Data("Keep downloaded payload".utf8)
        try bytes.write(to: payload)
        try source.write(to: torrent)
        let item = DownloadItem(
            sourceURL: torrent, sourceKind: .torrentFile, backend: .aria2,
            preferredFilename: nil, destinationFolderPath: root.path,
            fileLocationPath: payload.path, status: .seeding, finishedAt: .now,
            torrentSourceFingerprint: ManagedTorrentSourceStore.sourceFingerprint(for: source),
            torrentPayloadPaths: [payload.path], shouldSeedAfterDownload: true
        )
        center.downloads = [item]
        center.stopSeeding(id: item.id)
        for _ in 0..<200 where !center.downloads.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(center.downloads.isEmpty)
        await center.shutdownForTermination()
        XCTAssertEqual(try Data(contentsOf: payload), bytes)

        // A fresh watcher models relaunch; a new file proves both scans ran.
        let fresh = watch.appendingPathComponent("new.torrent")
        try Data("new torrent source".utf8).write(to: fresh)
        let watcher = TorrentWatchFolderService(debounceInterval: 0.01)
        var candidates: [URL] = []
        watcher.start(watching: watch) { candidates.append($0) }
        defer { watcher.stop() }
        for _ in 0..<200 where !candidates.contains(fresh) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(Set(candidates), [fresh], "Completed torrents must not return after automatic cleanup")
    }

    func testAutomaticCleanupWaitsForSeederStopAndKeepsFiles() async throws {
        for shouldFail in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborAutoCleanup-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "HarborTests.AutoCleanup.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettingsStore(userDefaults: defaults)
            settings.removeCompletedDownloadsAutomatically = true
            let persistence = DownloadPersistence(directoryURL: root.appendingPathComponent("records"))
            let gate = AsyncTestGate()
            let center = DownloadCenter(settings: settings, persistence: persistence,
                torrentRemoveOperation: { _, _ in
                    await gate.wait()
                    if shouldFail { throw CocoaError(.fileWriteUnknown) }
                })
            let payload = root.appendingPathComponent("payload.bin")
            let torrent = root.appendingPathComponent("source.torrent")
            let bytes = Data("Keep the downloaded file".utf8)
            try bytes.write(to: payload)
            try Data("Keep the source torrent".utf8).write(to: torrent)
            let item = DownloadItem(
                sourceURL: torrent, sourceKind: .torrentFile, backend: .aria2,
                preferredFilename: nil, destinationFolderPath: root.path,
                fileLocationPath: payload.path, status: .seeding, finishedAt: .now,
                backendIdentifier: "test-seeder", torrentPayloadPaths: [payload.path],
                shouldSeedAfterDownload: true
            )
            center.downloads = [item]
            center.stopSeeding(id: item.id)
            for _ in 0..<100 where item.shouldSeedAfterDownload {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertFalse(item.shouldSeedAfterDownload)
            XCTAssertEqual(center.downloads.count, 1, "Keep the entry until the engine stops")
            await gate.release()
            for _ in 0..<200 {
                if shouldFail ? item.lastError != nil : center.downloads.isEmpty { break }
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(center.downloads.isEmpty, !shouldFail)
            XCTAssertEqual(try Data(contentsOf: payload), bytes)
            XCTAssertTrue(FileManager.default.fileExists(atPath: torrent.path))
            let records = try await persistence.load()
            XCTAssertEqual(records.isEmpty, !shouldFail)
            await center.shutdownForTermination()
        }
    }
}
