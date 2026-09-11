import CryptoKit
import Foundation
import WebKit
import XCTest
@testable import Harbor

@MainActor
final class DownloadCleanupFaultRaceTests: XCTestCase {
    func testPendingBrowserCancelOverridesPauseForEveryWaiter() async throws {
        let coordinator = makeBrowserCoordinator()
        let id = UUID()
        let session = coordinator.startSession(
            downloadID: id,
            sourceURL: URL(string: "https://example.test/download")!,
            displayName: "Download",
            resumeData: Data("original-resume-data".utf8)
        )
        let started = AsyncStream<Void>.makeStream()
        let pause = Task { @MainActor in
            started.continuation.yield(())
            return await coordinator.quiesceDownload(id: id)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        started.continuation.finish()

        let cancelled = await coordinator.quiesceDownload(id: id, cancelling: true)
        let paused = await pause.value

        XCTAssertEqual(paused?.attemptIdentifier, session.attemptIdentifier)
        XCTAssertEqual(cancelled?.attemptIdentifier, session.attemptIdentifier)
        XCTAssertNil(paused?.resumeData, "A later cancel must clear data for earlier pause waiters too")
        XCTAssertNil(cancelled?.resumeData)
        XCTAssertFalse(coordinator.hasPendingOrActiveAttempt(id: id))
    }

    func testReplacingPendingBrowserAttemptDrainsOldWaiterWithoutClaimingReplacement() async throws {
        let coordinator = makeBrowserCoordinator()
        let id = UUID()
        let originalData = Data("original-resume-data".utf8)
        let oldSession = coordinator.startSession(
            downloadID: id,
            sourceURL: URL(string: "https://example.test/download")!,
            displayName: "Original",
            resumeData: originalData
        )
        let started = AsyncStream<Void>.makeStream()
        let pause = Task { @MainActor in
            started.continuation.yield(())
            return await coordinator.quiesceDownload(id: id)
        }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        started.continuation.finish()

        let replacement = coordinator.startSession(
            downloadID: id,
            attemptIdentifier: UUID(),
            sourceURL: oldSession.sourceURL,
            displayName: "Replacement",
            resumeData: Data("replacement-resume-data".utf8)
        )
        let result = await pause.value

        XCTAssertEqual(result?.attemptIdentifier, oldSession.attemptIdentifier)
        XCTAssertEqual(result?.resumeData, originalData)
        XCTAssertFalse(coordinator.claimPendingResume(
            downloadID: id, attemptIdentifier: oldSession.attemptIdentifier,
            session: oldSession, webView: oldSession.webView
        ))
        XCTAssertTrue(coordinator.claimPendingResume(
            downloadID: id, attemptIdentifier: replacement.attemptIdentifier,
            session: replacement, webView: replacement.webView
        ))
        coordinator.cancelSession()
    }

    func testKeepStoppedDuringApprovalSaveRetainsDurableRepairGate() async throws {
        let fixture = try makeTorrentFixture()
        defer { fixture.remove() }
        try await fixture.persistence.save([fixture.item.makeRecord()])
        let saveEntered = AsyncTestGate()
        let releaseSave = AsyncTestGate()
        let saveCount = AsyncTestCounter()
        let center = makeCenter(fixture: fixture) { persistence, records, revision in
            if await saveCount.incrementAndGet() == 1 {
                await saveEntered.release()
                await releaseSave.wait()
            }
            try await persistence.save(records, revision: revision)
        }
        center.downloads = [fixture.item]

        center.downloadMissingTorrentPieces(id: fixture.item.id)
        let approval = try XCTUnwrap(center.torrentCheckTask(for: fixture.item.id))
        await saveEntered.wait()
        center.keepTorrentStopped(id: fixture.item.id)
        await releaseSave.release()
        await approval.value

        // Read before the delayed persistence task can repair the record.
        // A completed cancellation must also be safe if the app crashes now.
        let records = try await fixture.persistence.load()
        let restored = try XCTUnwrap(records.first { $0.id == fixture.item.id })
        XCTAssertNotNil(fixture.item.torrentCheckState, "Stop must revoke the pending repair approval")
        XCTAssertNotNil(restored.torrentCheckState, "Relaunch must still require repair approval")
        XCTAssertFalse(fixture.item.shouldSeedAfterDownload)
        XCTAssertEqual(fixture.item.status, .paused)
        await center.shutdownForTermination()
    }

    func testFailedApprovalSavePreservesDurableCheckResult() async throws {
        struct SaveFailure: LocalizedError {
            var errorDescription: String? { "Injected approval save failure" }
        }
        let fixture = try makeTorrentFixture()
        defer { fixture.remove() }
        try await fixture.persistence.save([fixture.item.makeRecord()])
        let saveCount = AsyncTestCounter()
        let center = makeCenter(fixture: fixture) { persistence, records, revision in
            if await saveCount.incrementAndGet() == 1 { throw SaveFailure() }
            try await persistence.save(records, revision: revision)
        }
        center.downloads = [fixture.item]

        center.downloadMissingTorrentPieces(id: fixture.item.id)
        let approval = try XCTUnwrap(center.torrentCheckTask(for: fixture.item.id))
        await approval.value

        XCTAssertEqual(fixture.item.lastError, "Injected approval save failure")
        XCTAssertEqual(fixture.item.torrentCheckState, .incomplete)
        XCTAssertNil(fixture.item.backendIdentifier)
        let records = try await fixture.persistence.load()
        XCTAssertEqual(records.first?.torrentCheckState, .incomplete)
        XCTAssertEqual(records.first?.torrentExistingDataPath, fixture.item.torrentExistingDataPath)
        await center.shutdownForTermination()
    }

    func testStreamingCheckRejectsFileReplacementAfterIdentityCapture() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborCheckReplacement-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("data".utf8)
        let file = root.appendingPathComponent("payload.bin")
        let replacement = root.appendingPathComponent("replacement.bin")
        try payload.write(to: file)
        try payload.write(to: replacement)
        let captured = AsyncTestGate()
        let resume = AsyncTestGate()
        let metainfo = singleFileMetainfo(payload: payload)
        let check = Task {
            do {
                return try await Aria2TorrentService().checkExistingData(metainfo: metainfo, location: file) { progress in
                    if progress == 0 {
                        await captured.release()
                        await resume.wait()
                    }
                }
            } catch {
                await captured.release()
                throw error
            }
        }
        await captured.wait()
        // Identical bytes at a new inode must not inherit the captured identity.
        do {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.moveItem(at: replacement, to: file)
        } catch {
            await resume.release()
            _ = await check.result
            throw error
        }
        await resume.release()
        do {
            _ = try await check.value
            XCTFail("A replaced file must not receive a successful check result")
        } catch TorrentCheckReadError.changedDuringCheck {
            // Expected: the replacement invalidates the identity snapshot.
        }
        XCTAssertEqual(try Data(contentsOf: file), payload)
    }

