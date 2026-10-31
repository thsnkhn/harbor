import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testChildOwnedMediaReceiptRestoresCollectionThroughDownloadCenter() async throws {
        let suiteName = "HarborTests.MediaCompletionReplay.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionReplayTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let temporaryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let firstURL = destinationRoot.appendingPathComponent("episode-1.mp4")
        let secondURL = destinationRoot.appendingPathComponent("episode-2.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let firstPayload = Data("first-episode".utf8)
        let secondPayload = Data("second-episode".utf8)
        try firstPayload.write(to: firstURL)
        try secondPayload.write(to: secondURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/playlist")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .downloading,
            progress: 0.8,
            bytesWritten: 80,
            expectedBytes: 100
        )
        let attemptIdentifier = UUID()
        let actualBytes = Int64(firstPayload.count + secondPayload.count)
        let storage = DownloadStorageLocations(directoryURL: persistenceRoot)
        try storage.preserveLegacyLocations(for: [])
        try storage.prepare(id: item.id, destination: destinationRoot)
        let recoveryFolder = storage.directory(for: item.id, name: "MediaDownloads", legacy: temporaryRoot)
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try writeChildOwnedMediaCompletionEvidence(
            recoveryFolder: recoveryFolder,
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolder: destinationRoot,
            completedURLs: [firstURL, secondURL],
            isCollection: true
        )

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let mediaService = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: temporaryRoot,
            storageLocations: storage
        )
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            storageLocations: storage,
            mediaService: mediaService
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first { $0.id == item.id })
        XCTAssertEqual(restored.status, .completed)
        XCTAssertEqual(restored.fileLocationPath, destinationRoot.path)
        XCTAssertEqual(restored.torrentPayloadPaths, [firstURL.path, secondURL.path])
        XCTAssertEqual(restored.bytesWritten, actualBytes)
        XCTAssertEqual(restored.expectedBytes, actualBytes)
        XCTAssertEqual(restored.progress, 1)
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: firstURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: secondURL.path))
        let persistedRecords = try await persistence.load()
        let persisted = try XCTUnwrap(persistedRecords.first)
        XCTAssertEqual(persisted.status, .completed)
        XCTAssertEqual(persisted.torrentPayloadPaths, [firstURL.path, secondURL.path])
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testMediaCompletionJournalSurvivesRecordSaveFailure() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected media completion save failure" }
        }

        let suiteName = "HarborTests.MediaCompletionSaveFailure.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionSaveFailure-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let payload = Data("durable-media".utf8)
        try payload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .paused
        )
        let attemptIdentifier = UUID()
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(payload.count),
                    sha256: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(payload.count)
        )
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(
            to: recoveryFolder.appendingPathComponent(".harbor-completion.json")
        )
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])

        var failedCenter: DownloadCenter? = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            ),
            recordSaveOperation: { _, _, _ in
                throw ExpectedSaveFailure()
            }
        )
        await failedCenter?.initializeIfNeeded()

        XCTAssertEqual(failedCenter?.downloads.first?.status, .failed)
        XCTAssertTrue(fileManager.fileExists(atPath: recoveryFolder.path))
        let recordsAfterFailedSave = try await persistence.load()
        XCTAssertEqual(recordsAfterFailedSave.first?.status, .paused)
        failedCenter = nil

        let restoredCenter = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            )
        )
        await restoredCenter.initializeIfNeeded()

        XCTAssertEqual(restoredCenter.downloads.first?.status, .completed)
        XCTAssertEqual(restoredCenter.downloads.first?.bytesWritten, Int64(payload.count))
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        let recordsAfterRecovery = try await persistence.load()
        XCTAssertEqual(recordsAfterRecovery.first?.status, .completed)
        let shutdownSucceeded = await restoredCenter.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testInvalidMediaCompletionRotatesOutputPathBeforeDiscardingJournal() async throws {
        let suiteName = "HarborTests.InvalidMediaCompletionOutput.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborInvalidMediaCompletion-\(UUID().uuidString)")
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let originalPayload = Data("original-completed-media".utf8)
        try originalPayload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .downloading
        )
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: UUID(),
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(originalPayload.count),
                    sha256: SHA256.hash(data: originalPayload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(originalPayload.count)
        )
        let recoveryFolder = recoveryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        let markerURL = recoveryFolder.appendingPathComponent(".harbor-completion.json")
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(to: markerURL)
        let replacementPayload = Data("replacement-owned-by-another-writer".utf8)
        try replacementPayload.write(to: payloadURL)

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: testRoot.appendingPathComponent("DirectRecovery"),
            completedHandoffDirectoryURL: testRoot.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: testRoot.appendingPathComponent("BrowserRecovery"),
            mediaService: MediaDownloadService(
                eventHandler: { _, _ in },
                fileManager: fileManager,
                temporaryRoot: recoveryRoot
            )
        )
        await center.initializeIfNeeded()

        let restored = try XCTUnwrap(center.downloads.first)
        let conflictIdentifier = try XCTUnwrap(
            restored.mediaOutputConflictIdentifier
        )
        XCTAssertEqual(restored.status, .failed)
        XCTAssertFalse(fileManager.fileExists(atPath: markerURL.path))
        XCTAssertEqual(try Data(contentsOf: payloadURL), replacementPayload)
        let storedRecords = try await persistence.load()
        XCTAssertEqual(
            storedRecords.first?.mediaOutputConflictIdentifier,
            conflictIdentifier
        )
        let shutdownSucceeded = await center.shutdownForTermination()
        XCTAssertTrue(shutdownSucceeded)
    }

    func testMediaRetryReconcilesDurableCompletionInsteadOfStartingAnotherProcess() async throws {
        let suiteName = "HarborTests.MediaCompletionRetry.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaCompletionRetry-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let temporaryRoot = testRoot.appendingPathComponent("MediaRecovery", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let payloadURL = destinationRoot.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)
        let payload = Data("already-finished-media".utf8)
        try payload.write(to: payloadURL)

        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/video")),
            sourceKind: .mediaURL,
            backend: .ytDlp,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .failed
        )
        item.lastError = "The completion journal could not be published."
        let attemptIdentifier = UUID()
        let manifest = MediaCompletionManifest(
            downloadID: item.id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: item.sourceURL,
            destinationFolderPath: destinationRoot.path,
            fileLocationPath: payloadURL.path,
            payloads: [
                MediaCompletedFileManifest(
                    path: payloadURL.path,
                    byteCount: Int64(payload.count),
                    sha256: SHA256.hash(data: payload)
                        .map { String(format: "%02x", $0) }
                        .joined()
                )
            ],
            actualBytes: Int64(payload.count)
        )
        let recoveryFolder = temporaryRoot
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: recoveryFolder, withIntermediateDirectories: true)
        try JSONEncoder().encode(manifest).write(
            to: recoveryFolder.appendingPathComponent(".harbor-completion.json")
        )

        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        try await persistence.save([item.makeRecord()])
        let mediaService = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: temporaryRoot
        )
        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: persistence,
            mediaService: mediaService
        )
        center.downloads = [item]

        center.retryDownload(id: item.id)
        for _ in 0 ..< 200 where item.status != .completed {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(item.status, .completed)
        XCTAssertEqual(item.fileLocationPath, payloadURL.path)
        XCTAssertEqual(item.bytesWritten, Int64(payload.count))
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))
        let storedRecords = try await persistence.load()
        let stored = try XCTUnwrap(storedRecords.first)
        XCTAssertEqual(stored.status, .completed)
        XCTAssertEqual(stored.fileLocationPath, payloadURL.path)
        let didShutDown = await center.shutdownForTermination()
        XCTAssertTrue(didShutDown)
    }

    func testPlacementReconciliationHashDoesNotBlockUnrelatedClaim() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent(
                "HarborConcurrentPlacementReconciliation-\(UUID().uuidString)",
                isDirectory: true
            )
        let destinationRoot = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: destinationRoot, withIntermediateDirectories: true)

        let firstID = UUID()
        let firstAttempt = UUID()
        let secondID = UUID()
        let secondAttempt = UUID()
        let shouldBlockHash = LockedTestFlag()
        let hashEntered = LockedTestFlag()
        let releaseHash = DispatchSemaphore(value: 0)
        defer { releaseHash.signal() }
        let secondClaimFinished = LockedTestFlag()
        let store = CompletedDownloadHandoffStore(
            directoryURL: root.appendingPathComponent("Handoffs", isDirectory: true),
            payloadHashOperation: { url in
                if shouldBlockHash.value,
                   url.path.contains(firstAttempt.uuidString),
                   hashEntered.value == false {
                    hashEntered.set()
                    releaseHash.wait()
                }
                return SHA256.hash(data: try Data(contentsOf: url))
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/archive.bin"))
        let firstPayloadURL = root.appendingPathComponent("first.bin")
        let secondPayloadURL = root.appendingPathComponent("second.bin")
        try Data(repeating: 0x41, count: 1_024).write(to: firstPayloadURL)
        try Data(repeating: 0x42, count: 128).write(to: secondPayloadURL)

        let firstClaim = try store.claim(
            payloadAt: firstPayloadURL,
            manifest: CompletedDownloadHandoffManifest(
                downloadID: firstID,
                attemptIdentifier: firstAttempt,
                owner: .direct,
                sourceURL: sourceURL,
                statusCode: 200,
                mimeType: "application/octet-stream",
                suggestedFilename: "first.bin",
                actualBytes: 1_024,
                expectedBytes: 1_024
            )
        )
        let firstHandoff = try store.finalize(firstClaim)
        _ = try store.recordDestination(
            destinationRoot.appendingPathComponent("first.bin"),
            for: firstHandoff
        )

        shouldBlockHash.set()
        let reconciliationTask = Task.detached {
            try store.entries()
        }
        for _ in 0 ..< 200 where hashEntered.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(hashEntered.value)

        let secondClaimTask = Task.detached {
            defer { secondClaimFinished.set() }
            return try store.claim(
                payloadAt: secondPayloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: secondID,
                    attemptIdentifier: secondAttempt,
                    owner: .direct,
                    sourceURL: sourceURL,
                    statusCode: 200,
                    mimeType: "application/octet-stream",
                    suggestedFilename: "second.bin",
                    actualBytes: 128,
                    expectedBytes: 128
                )
            )
        }
        for _ in 0 ..< 100 where secondClaimFinished.value == false {
            try await Task.sleep(for: .milliseconds(10))
        }
        let secondClaimCompletedBeforeRelease = secondClaimFinished.value
        releaseHash.signal()

        XCTAssertTrue(secondClaimCompletedBeforeRelease)
        _ = try await reconciliationTask.value
        let secondClaim = try await secondClaimTask.value
        _ = try store.finalize(secondClaim)
        XCTAssertEqual(try store.entries().count, 2)
    }
}
