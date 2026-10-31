import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testInterruptedDirectDownloadContinuesFromOwnedPartialFile() async throws {
        InterruptingRangeURLProtocol.reset()

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborDirectRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }
        let destination = testRoot.appendingPathComponent("Destination", isDirectory: true)
        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
        let storage = DownloadStorageLocations(directoryURL: testRoot)
        try storage.preserveLegacyLocations(for: [])
        let id = UUID()
        try storage.prepare(id: id, destination: destination)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]

        let firstFailure = expectation(description: "The first request is interrupted")
        let completion = expectation(description: "The range request completes the file")
        let eventState = DirectDownloadTestEventState()

        let handleEvent: DownloadCoordinator.EventHandler = { event in
            switch event {
            case let .failed(_, _, failure):
                if eventState.recordFailure(failure) == 1 {
                    firstFailure.fulfill()
                }
            case let .progress(_, _, bytesWritten, expectedBytes, _):
                eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
            case let .finished(_, _, handoff):
                eventState.recordCompletion(handoff)
                completion.fulfill()
            default:
                break
            }
        }
        func makeCoordinator(storage: DownloadStorageLocations) -> DownloadCoordinator {
            DownloadCoordinator(
                eventHandler: handleEvent,
                fileManager: fileManager,
                recoveryDirectoryURL: recoveryRoot,
                completedHandoffStore: CompletedDownloadHandoffStore(
                    directoryURL: testRoot.appendingPathComponent("LegacyHandoffs"),
                    storageLocations: storage
                ),
                storageLocations: storage,
                sessionConfiguration: configuration
            )
        }
        let coordinator = makeCoordinator(storage: storage)

        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [firstFailure], timeout: 2)

        let failure = eventState.firstFailure
        XCTAssertEqual(failure?.recoverableBytes, 5)
        XCTAssertFalse(failure?.requiresFreshStart ?? true)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            5
        )

        XCTAssertFalse(fileManager.fileExists(atPath: recoveryRoot.path))
        let partial = destination.appendingPathComponent(".harbor-downloads/DirectDownloadRecovery/\(id.uuidString).part")
        XCTAssertEqual(try Data(contentsOf: partial), Data("abcde".utf8))

        let reloadedCoordinator = makeCoordinator(storage: DownloadStorageLocations(directoryURL: testRoot))
        try reloadedCoordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let unwrappedResultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: unwrappedResultURL) }
        XCTAssertEqual(try Data(contentsOf: unwrappedResultURL), Data("abcdefghij".utf8))
        XCTAssertTrue(unwrappedResultURL.path.hasPrefix(destination.appendingPathComponent(".harbor-downloads/CompletedDownloadHandoffs").path + "/"))
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        let requests = InterruptingRangeURLProtocol.capturedHeaders
        XCTAssertEqual(requests.count, 2)
        XCTAssertNil(requests[0].range)
        XCTAssertEqual(requests[1].range, "bytes=5-")
        XCTAssertEqual(requests[1].ifRange, "\"test-etag\"")
    }

    func testStorageMigrationKeepsLegacyRecoveryAndOnlyRunsOnce() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("HarborStorageMigration-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let oldID = UUID()
        let newID = UUID()
        let storage = DownloadStorageLocations(directoryURL: root)
        let legacy = root.appendingPathComponent("LegacyRecovery")
        try storage.preserveLegacyLocations(for: [oldID], directories: ["DirectDownloadRecovery": legacy])
        try storage.prepare(id: oldID, destination: root)
        XCTAssertEqual(storage.directory(for: oldID, name: "DirectDownloadRecovery", legacy: legacy), legacy)

        let restored = DownloadStorageLocations(directoryURL: root)
        XCTAssertEqual(restored.directory(for: oldID, name: "DirectDownloadRecovery", legacy: root.appendingPathComponent("ChangedDefault")), legacy)
        // A new queued record must not become a legacy download after relaunch.
        try restored.preserveLegacyLocations(for: [oldID, newID])
        try restored.prepare(id: newID, destination: root)
        let chosenRoot = restored.directory(for: newID, name: "DirectDownloadRecovery", legacy: legacy)
        XCTAssertEqual(chosenRoot, root.appendingPathComponent(".harbor-downloads/DirectDownloadRecovery", isDirectory: true))
        try restored.prepare(id: newID, destination: root, customRoot: root.appendingPathComponent("ChangedSetting"))
        XCTAssertEqual(restored.directory(for: newID, name: "DirectDownloadRecovery", legacy: legacy), chosenRoot)
    }

    func testChangedResumeValidatorRestartsWithoutCombiningRepresentations() async throws {
        InterruptingRangeURLProtocol.reset(changeValidatorOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborChangedValidatorTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial representation is interrupted")
        let changedValidatorFailure = expectation(description: "The changed representation is rejected")
        let completion = expectation(description: "A fresh request downloads the replacement representation")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: changedValidatorFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [changedValidatorFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("klmnopqrst".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-", nil]
        )
    }

    func testFullResponseFallbackDoesNotReusePartialRepresentationMetadata() async throws {
        InterruptingRangeURLProtocol.reset(fallbackToFullResponseOnFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborFallbackMetadataTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The old HTML representation is interrupted")
        let completion = expectation(description: "The full replacement response completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        initialFailure.fulfill()
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("uvwxyz12".utf8))
        XCTAssertNotEqual(eventState.completedSuggestedFilename, "old.html")
        XCTAssertNotEqual(eventState.completedResponseMimeType, "text/html")
        XCTAssertEqual(eventState.completedStatusCode, 200)
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, "bytes=5-"]
        )
    }

    func testCompletePartialKeepsPayloadMetadataWhenRangeResponseIsHTML() async throws {
        InterruptingRangeURLProtocol.reset(completePartialWithHTML416: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborComplete416MetadataTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        let recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let handle = try recoveryStore.openFreshFile(id: id)
        try handle.write(contentsOf: Data("abcde".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"test-etag\"",
                lastModified: nil,
                expectedBytes: 5,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let completion = expectation(description: "The complete partial is claimed")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                if case let .finished(_, _, handoff) = event {
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcde".utf8))
        XCTAssertEqual(eventState.completedSuggestedFilename, "archive.bin")
        XCTAssertEqual(eventState.completedResponseMimeType, "application/octet-stream")
        XCTAssertEqual(eventState.completedStatusCode, 206)
        XCTAssertEqual(InterruptingRangeURLProtocol.capturedHeaders.map(\.range), ["bytes=5-"])
    }

    func testUnsatisfiedRangeWithoutMatchingValidatorCannotCertifyCompletePartial() async throws {
        InterruptingRangeURLProtocol.reset(completePartialWithoutValidator416: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborUnvalidated416Tests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        let recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryRoot
        )
        let handle = try recoveryStore.openFreshFile(id: id)
        try handle.write(contentsOf: Data("abcde".utf8))
        try handle.close()
        try recoveryStore.saveMetadata(
            DirectDownloadRecoveryMetadata(
                sourceURL: sourceURL,
                entityTag: "\"test-etag\"",
                lastModified: nil,
                expectedBytes: 5,
                suggestedFilename: "archive.bin",
                mimeType: "application/octet-stream"
            ),
            id: id
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let failureExpectation = expectation(description: "The unvalidated 416 is rejected")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    _ = eventState.recordFailure(failure)
                    failureExpectation.fulfill()
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [failureExpectation], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.requiresFreshStart ?? false)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
        XCTAssertEqual(InterruptingRangeURLProtocol.capturedHeaders.map(\.range), ["bytes=5-"])
    }

    func testOverlongRangeResponseCannotPublishUndeclaredBytesOnRetry() async throws {
        InterruptingRangeURLProtocol.reset(overlongFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborOverlongRangeTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let initialFailure = expectation(description: "The initial transfer is interrupted")
        let overflowFailure = expectation(description: "The overlong range is rejected")
        let completion = expectation(description: "The safe range retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: initialFailure.fulfill()
                    case 2: overflowFailure.fulfill()
                    default: break
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [initialFailure], timeout: 2)

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [overflowFailure], timeout: 2)

        XCTAssertNil(eventState.completedURL)
        XCTAssertTrue(eventState.failures.last?.isRetryable ?? false)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 0)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let completedURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: completedURL) }
        XCTAssertEqual(try Data(contentsOf: completedURL), Data("abcdefghij".utf8))

        let requests = InterruptingRangeURLProtocol.capturedHeaders
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests[1].range, "bytes=5-")
        XCTAssertNil(requests[2].range)
    }

    func testValidatorlessInterruptedDownloadRestartsWithoutRange() async throws {
        InterruptingRangeURLProtocol.reset(omitValidator: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborValidatorlessDownloadTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The validator-less transfer is interrupted")
        let completion = expectation(description: "The fresh retry completes")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    if eventState.recordFailure(failure) == 1 {
                        firstFailure.fulfill()
                    }
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [firstFailure], timeout: 2)

        XCTAssertEqual(eventState.firstFailure?.recoverableBytes, 0)
        XCTAssertTrue(eventState.firstFailure?.requiresFreshStart ?? false)
        XCTAssertNil(coordinator.recoverySnapshot(id: id, sourceURL: sourceURL))
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: recoveryRoot
                    .appendingPathComponent(id.uuidString)
                    .appendingPathExtension("part")
                    .path
            )
        )
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: recoveryRoot
                    .appendingPathComponent(id.uuidString)
                    .appendingPathExtension("json")
                    .path
            )
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let resultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: resultURL) }
        XCTAssertEqual(try Data(contentsOf: resultURL), Data("abcdefghij".utf8))
        XCTAssertEqual(
            InterruptingRangeURLProtocol.capturedHeaders.map(\.range),
            [nil, nil]
        )
    }

    func testHTTPErrorDuringOwnedResumePreservesPartialAndDoesNotReportErrorBodyProgress() async throws {
        InterruptingRangeURLProtocol.reset(rejectFirstResume: true)

        let fileManager = FileManager.default
        let testRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborHTTPRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        let recoveryRoot = testRoot.appendingPathComponent("Recovery", isDirectory: true)
        defer { try? fileManager.removeItem(at: testRoot) }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InterruptingRangeURLProtocol.self]
        let firstFailure = expectation(description: "The initial transfer is interrupted")
        let rejectedResume = expectation(description: "The first range request receives an HTTP error")
        let completion = expectation(description: "The next range request completes the file")
        let eventState = DirectDownloadTestEventState()
        let coordinator = DownloadCoordinator(
            eventHandler: { event in
                switch event {
                case let .failed(_, _, failure):
                    switch eventState.recordFailure(failure) {
                    case 1: firstFailure.fulfill()
                    case 2: rejectedResume.fulfill()
                    default: break
                    }
                case let .progress(_, _, bytesWritten, expectedBytes, _):
                    eventState.recordProgress(bytesWritten: bytesWritten, expectedBytes: expectedBytes)
                case let .finished(_, _, handoff):
                    eventState.recordCompletion(handoff)
                    completion.fulfill()
                default:
                    break
                }
            },
            fileManager: fileManager,
            recoveryDirectoryURL: recoveryRoot,
            sessionConfiguration: configuration
        )

        let id = UUID()
        let sourceURL = try XCTUnwrap(URL(string: "https://recovery.example.test/file.bin"))
        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [firstFailure], timeout: 2)
        let progressCountBeforeRejection = eventState.progressCount

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [rejectedResume], timeout: 2)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(eventState.failures.last?.httpStatusCode, 403)
        XCTAssertEqual(eventState.failures.last?.recoverableBytes, 5)
        XCTAssertEqual(eventState.progressCount, progressCountBeforeRejection)
        XCTAssertEqual(
            coordinator.recoverySnapshot(id: id, sourceURL: sourceURL)?.bytesWritten,
            5
        )

        try coordinator.startDownload(id: id, sourceURL: sourceURL)
        await fulfillment(of: [completion], timeout: 2)

        let resultURL = try XCTUnwrap(eventState.completedURL)
        defer { try? fileManager.removeItem(at: resultURL) }
        XCTAssertEqual(try Data(contentsOf: resultURL), Data("abcdefghij".utf8))
    }
}
