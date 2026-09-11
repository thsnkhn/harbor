import Foundation
import WebKit
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testStaleBrowserResumeCallbackCannotAttachToReplacementSession() throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let firstID = UUID()
        let secondID = UUID()

        let firstSession = coordinator.startSession(
            downloadID: firstID,
            sourceURL: sourceURL,
            displayName: "First",
            resumeData: Data("first".utf8)
        )
        coordinator.cancelSession()
        let secondSession = coordinator.startSession(
            downloadID: secondID,
            sourceURL: sourceURL,
            displayName: "Second",
            resumeData: Data("second".utf8)
        )

        XCTAssertFalse(
            coordinator.claimPendingResume(
                downloadID: firstID,
                session: firstSession,
                webView: firstSession.webView
            )
        )
        XCTAssertTrue(
            coordinator.claimPendingResume(
                downloadID: secondID,
                session: secondSession,
                webView: secondSession.webView
            )
        )
    }

    func testPendingBrowserResumeQuiescenceReturnsOriginalBlobWhenWebKitNeverCallsBack() async throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let id = UUID()
        let attemptIdentifier = UUID()
        let resumeData = Data("opaque-webkit-resume-data".utf8)
        _ = coordinator.startSession(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: "Download",
            resumeData: resumeData
        )

        let clock = ContinuousClock()
        let startedAt = clock.now
        let result = await coordinator.quiesceDownload(id: id)
        let elapsed = startedAt.duration(to: clock.now)

        XCTAssertEqual(result?.attemptIdentifier, attemptIdentifier)
        XCTAssertEqual(result?.resumeData, resumeData)
        XCTAssertNil(result?.completionUnavailableMessage)
        XCTAssertLessThan(elapsed, .seconds(2))
        XCTAssertFalse(coordinator.hasPendingOrActiveAttempt(id: id))
    }

    func testPendingBrowserResumeCancellationDiscardsBlobAndRejectsLateClaim() async throws {
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
        let id = UUID()
        let session = coordinator.startSession(
            downloadID: id,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/download")),
            displayName: "Download",
            resumeData: Data("opaque-webkit-resume-data".utf8)
        )

        let result = await coordinator.quiesceDownload(id: id, cancelling: true)

        XCTAssertEqual(result?.attemptIdentifier, session.attemptIdentifier)
        XCTAssertNil(result?.resumeData)
        XCTAssertFalse(coordinator.hasPendingOrActiveAttempt(id: id))
        XCTAssertFalse(coordinator.claimPendingResume(
            downloadID: id,
            session: session,
            webView: session.webView
        ))
    }

    func testStaleBrowserCallbacksCannotDismissReplacementSession() throws {
        var failedDownloadIDs: [UUID] = []
        let coordinator = BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { event in
                if case let .failed(id, _, _) = event {
                    failedDownloadIDs.append(id)
                }
            }
        )
        let sourceURL = try XCTUnwrap(URL(string: "https://example.test/download"))
        let firstID = UUID()
        let secondID = UUID()
        let firstSession = coordinator.startSession(
            downloadID: firstID,
            sourceURL: sourceURL,
            displayName: "First",
            resumeData: Data("first".utf8)
        )
        coordinator.cancelSession()
        let secondSession = coordinator.startSession(
            downloadID: secondID,
            sourceURL: sourceURL,
            displayName: "Second",
            resumeData: Data("second".utf8)
        )

        coordinator.webView(
            firstSession.webView,
            didFailProvisionalNavigation: nil,
            withError: URLError(.cannotConnectToHost)
        )
        coordinator.webViewDidClose(firstSession.webView)

        XCTAssertTrue(failedDownloadIDs.isEmpty)
        XCTAssertTrue(
            coordinator.claimPendingResume(
                downloadID: secondID,
                session: secondSession,
                webView: secondSession.webView
            )
        )
    }

    func testRestoredBrowserResumeDoesNotBlockNextQueuedDownload() async throws {
        let suiteName = "HarborTests.BrowserResumeQueue.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let persistenceRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBrowserResumeQueueTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: persistenceRoot) }

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        settings.maxConcurrentDownloads = 1
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let olderBrowserItem = DownloadItem(
            createdAt: .now.addingTimeInterval(-10),
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/browser-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued,
            browserResumeData: Data("browser-resume".utf8)
        )
        let newerDirectItem = DownloadItem(
            createdAt: .now,
            sourceURL: try XCTUnwrap(URL(string: "harbor-test://ordinary-download")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        try await persistence.save([
            olderBrowserItem.makeRecord(),
            newerDirectItem.makeRecord()
        ])

        let center = DownloadCenter(settings: settings, persistence: persistence)
        await center.initializeIfNeeded()

        let restoredBrowserItem = try XCTUnwrap(
            center.downloads.first { $0.id == olderBrowserItem.id }
        )
        let restoredDirectItem = try XCTUnwrap(
            center.downloads.first { $0.id == newerDirectItem.id }
        )
        XCTAssertEqual(restoredBrowserItem.status, .browserSessionRequired)
        XCTAssertNotEqual(restoredDirectItem.status, .queued)
        XCTAssertNotNil(restoredDirectItem.startedAt)

        await center.shutdownForTermination()
    }


    func testReentrantQueueDrainDoesNotRestartFailedSnapshotItem() async throws {
        let suiteName = "HarborTests.ReentrantQueueDrain.\(UUID().uuidString)"
        let userDefaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        userDefaults.removePersistentDomain(forName: suiteName)
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborReentrantQueueDrainTests-\(UUID().uuidString)", isDirectory: true)
        let persistenceRoot = testRoot.appendingPathComponent("Persistence", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer {
            try? fileManager.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: recoveryRoot.path
            )
            try? fileManager.removeItem(at: testRoot)
        }
        try fileManager.createDirectory(at: testRoot, withIntermediateDirectories: true)

        let settings = AppSettingsStore(userDefaults: userDefaults)
        settings.startDownloadsAutomatically = true
        settings.maxConcurrentDownloads = 1
        let persistence = DownloadPersistence(directoryURL: persistenceRoot)
        let firstItem = DownloadItem(
            createdAt: .now.addingTimeInterval(-10),
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/first.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        let secondItem = DownloadItem(
            createdAt: .now,
            sourceURL: try XCTUnwrap(URL(string: "https://example.test/second.bin")),
            sourceKind: .directURL,
            backend: .urlSession,
            preferredFilename: nil,
            destinationFolderPath: "/tmp",
            status: .queued
        )
        try fileManager.createDirectory(at: recoveryRoot, withIntermediateDirectories: true)
        for item in [firstItem, secondItem] {
            try Data("partial".utf8).write(
                to: recoveryRoot
                    .appendingPathComponent(item.id.uuidString)
                    .appendingPathExtension("part")
            )
        }
        try fileManager.setAttributes(
            [.posixPermissions: 0o555],
            ofItemAtPath: recoveryRoot.path
        )
        try await persistence.save([firstItem.makeRecord(), secondItem.makeRecord()])

        let center = DownloadCenter(
            settings: settings,
            persistence: persistence,
            directRecoveryDirectoryURL: recoveryRoot
        )
        await center.initializeIfNeeded()

        for itemID in [firstItem.id, secondItem.id] {
            let restoredItem = try XCTUnwrap(center.downloads.first { $0.id == itemID })
            XCTAssertEqual(restoredItem.status, .failed)
            XCTAssertEqual(
                restoredItem.activityEvents.filter { $0.kind == .started }.count,
                0,
                "Strict recovery preflight must reject the unsafe partial before URLSession starts"
            )
            XCTAssertEqual(
                restoredItem.activityEvents.filter { $0.kind == .failed }.count,
                1
            )
        }

        await center.shutdownForTermination()
    }
}
