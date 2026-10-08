import CryptoKit
import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testAutomaticCleanupRemovesPublishedDownloadOnlyWhenEnabled() async throws {
        for enabled in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborAutoCompletion-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let suite = "HarborTests.AutoCompletion.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = AppSettingsStore(userDefaults: defaults)
            settings.removeCompletedDownloadsAutomatically = enabled
            let persistence = DownloadPersistence(directoryURL: root.appendingPathComponent("records"))
            let handoffs = root.appendingPathComponent("handoffs")
            let destination = root.appendingPathComponent("downloads")
            let incoming = root.appendingPathComponent("incoming.download")
            let payload = Data("Verified completed payload".utf8)
            try payload.write(to: incoming)
            let item = DownloadItem(
                sourceURL: URL(string: "https://example.test/cleanup.bin")!, sourceKind: .directURL,
                backend: .urlSession, preferredFilename: nil, destinationFolderPath: destination.path,
                status: .paused
            )
            try await persistence.save([item.makeRecord()])
            _ = try makeCompletedHandoff(
                payloadURL: incoming, handoffDirectoryURL: handoffs, downloadID: item.id,
                attemptIdentifier: UUID(), sourceURL: item.sourceURL, suggestedFilename: "cleanup.bin"
            )
            let center = DownloadCenter(settings: settings, persistence: persistence, completedHandoffDirectoryURL: handoffs)
            await center.initializeIfNeeded()
            if enabled {
                for _ in 0..<200 where !center.downloads.isEmpty {
                    try await Task.sleep(for: .milliseconds(10))
                }
            }
            XCTAssertEqual(center.downloads.isEmpty, enabled)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("cleanup.bin")), payload)
            let records = try await persistence.load()
            XCTAssertEqual(records.isEmpty, enabled)
            XCTAssertTrue(try CompletedDownloadHandoffStore(directoryURL: handoffs).entries().isEmpty)
            await center.shutdownForTermination()
        }
    }

    func testUnclaimableCompletionEventsDiscardTemporaryFiles() async throws {
        let suiteName = "HarborTests.UnclaimableCompletion.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnclaimableCompletionTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let directTemporaryURL = testRoot.appendingPathComponent("direct.download")
        let browserTemporaryURL = testRoot.appendingPathComponent("browser.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("direct".utf8).write(to: directTemporaryURL)
        try Data("browser".utf8).write(to: browserTemporaryURL)

        let center = DownloadCenter(
            settings: AppSettingsStore(userDefaults: userDefaults),
            persistence: DownloadPersistence(directoryURL: persistenceRoot),
            completedHandoffDirectoryURL: handoffRoot
        )
        let cancelledItem = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/cancelled.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: testRoot.path,
            status: .cancelled
        )
        center.downloads = [cancelledItem]
        let directAttemptIdentifier = UUID()
        let directHandoff = try makeCompletedHandoff(
            payloadURL: directTemporaryURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: cancelledItem.id,
            attemptIdentifier: directAttemptIdentifier,
            sourceURL: cancelledItem.sourceURL,
            suggestedFilename: "cancelled.bin"
        )
        let removedID = UUID()
        let browserAttemptIdentifier = UUID()
        let browserSourceURL = try XCTUnwrap(URL(string: "https://example.test/removed.bin"))
        let browserHandoff = try makeCompletedHandoff(
            payloadURL: browserTemporaryURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: removedID,
            attemptIdentifier: browserAttemptIdentifier,
            sourceURL: browserSourceURL,
            owner: .browser,
            suggestedFilename: "removed.bin"
        )

        center.handle(
            .finished(
                id: cancelledItem.id,
                attemptIdentifier: directAttemptIdentifier,
                handoff: directHandoff
            )
        )
        center.handleBrowserDownloadEvent(
            .finished(
                id: removedID,
                attemptIdentifier: browserAttemptIdentifier,
                handoff: browserHandoff
            )
        )

        XCTAssertEqual(cancelledItem.status, .cancelled)
        XCTAssertFalse(fileManager.fileExists(atPath: directHandoff.packageURL.path))
        XCTAssertFalse(fileManager.fileExists(atPath: browserHandoff.packageURL.path))

        await center.shutdownForTermination()
    }

    func testCompletedHandoffSurvivesSaveFailureAndSupersedesCorruptSibling() async throws {
        struct ExpectedSaveFailure: LocalizedError {
            var errorDescription: String? { "Expected completion save failure" }
        }

        let suiteName = "HarborTests.CompletedHandoffRecovery.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborCompletedHandoffRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let destinationRoot = testRoot.appendingPathComponent("Destination", isDirectory: true)
        let incomingURL = testRoot.appendingPathComponent("incoming.download")
        defer { try? fileManager.removeItem(at: testRoot) }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)
        try Data("verified-payload".utf8).write(to: incomingURL)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = false
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let item = DownloadItem(
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/archive.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: destinationRoot.path,
            status: .paused
        )
        try await persistence.save([item.makeRecord()])

        let validAttempt = UUID()
        _ = try makeCompletedHandoff(
            payloadURL: incomingURL,
            handoffDirectoryURL: handoffRoot,
            downloadID: item.id,
            attemptIdentifier: validAttempt,
            sourceURL: item.sourceURL,
            suggestedFilename: "archive.bin"
        )
        let corruptPackageURL = handoffRoot
            .appendingPathComponent("\(item.id.uuidString)-\(UUID().uuidString)", isDirectory: true)
            .appendingPathExtension("handoff")
        try fileManager.createDirectory(at: corruptPackageURL, withIntermediateDirectories: true)
        try Data("not-json".utf8).write(
            to: corruptPackageURL.appendingPathComponent("manifest.json")
        )

        var failedCenter: DownloadCenter? = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot,
            recordSaveOperation: { _, _, _ in
                throw ExpectedSaveFailure()
            }
        )
        await failedCenter?.initializeIfNeeded()

        // The validated journal owns the placed payload, but completion is
        // not exposed until the corresponding record is durable.
        XCTAssertEqual(failedCenter?.downloads.first?.status, .failed)
        XCTAssertFalse(fileManager.fileExists(atPath: corruptPackageURL.path))
        let handoffStore = CompletedDownloadHandoffStore(directoryURL: handoffRoot)
        let retainedEntries = try handoffStore.entries()
        XCTAssertEqual(retainedEntries.count, 1)
        guard case let .valid(retainedHandoff) = try XCTUnwrap(retainedEntries.first) else {
            return XCTFail("Expected the completion handoff to remain valid")
        }
        XCTAssertNotNil(retainedHandoff.payloadURL)
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: destinationRoot.appendingPathComponent("archive.bin").path
            )
        )
        failedCenter = nil

        // The failed record save leaves the journal authoritative. A third
        // party can replace the visible pathname before relaunch without
        // stealing or destroying the completed payload.
        let firstDestinationURL = destinationRoot.appendingPathComponent("archive.bin")
        let replacement = Data("replacement-owned-by-another-writer".utf8)
        try replacement.write(to: firstDestinationURL)

        let restoredCenter = DownloadCenter(
            settings: settings,
            persistence: persistence,
            completedHandoffDirectoryURL: handoffRoot
        )
        await restoredCenter.initializeIfNeeded()

        let restoredItem = try XCTUnwrap(
            restoredCenter.downloads.first { $0.id == item.id }
        )
        XCTAssertEqual(restoredItem.status, .completed)
        XCTAssertEqual(restoredItem.bytesWritten, Int64("verified-payload".utf8.count))
        let recoveredDestinationURL = destinationRoot.appendingPathComponent("archive 2.bin")
        XCTAssertEqual(restoredItem.fileLocationPath, recoveredDestinationURL.path)
        XCTAssertEqual(try Data(contentsOf: firstDestinationURL), replacement)
        XCTAssertEqual(
            try Data(contentsOf: recoveredDestinationURL),
            Data("verified-payload".utf8)
        )
        XCTAssertTrue(
            try CompletedDownloadHandoffStore(directoryURL: handoffRoot).entries().isEmpty
        )
        let persistedRecords = try await persistence.load()
        XCTAssertEqual(persistedRecords.first?.status, .completed)

        await restoredCenter.shutdownForTermination()
    }

    func testClaimingHandoffSurvivesReadFailureAndFinishesRecovery() throws {
        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborClaimingHandoffTests-\(UUID().uuidString)", isDirectory: true)
        let handoffRoot = testRoot.appendingPathComponent("Handoffs", isDirectory: true)
        let downloadID = UUID()
        let attemptIdentifier = UUID()
        let packageURL = handoffRoot
            .appendingPathComponent(
                "\(downloadID.uuidString)-\(attemptIdentifier.uuidString)",
                isDirectory: true
            )
            .appendingPathExtension("staging")
        let manifestURL = packageURL.appendingPathComponent("manifest.json")
        let payloadURL = packageURL.appendingPathComponent("payload")
        var restoredPermissions = false
        defer {
            if restoredPermissions == false {
                try? fileManager.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: manifestURL.path
                )
            }
            try? fileManager.removeItem(at: testRoot)
        }

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: true)
        let payload = Data("claimed-before-hash".utf8)
        try payload.write(to: payloadURL)
        let claim = CompletedDownloadHandoffManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            owner: .direct,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/claimed.bin")),
            statusCode: 200,
            mimeType: "application/octet-stream",
            suggestedFilename: "claimed.bin",
            actualBytes: Int64(payload.count),
            expectedBytes: Int64(payload.count),
            phase: .claiming
        )
        try JSONEncoder().encode(claim).write(to: manifestURL)
        try fileManager.setAttributes(
            [.posixPermissions: 0o000],
            ofItemAtPath: manifestURL.path
        )

        let store = CompletedDownloadHandoffStore(
            fileManager: fileManager,
            directoryURL: handoffRoot
        )
        let unavailableEntries = try store.entries()
        XCTAssertEqual(unavailableEntries.count, 1)
        guard case .unavailable = try XCTUnwrap(unavailableEntries.first) else {
            return XCTFail("A transient manifest read failure must retain the claimed payload")
        }
        XCTAssertTrue(fileManager.fileExists(atPath: packageURL.path))

        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: manifestURL.path
        )
        restoredPermissions = true
        let recoveredEntries = try store.entries()
        guard case let .valid(handoff) = try XCTUnwrap(recoveredEntries.first) else {
            return XCTFail("Expected the claiming handoff to finish after access returned")
        }
        XCTAssertEqual(try Data(contentsOf: try XCTUnwrap(handoff.payloadURL)), payload)
        XCTAssertEqual(handoff.manifest.phase, .ready)
        XCTAssertEqual(handoff.manifest.payloadSHA256.count, SHA256.byteCount * 2)
        XCTAssertEqual(handoff.packageURL.pathExtension, "handoff")
        XCTAssertFalse(fileManager.fileExists(atPath: packageURL.path))
    }

    func testDanglingDestinationSymlinkCannotBeOverwritten() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDanglingDestinationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        let occupiedURL = directoryURL.appendingPathComponent("archive.bin")
        try fileManager.createSymbolicLink(
            at: occupiedURL,
            withDestinationURL: directoryURL.appendingPathComponent("missing-target.bin")
        )

        let resolved = try DownloadDestinationResolver(fileManager: fileManager)
            .uniqueDestinationURL(for: "archive.bin", in: directoryURL)
        XCTAssertEqual(resolved, directoryURL.appendingPathComponent("archive 2.bin"))
        XCTAssertNoThrow(
            try fileManager.destinationOfSymbolicLink(atPath: occupiedURL.path)
        )
    }

    func testConcurrentDestinationMovesPublishExactlyOnePayloadWithoutReplacement() throws {
        let fileManager = FileManager.default
        let directoryURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborExclusiveDestinationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: directoryURL) }
        try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let resolver = DownloadDestinationResolver(fileManager: fileManager)

        for iteration in 0 ..< 25 {
            let payloads = [
                Data("first-\(iteration)".utf8),
                Data("second-\(iteration)".utf8)
            ]
            let sourceURLs = payloads.indices.map { index in
                directoryURL.appendingPathComponent("source-\(iteration)-\(index).part")
            }
            for index in payloads.indices {
                try payloads[index].write(to: sourceURLs[index])
            }
            let destinationURL = directoryURL.appendingPathComponent("archive-\(iteration).bin")
            let results = ConcurrentMoveResults()
            let ready = DispatchSemaphore(value: 0)
            let start = DispatchSemaphore(value: 0)
            let group = DispatchGroup()

            for index in payloads.indices {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer { group.leave() }
                    ready.signal()
                    start.wait()
                    do {
                        try resolver.moveDownloadedFile(
                            from: sourceURLs[index],
                            to: destinationURL
                        )
                        results.recordSuccess(index)
                    } catch let error as CocoaError {
                        results.recordCocoaError(error.code)
                    } catch {
                        results.recordUnexpectedError(error)
                    }
                }
            }

            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(ready.wait(timeout: .now() + 2), .success)
            start.signal()
            start.signal()
            XCTAssertEqual(group.wait(timeout: .now() + 5), .success)

            let snapshot = results.snapshot
            XCTAssertEqual(snapshot.successfulIndices.count, 1)
            XCTAssertEqual(snapshot.cocoaErrorCodes, [.fileWriteFileExists])
            XCTAssertTrue(snapshot.unexpectedErrors.isEmpty)
            let winningIndex = try XCTUnwrap(snapshot.successfulIndices.first)
            let losingIndex = winningIndex == 0 ? 1 : 0
            XCTAssertEqual(try Data(contentsOf: destinationURL), payloads[winningIndex])
            XCTAssertEqual(try Data(contentsOf: sourceURLs[losingIndex]), payloads[losingIndex])
        }
    }

}