    func testCancellingStreamingCheckCancelsDetachedReaderWithoutChangingFiles() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborCheckCancellation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data("data".utf8)
        let file = root.appendingPathComponent("payload.bin")
        try payload.write(to: file)
        let captured = AsyncTestGate()
        let resume = AsyncTestGate()
        let metainfo = singleFileMetainfo(payload: payload)
        let check = Task {
            do {
                return try await Aria2TorrentService().checkExistingData(metainfo: metainfo, location: file) { progress in
                    if progress == 0 {
                        await captured.release()
                        await resume.wait()
                    }
                }
            } catch {
                await captured.release()
                throw error
            }
        }
        await captured.wait()
        check.cancel()
        await resume.release()
        do {
            _ = try await check.value
            XCTFail("Cancellation must reach the detached verifier")
        } catch is CancellationError {
            // Expected: no check result is published after cancellation.
        }
        XCTAssertEqual(try Data(contentsOf: file), payload)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["payload.bin"])
    }

    private func singleFileMetainfo(payload: Data) -> Data {
        var data = Data("d4:infod6:lengthi\(payload.count)e4:name11:payload.bin12:piece lengthi\(payload.count)e6:pieces20:".utf8)
        data.append(contentsOf: Insecure.SHA1.hash(data: payload))
        data.append(Data("ee".utf8))
        return data
    }

    private func makeBrowserCoordinator() -> BrowserDownloadCoordinator {
        BrowserDownloadCoordinator(
            resumeDownload: { _, _, _ in },
            cancelUnownedDownload: { _ in },
            onEvent: { _ in }
        )
    }

    private struct TorrentFixture {
        let root: URL
        let suiteName: String
        let defaults: UserDefaults
        let persistence: DownloadPersistence
        let item: DownloadItem

        func remove() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func makeTorrentFixture() throws -> TorrentFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborCleanupFaultRaces-\(UUID().uuidString)")
        let suiteName = "HarborTests.CleanupFaultRaces.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let item = DownloadItem(
            sourceURL: URL(string: "magnet:?xt=urn:btih:0123456789012345678901234567890123456789")!,
            sourceKind: .magnetLink, backend: .aria2, preferredFilename: nil,
            destinationFolderPath: root.path, status: .paused,
            torrentCheckState: .incomplete,
            torrentExistingDataPath: root.appendingPathComponent("payload").path,
            shouldSeedAfterDownload: false
        )
        return TorrentFixture(root: root, suiteName: suiteName, defaults: defaults,
                              persistence: DownloadPersistence(directoryURL: root.appendingPathComponent("Records")),
                              item: item)
    }

    private func makeCenter(
        fixture: TorrentFixture,
        save: @escaping DownloadCenter.RecordSaveOperation
    ) -> DownloadCenter {
        let settings = AppSettingsStore(userDefaults: fixture.defaults)
        settings.seedNewTorrents = false
        // Leave initialization unopened: these tests exercise the approval
        // transaction without allowing a successful approval to launch aria2.
        return DownloadCenter(
            settings: settings, persistence: fixture.persistence,
            directRecoveryDirectoryURL: fixture.root.appendingPathComponent("Direct"),
            completedHandoffDirectoryURL: fixture.root.appendingPathComponent("Handoffs"),
            browserRecoveryDirectoryURL: fixture.root.appendingPathComponent("Browser"),
            mediaService: MediaDownloadService(eventHandler: { _, _ in },
                                               temporaryRoot: fixture.root.appendingPathComponent("Media")),
            torrentShutdownOperation: { _ in },
            recordSaveOperation: save
        )
    }
}
