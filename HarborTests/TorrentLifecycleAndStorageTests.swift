import Darwin
import CryptoKit
import Foundation
import XCTest
@testable import Harbor

@MainActor
final class TorrentLifecycleAndStorageTests: XCTestCase {
    func testPausingSeederStopsSeedingAndMarksItCompleted() async {
        let suiteName = "HarborTests.SeedingLifecycle.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let persistenceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborSeedingLifecycleTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceDirectoryURL) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceDirectoryURL)
        )
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .seeding,
            finishedAt: .now,
            backendIdentifier: nil,
            shouldSeedAfterDownload: true
        )
        center.downloads = [item]

        center.pauseDownloads(ids: [item.id])

        XCTAssertEqual(item.status, .completed)
        XCTAssertFalse(item.shouldSeedAfterDownload)
        XCTAssertNil(item.backendIdentifier)
        XCTAssertEqual(item.activityEvents.last?.kind, .seedingStopped)
        await center.shutdownForTermination()
    }

    func testPausedSeederIsNotCancellableAsAFreshDownload() async {
        let suiteName = "HarborTests.PausedSeederCancellation.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let persistenceDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborPausedSeederTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: persistenceDirectoryURL) }

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceDirectoryURL)
        )
        let item = DownloadItem(
            sourceURL: URL(fileURLWithPath: "/tmp/example.torrent"),
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .paused,
            finishedAt: .now,
            backendIdentifier: nil,
            shouldSeedAfterDownload: true
        )
        center.downloads = [item]

        XCTAssertTrue(item.isPausedSeeder)
        XCTAssertFalse(center.canCancelDownloads(ids: [item.id]))

        center.cancelDownload(id: item.id)

        XCTAssertEqual(item.status, .completed)
        XCTAssertFalse(item.shouldSeedAfterDownload)
        await center.shutdownForTermination()
    }

    func testRemovingTorrentFromListTrashesSourceButKeepsPayload() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborWatchedCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let watchDirectoryURL = rootURL.appendingPathComponent("Watch", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        let applicationSupportURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try fileManager.createDirectory(at: watchDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let key = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }
        setenv(key, applicationSupportURL.path, 1)

        let suiteName = "HarborTests.WatchedCleanup.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        settings.torrentDestinationPath = rootURL.appendingPathComponent("Downloads", isDirectory: true).path

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(directoryURL: applicationSupportURL),
            managedTorrentSourceStore: store
        )
        let torrentURL = watchDirectoryURL.appendingPathComponent("watched.torrent")
        try Data("paused watched torrent".utf8).write(to: torrentURL)

        await center.initializeIfNeeded()
        center.receiveWatchedTorrent(torrentURL)

        for _ in 0 ..< 40 {
            if center.downloads.count == 1 {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(center.downloads.count, 1)
        let item = try XCTUnwrap(center.downloads.first)
        let payloadURL = rootURL.appendingPathComponent("Downloads/payload.bin")
        try fileManager.createDirectory(
            at: payloadURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("downloaded payload".utf8).write(to: payloadURL)
        let controlURL = URL(fileURLWithPath: payloadURL.path + ".aria2")
        try Data("aria2 control data".utf8).write(to: controlURL)
        item.torrentPayloadPaths = [payloadURL.path]

        XCTAssertTrue(fileManager.fileExists(atPath: torrentURL.path))

        center.removeDownload(id: item.id)

        for _ in 0 ..< 100 {
            if center.downloads.isEmpty {
                break
            }
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertTrue(center.downloads.isEmpty)
        XCTAssertFalse(fileManager.fileExists(atPath: torrentURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: controlURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: payloadURL.path))
    }

    func testMagnetSidecarsAreHiddenAndRemovedWithoutDeletingPayload() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentSidecarTests-\(UUID().uuidString)", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Application Support", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let metainfo = makeTorrentMetainfo(announceURL: "https://tracker.example/announce")
        let infoHash = Insecure.SHA1.hash(data: metainfo.infoDictionary)
            .map { String(format: "%02x", $0) }
            .joined()
        let metadataURL = rootURL.appendingPathComponent("\(infoHash).torrent")
        try metainfo.data.write(to: metadataURL)

        let payloadURL = rootURL.appendingPathComponent("payload.bin")
        try Data("downloaded payload".utf8).write(to: payloadURL)
        let controlURL = URL(fileURLWithPath: payloadURL.path + ".aria2")
        try Data("aria2 control data".utf8).write(to: controlURL)
        let multiFileRootURL = rootURL.appendingPathComponent("Movie Folder", isDirectory: true)
        try fileManager.createDirectory(at: multiFileRootURL, withIntermediateDirectories: true)
        let firstMoviePartURL = multiFileRootURL.appendingPathComponent("movie.mkv")
        let subtitleURL = multiFileRootURL.appendingPathComponent("movie.srt")
        try Data("movie data".utf8).write(to: firstMoviePartURL)
        try Data("subtitle data".utf8).write(to: subtitleURL)
        let multiFileControlURL = URL(fileURLWithPath: multiFileRootURL.path + ".aria2")
        try Data("multi-file aria2 control data".utf8).write(to: multiFileControlURL)
        let unrelatedURL = rootURL.appendingPathComponent("unrelated.aria2")
        try Data("keep this file".utf8).write(to: unrelatedURL)

        let service = TorrentSidecarFileService(fileManager: fileManager)
        let context = TorrentSidecarContext(
            destinationFolderURL: rootURL,
            sourceKind: .magnetLink,
            torrentFingerprint: infoHash,
            fileLocationURL: multiFileRootURL,
            payloadURLs: [payloadURL, firstMoviePartURL, subtitleURL]
        )

        service.hideExistingSidecars(for: context)

        XCTAssertTrue(fileManager.fileExists(atPath: metadataURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: controlURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: multiFileControlURL.path))
        XCTAssertEqual(
            try metadataURL.resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )
        XCTAssertEqual(
            try controlURL.resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )
        XCTAssertEqual(
            try multiFileControlURL.resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )
        XCTAssertNotEqual(
            try unrelatedURL.resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let managedSource = try await store.prepareLocalTorrent(
            at: metadataURL,
            originalURL: URL(string: "magnet:?xt=urn:btih:\(infoHash)")!
        )

        try service.removeExistingSidecars(for: context)

        XCTAssertFalse(fileManager.fileExists(atPath: metadataURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: controlURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: multiFileControlURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: managedSource.managedURL.path))
        XCTAssertTrue(managedSource.managedURL.path.hasPrefix(managedDirectoryURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: payloadURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: firstMoviePartURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: subtitleURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedURL.path))
    }

    func testSidecarCleanupRejectsUnrelatedHashNamedTorrent() throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnrelatedTorrentTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let unrelatedFingerprint = String(repeating: "a", count: 40)
        let unrelatedTorrentURL = rootURL.appendingPathComponent("\(unrelatedFingerprint).torrent")
        let unrelatedMetainfo = makeTorrentMetainfo(announceURL: "https://unrelated.example/announce")
        try unrelatedMetainfo.data.write(to: unrelatedTorrentURL)

        let service = TorrentSidecarFileService(fileManager: fileManager)
        let context = TorrentSidecarContext(
            destinationFolderURL: rootURL,
            sourceKind: .magnetLink,
            torrentFingerprint: unrelatedFingerprint,
            fileLocationURL: nil,
            payloadURLs: []
        )

        service.hideExistingSidecars(for: context)
        try service.removeExistingSidecars(for: context)

        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedTorrentURL.path))
        XCTAssertNotEqual(
            try unrelatedTorrentURL.resourceValues(forKeys: [.isHiddenKey]).isHidden,
            true
        )
    }

    func testTorrentFileImportCleansVerifiedMetadataWithDifferentHashName() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let metainfo = makeTorrentMetainfo(announceURL: "https://tracker.example/announce")
        let generated = root.appendingPathComponent(String(repeating: "b", count: 40) + ".torrent")
        let named = root.appendingPathComponent("My Torrent.torrent")
        try metainfo.data.write(to: generated)
        try metainfo.data.write(to: named)
        let link = root.appendingPathComponent(String(repeating: "c", count: 40) + ".torrent")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: named)
        let context = TorrentSidecarContext(
            destinationFolderURL: root, sourceKind: .torrentFile,
            torrentFingerprint: ManagedTorrentSourceStore.fingerprint(for: metainfo.data),
            fileLocationURL: nil, payloadURLs: []
        )
        let service = TorrentSidecarFileService()
        service.hideExistingSidecars(for: context)
        XCTAssertEqual(try generated.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        XCTAssertNotEqual(try named.resourceValues(forKeys: [.isHiddenKey]).isHidden, true)
        try service.removeExistingSidecars(for: context)
        XCTAssertFalse(FileManager.default.fileExists(atPath: generated.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: named.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.path))
    }

    func testEmptyTorrentParentsAreRemovedButUnselectedFilesAndDestinationRemain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let empty = root.appendingPathComponent("Movie/Subtitles")
        let partial = root.appendingPathComponent("Partial")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kept = partial.appendingPathComponent("unselected.mkv")
        try Data("keep".utf8).write(to: kept)
        let result = DownloadDataRemovalService().movePayloadDataToTrash(
            destinationFolderPath: root.path,
            payloadPaths: [empty.appendingPathComponent("removed.srt").path,
                           partial.appendingPathComponent("removed.mkv").path],
            removeEmptyParents: true
        )
        XCTAssertTrue(result.failures.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Movie").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testExistingDataRecoveryDisablesAutomaticRenaming() {
        let options = Aria2TorrentService.downloadOptions(
            destinationFolderPath: "/tmp/HarborExistingDataTest",
            transferSettings: .default,
            transferOptions: TorrentTransferOptions(
                downloadLimitBytesPerSecond: nil,
                uploadLimitBytesPerSecond: nil,
                shouldSeed: true,
                verifyExistingData: true
            )
        )

        XCTAssertEqual(options["check-integrity"], "true")
        XCTAssertNil(options["bt-hash-check-seed"])
        XCTAssertEqual(options["allow-overwrite"], "false")
        XCTAssertEqual(options["auto-file-renaming"], "false")
    }

    func testPrepareLocalTorrentCreatesStableDeduplicatedManagedCopy() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborManagedTorrentTests-\(UUID().uuidString)", isDirectory: true)
        let sourceDirectoryURL = rootURL.appendingPathComponent("Sources", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: sourceDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let data = Data("abc".utf8)
        let firstSourceURL = sourceDirectoryURL.appendingPathComponent("first.torrent")
        let secondSourceURL = sourceDirectoryURL.appendingPathComponent("second.torrent")
        try data.write(to: firstSourceURL)
        try data.write(to: secondSourceURL)

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let first = try await store.prepareLocalTorrent(at: firstSourceURL)
        let second = try await store.prepareLocalTorrent(at: secondSourceURL)
        let expectedFingerprint = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

        XCTAssertEqual(first.fingerprint, expectedFingerprint)
        XCTAssertEqual(second.fingerprint, expectedFingerprint)
        XCTAssertEqual(first.originalURL, firstSourceURL)
        XCTAssertEqual(second.originalURL, secondSourceURL)
        XCTAssertEqual(first.managedURL, second.managedURL)
        XCTAssertEqual(
            first.managedURL,
            managedDirectoryURL.appendingPathComponent("\(expectedFingerprint).torrent")
        )
        XCTAssertEqual(try Data(contentsOf: first.managedURL), data)
        XCTAssertEqual(
            try fileManager.contentsOfDirectory(
                at: managedDirectoryURL,
                includingPropertiesForKeys: nil
            ).count,
            1
        )
    }

    func testTorrentFingerprintUsesInfoHashAcrossTrackerChanges() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInfoHashTests-\(UUID().uuidString)", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let firstMetainfo = makeTorrentMetainfo(announceURL: "https://tracker-one.example/announce")
        let secondMetainfo = makeTorrentMetainfo(announceURL: "https://tracker-two.example/announce")
        let firstURL = rootURL.appendingPathComponent("first.torrent")
        let secondURL = rootURL.appendingPathComponent("second.torrent")
        try firstMetainfo.data.write(to: firstURL)
        try secondMetainfo.data.write(to: secondURL)

        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let first = try await store.prepareLocalTorrent(at: firstURL)
        let second = try await store.prepareLocalTorrent(at: secondURL)
        let expectedInfoHash = Insecure.SHA1.hash(data: firstMetainfo.infoDictionary)
            .map { String(format: "%02x", $0) }
            .joined()

        XCTAssertNotEqual(firstMetainfo.data, secondMetainfo.data)
        XCTAssertEqual(first.fingerprint, expectedInfoHash)
        XCTAssertEqual(second.fingerprint, expectedInfoHash)
        XCTAssertNotEqual(first.sourceFingerprint, second.sourceFingerprint)
        XCTAssertEqual(first.managedURL, second.managedURL)
        XCTAssertEqual(first.fingerprint.count, 40)
        XCTAssertEqual(
            ManagedTorrentSourceStore.normalizedInfoHash(String(repeating: "a", count: 32)),
            String(repeating: "0", count: 40)
        )
    }

    func testWatchedReimportAfterRelaunchPreservesCompletedTorrentRecordAndPayload() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentReimportTests-\(UUID().uuidString)", isDirectory: true)
        let watchDirectoryURL = rootURL.appendingPathComponent("Watch", isDirectory: true)
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        let downloadDirectoryURL = rootURL.appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: watchDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: managedDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: downloadDirectoryURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        let originalMetainfo = makeTorrentMetainfo(announceURL: "https://tracker-one.example/announce")
        let reimportedMetainfo = makeTorrentMetainfo(announceURL: "https://tracker-two.example/announce")
        let originalSourceURL = watchDirectoryURL.appendingPathComponent("original.torrent")
        try originalMetainfo.data.write(to: originalSourceURL)

        let legacyFingerprint = String(repeating: "f", count: 64)
        let legacyManagedURL = managedDirectoryURL.appendingPathComponent("\(legacyFingerprint).torrent")
        try originalMetainfo.data.write(to: legacyManagedURL)

        let payloadURL = downloadDirectoryURL.appendingPathComponent("payload.bin")
        let originalPayload = Data("completed payload must remain unchanged".utf8)
        try originalPayload.write(to: payloadURL)

        let originalID = UUID()
        let finishedAt = Date.now.addingTimeInterval(-60)
        let originalItem = DownloadItem(
            id: originalID,
            sourceURL: originalSourceURL,
            sourceKind: .torrentFile,
            backend: .aria2,
            preferredFilename: nil,
            destinationFolderPath: downloadDirectoryURL.path,
            fileLocationPath: payloadURL.path,
            status: .seeding,
            progress: 1,
            bytesWritten: Int64(originalPayload.count),
            expectedBytes: Int64(originalPayload.count),
            finishedAt: finishedAt,
            metadataName: "Payload",
            torrentFingerprint: legacyFingerprint,
            managedTorrentSourcePath: legacyManagedURL.path,
            torrentPayloadPaths: [payloadURL.path],
            shouldSeedAfterDownload: true,
            activityEvents: [
                DownloadActivityEvent(kind: .added, timestamp: finishedAt.addingTimeInterval(-120)),
                DownloadActivityEvent(kind: .completed, timestamp: finishedAt),
                DownloadActivityEvent(kind: .seedingStarted, timestamp: finishedAt)
            ]
        )
        let restoredItem = DownloadItem(record: originalItem.makeRecord())
        let originalActivity = restoredItem.activityEvents

        try fileManager.removeItem(at: originalSourceURL)
        let reimportedSourceURL = watchDirectoryURL.appendingPathComponent("reimported.torrent")
        try reimportedMetainfo.data.write(to: reimportedSourceURL)

        let suiteName = "HarborTests.TorrentReimport.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        settings.torrentDestinationPath = downloadDirectoryURL.path
        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let center = DownloadCenter(
            settings: settings,
            persistence: DownloadPersistence(
                directoryURL: rootURL.appendingPathComponent("Persistence", isDirectory: true)
            ),
            directRecoveryDirectoryURL: rootURL.appendingPathComponent("DirectRecovery", isDirectory: true),
            completedHandoffDirectoryURL: rootURL.appendingPathComponent("Handoffs", isDirectory: true),
            browserRecoveryDirectoryURL: rootURL.appendingPathComponent("BrowserRecovery", isDirectory: true),
            managedTorrentSourceStore: store
        )
        await center.initializeIfNeeded()
        center.downloads = [restoredItem]

        center.receiveWatchedTorrent(reimportedSourceURL)

        for _ in 0 ..< 80 where restoredItem.torrentFingerprint == legacyFingerprint {
            try await Task.sleep(for: .milliseconds(25))
        }

        let expectedInfoHash = Insecure.SHA1.hash(data: originalMetainfo.infoDictionary)
            .map { String(format: "%02x", $0) }
            .joined()
        XCTAssertEqual(center.downloads.count, 1)
        XCTAssertEqual(center.downloads.first?.id, originalID)
        XCTAssertEqual(restoredItem.torrentFingerprint, expectedInfoHash)
        XCTAssertEqual(
            restoredItem.torrentSourceFingerprint,
            ManagedTorrentSourceStore.sourceFingerprint(for: originalMetainfo.data)
        )
        XCTAssertEqual(restoredItem.status, .seeding)
        XCTAssertEqual(restoredItem.finishedAt, finishedAt)
        XCTAssertEqual(restoredItem.activityEvents, originalActivity)
        XCTAssertEqual(restoredItem.torrentPayloadPaths, [payloadURL.path])
        XCTAssertNil(restoredItem.backendIdentifier)
        XCTAssertNil(center.activeAlert)
        XCTAssertEqual(try Data(contentsOf: payloadURL), originalPayload)
        XCTAssertTrue(DownloadCenter.hasExistingTorrentPayload(restoredItem))

        try fileManager.removeItem(at: payloadURL)
        center.receiveWatchedTorrent(reimportedSourceURL)
        for _ in 0 ..< 80 where center.activeAlert == nil {
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertEqual(center.downloads.count, 1)
        XCTAssertEqual(center.downloads.first?.id, originalID)
        XCTAssertEqual(center.activeAlert?.title, "Torrent Already Added")
        XCTAssertTrue(center.activeAlert?.message.contains("No duplicate download was started") == true)
        XCTAssertNil(restoredItem.backendIdentifier)
        XCTAssertFalse(DownloadCenter.hasExistingTorrentPayload(restoredItem))

        await center.shutdownForTermination()
    }

    func testCleanupFingerprintRejectsReplacementAtSamePath() async throws {
        let fileManager = FileManager.default
        let rootURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborTorrentCleanupTests-\(UUID().uuidString)", isDirectory: true)
        let sourceURL = rootURL.appendingPathComponent("watched.torrent")
        let managedDirectoryURL = rootURL.appendingPathComponent("Managed", isDirectory: true)
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: rootURL) }

        try Data("original torrent".utf8).write(to: sourceURL)
        let store = ManagedTorrentSourceStore(
            fileManager: fileManager,
            directoryURL: managedDirectoryURL
        )
        let managedSource = try await store.prepareLocalTorrent(at: sourceURL)

        let originalMatches = await store.torrent(
            at: sourceURL,
            matches: managedSource.fingerprint
        )
        XCTAssertTrue(originalMatches)

        try Data("replacement torrent".utf8).write(to: sourceURL, options: .atomic)

        let replacementMatches = await store.torrent(
            at: sourceURL,
            matches: managedSource.fingerprint
        )
        XCTAssertFalse(replacementMatches)
        XCTAssertEqual(try Data(contentsOf: sourceURL), Data("replacement torrent".utf8))
    }

    func testApplicationSupportDirectoryHonorsEnvironmentOverride() {
        let key = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(key).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(key, previousValue, 1)
            } else {
                unsetenv(key)
            }
        }

        let overrideURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborApplicationSupportTests-\(UUID().uuidString)", isDirectory: true)
        setenv(key, overrideURL.path, 1)

        XCTAssertEqual(
            HarborApplicationSupport.directoryURL().standardizedFileURL,
            overrideURL.appendingPathComponent("Harbor", isDirectory: true).standardizedFileURL
        )
    }

    func testSessionRecoveryRequiresCorruptionSignal() {
        XCTAssertTrue(
            Aria2TorrentService.shouldRecoverSession(
                from: "ERROR Unrecognized URI or unsupported protocol: broken session row"
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.shouldRecoverSession(
                from: "Failed to parse aria2 session"
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.shouldRecoverSession(
                from: "Address already in use while opening RPC port"
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.shouldRecoverSession(
                from: "Timed out waiting for network connectivity"
            )
        )
    }

    func testRestorePolicyPreservesPausedIntentAndOnlyRestartsActiveSeeder() {
        XCTAssertTrue(
            DownloadCenter.shouldPauseRestoredTorrent(
                persistedStatus: .paused,
                engineStatus: "active"
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldPauseRestoredTorrent(
                persistedStatus: .seeding,
                engineStatus: "active"
            )
        )
        XCTAssertTrue(
            DownloadCenter.shouldRestartStaleSeeder(
                persistedStatus: .seeding,
                hasFinishedData: true,
                shouldSeed: true
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRestartStaleSeeder(
                persistedStatus: .paused,
                hasFinishedData: true,
                shouldSeed: true
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRestartStaleSeeder(
                persistedStatus: .completed,
                hasFinishedData: true,
                shouldSeed: false
            )
        )

        XCTAssertTrue(
            DownloadCenter.shouldHideRestoredTorrentSidecars(
                backend: .aria2,
                status: .paused
            )
        )
        XCTAssertTrue(
            DownloadCenter.shouldHideRestoredTorrentSidecars(
                backend: .aria2,
                status: .seeding
            )
        )
        XCTAssertTrue(
            DownloadCenter.shouldHideRestoredTorrentSidecars(
                backend: .aria2,
                status: .completed
            )
        )
    }

    func testMagnetMetadataCompletionWaitsForAria2FollowedPayload() {
        let metadataSnapshot = TorrentStatusSnapshot(
            gid: "metadata-gid",
            status: "complete",
            totalLength: 21_167,
            completedLength: 21_167,
            uploadLength: 0,
            downloadSpeed: 0,
            uploadSpeed: 0,
            isSeeder: false,
            infoHash: "c8b32b9552e94fba03b8b2a8041e0593649fb4a1",
            errorMessage: nil,
            metadataName: "Example Torrent",
            filePaths: ["[METADATA]Example Torrent"],
            primaryPath: "[METADATA]Example Torrent",
            followedBy: ["payload-gid"],
            following: nil
        )
        let metadataLineage = TorrentStatusLineage(
            rootGID: "metadata-gid",
            gids: ["metadata-gid"],
            currentSnapshot: metadataSnapshot
        )

        XCTAssertTrue(metadataSnapshot.isMetadataDownload)
        XCTAssertTrue(
            DownloadCenter.shouldAwaitMagnetPayload(
                sourceKind: .magnetLink,
                lineage: metadataLineage
            )
        )

        let payloadSnapshot = TorrentStatusSnapshot(
            gid: "payload-gid",
            status: "active",
            totalLength: 4_199_224_677,
            completedLength: 1_048_576,
            uploadLength: 0,
            downloadSpeed: 512_000,
            uploadSpeed: 0,
            isSeeder: false,
            infoHash: "c8b32b9552e94fba03b8b2a8041e0593649fb4a1",
            errorMessage: nil,
            metadataName: "Example Torrent",
            filePaths: ["/Downloads/example.mkv"],
            primaryPath: "/Downloads/example.mkv",
            followedBy: [],
            following: "metadata-gid"
        )
        let payloadLineage = TorrentStatusLineage(
            rootGID: "metadata-gid",
            gids: ["metadata-gid", "payload-gid"],
            currentSnapshot: payloadSnapshot
        )

        XCTAssertFalse(payloadSnapshot.isMetadataDownload)
        XCTAssertFalse(
            DownloadCenter.shouldAwaitMagnetPayload(
                sourceKind: .magnetLink,
                lineage: payloadLineage
            )
        )
        XCTAssertEqual(payloadLineage.currentSnapshot.gid, "payload-gid")
        XCTAssertEqual(payloadLineage.currentSnapshot.following, "metadata-gid")
    }

    func testRestoredMagnetLineageDoesNotTreatPayloadChildAsOrphan() {
        let orphans = DownloadCenter.orphanedTorrentGIDs(
            engineGIDs: ["metadata-gid", "payload-gid", "untracked-gid"],
            retainedGIDs: ["metadata-gid", "payload-gid"]
        )

        XCTAssertEqual(orphans, ["untracked-gid"])
    }

    func testMetadataOnlyCompletedMagnetIsEligibleForRepair() {
        XCTAssertTrue(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .magnetLink,
                status: .completed,
                fileLocationPath: "[METADATA]Example Torrent",
                payloadPaths: []
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .magnetLink,
                status: .completed,
                fileLocationPath: "/Downloads/example.mkv",
                payloadPaths: []
            )
        )
        XCTAssertFalse(
            DownloadCenter.shouldRepairMetadataOnlyMagnetCompletion(
                sourceKind: .torrentFile,
                status: .completed,
                fileLocationPath: "[METADATA]Example Torrent",
                payloadPaths: []
            )
        )
    }

    private func makeTorrentMetainfo(announceURL: String) -> (data: Data, infoDictionary: Data) {
        var infoDictionary = Data([UInt8(ascii: "d")])
        appendBencodedString("length", to: &infoDictionary)
        infoDictionary.append(Data("i7e".utf8))
        appendBencodedString("name", to: &infoDictionary)
        appendBencodedString("payload.bin", to: &infoDictionary)
        appendBencodedString("piece length", to: &infoDictionary)
        infoDictionary.append(Data("i16384e".utf8))
        appendBencodedString("pieces", to: &infoDictionary)
        appendBencodedBytes(Data(repeating: 0x11, count: 20), to: &infoDictionary)
        infoDictionary.append(UInt8(ascii: "e"))

        var metainfo = Data([UInt8(ascii: "d")])
        appendBencodedString("announce", to: &metainfo)
        appendBencodedString(announceURL, to: &metainfo)
        appendBencodedString("info", to: &metainfo)
        metainfo.append(infoDictionary)
        metainfo.append(UInt8(ascii: "e"))
        return (metainfo, infoDictionary)
    }

    private func appendBencodedString(_ value: String, to data: inout Data) {
        appendBencodedBytes(Data(value.utf8), to: &data)
    }

    private func appendBencodedBytes(_ value: Data, to data: inout Data) {
        data.append(Data("\(value.count):".utf8))
        data.append(value)
    }
}
