import Darwin
import Foundation
import XCTest
@testable import Harbor

extension HarborModelAndSafetyTests {
    func testPeerBlocklistSurvivesTorrentDaemonRestart() async throws {
        guard Aria2BinaryResolver.resolveBinaryURL() != nil else {
            throw XCTSkip("The bundled Aria2 Next runtime is not available in this test build.")
        }

        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborBlocklistRestartTests-\(UUID().uuidString)", isDirectory: true)
        let environmentKey = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(environmentKey).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(environmentKey, previousValue, 1)
            } else {
                unsetenv(environmentKey)
            }
            try? fileManager.removeItem(at: applicationSupportURL)
        }
        setenv(environmentKey, applicationSupportURL.path, 1)

        let service = Aria2TorrentService()
        let applied = try await service.setPeerBlocklist(["192.0.2.1"])
        XCTAssertEqual(applied.ruleCount, 1)

        await service.setNetworkBinding(
            .bound(
                displayName: "Loopback",
                binding: ResolvedNetworkBinding(
                    interfaceName: "lo0",
                    ipv4Address: "127.0.0.1"
                )
            )
        )
        let cleared = try await service.setPeerBlocklist([])
        try await service.shutdown()

        XCTAssertEqual(cleared.ruleCount, 0)
        XCTAssertEqual(cleared.revision, 2)
    }

    func testBundledAriaNextDaemonMigratesLegacySessionAndPersistsOwnership() async throws {
        guard Aria2BinaryResolver.resolveBinaryURL() != nil else {
            throw XCTSkip("The bundled Aria2 Next runtime is not available in this test build.")
        }

        let fileManager = FileManager.default
        let applicationSupportURL = fileManager.temporaryDirectory
            .appendingPathComponent("HarborAriaStartupTests-\(UUID().uuidString)", isDirectory: true)
        let environmentKey = "HARBOR_APPLICATION_SUPPORT_DIR"
        let previousValue = getenv(environmentKey).map { String(cString: $0) }
        defer {
            if let previousValue {
                setenv(environmentKey, previousValue, 1)
            } else {
                unsetenv(environmentKey)
            }
            try? fileManager.removeItem(at: applicationSupportURL)
        }
        setenv(environmentKey, applicationSupportURL.path, 1)

        let harborSupportURL = applicationSupportURL
            .appendingPathComponent("Harbor", isDirectory: true)
        try fileManager.createDirectory(at: harborSupportURL, withIntermediateDirectories: true)
        let legacySessionURL = harborSupportURL.appendingPathComponent("aria2.session")
        let legacySession = """
        magnet:?xt=urn:btih:0123456789abcdef0123456789abcdef01234567
         gid=1234567890abcdef
         pause=true

        """
        try Data(legacySession.utf8).write(to: legacySessionURL)

        let service = Aria2TorrentService()
        var startupError: Error?
        do {
            let knownGIDs = try await service.allKnownGIDs()
            XCTAssertEqual(knownGIDs, Set(["1234567890abcdef"]))
        } catch {
            startupError = error
        }
        try? await service.shutdown()

        if let startupError {
            throw startupError
        }
        XCTAssertEqual(try Data(contentsOf: legacySessionURL), Data(legacySession.utf8))
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: harborSupportURL.appendingPathComponent("aria2-next.session").path
            )
        )
        var isStateDirectory: ObjCBool = false
        XCTAssertTrue(
            fileManager.fileExists(
                atPath: harborSupportURL.appendingPathComponent("aria2-next-state").path,
                isDirectory: &isStateDirectory
            )
        )
        XCTAssertTrue(isStateDirectory.boolValue)
        XCTAssertFalse(
            fileManager.fileExists(
                atPath: applicationSupportURL
                    .appendingPathComponent("aria2.daemon-owner.json")
                    .path
            )
        )
    }

    func testMediaRecoveryCleanupPreservesRecordedFoldersAndRemovesOrphans() async throws {
        let fileManager = FileManager.default
        let recoveryRoot = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: recoveryRoot) }

        let retainedID = UUID()
        let orphanedID = UUID()
        let retainedFolder = recoveryRoot.appendingPathComponent(retainedID.uuidString, isDirectory: true)
        let orphanedFolder = recoveryRoot.appendingPathComponent(orphanedID.uuidString, isDirectory: true)
        let unrelatedFolder = recoveryRoot.appendingPathComponent("not-a-download", isDirectory: true)
        for folder in [retainedFolder, orphanedFolder, unrelatedFolder] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        }

        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )
        try await service.discardOrphanedRecoveryData(retaining: Set([retainedID]))

        XCTAssertTrue(fileManager.fileExists(atPath: retainedFolder.path))
        XCTAssertFalse(fileManager.fileExists(atPath: orphanedFolder.path))
        XCTAssertTrue(fileManager.fileExists(atPath: unrelatedFolder.path))

        try await service.discardRecoveryData(id: retainedID)
        XCTAssertFalse(fileManager.fileExists(atPath: retainedFolder.path))
    }

    func testOnlyExplicitAriaRPCRejectionMakesMutationFailureDefinitive() {
        XCTAssertFalse(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                URLError(.timedOut)
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                TorrentEngineError.invalidResponse
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.mutationFailureWasExplicitlyRejected(
                TorrentEngineError.rpc("The mutation was rejected")
            )
        )
    }

    func testAriaOwnershipMarkerAcceptsCurrentOrReparentedDaemonOnly() {
        XCTAssertTrue(
            Aria2TorrentService.isVerifiedOwnershipParent(
                4321,
                currentProcessIdentifier: 4321
            )
        )
        XCTAssertTrue(
            Aria2TorrentService.isVerifiedOwnershipParent(
                1,
                currentProcessIdentifier: 4321
            )
        )
        XCTAssertFalse(
            Aria2TorrentService.isVerifiedOwnershipParent(
                9876,
                currentProcessIdentifier: 4321
            )
        )
    }

    func testMediaProcessOwnershipRequiresExactPersistedIdentity() throws {
        let temporaryRoot = URL(
            fileURLWithPath: "/tmp/HarborMediaOwnership",
            isDirectory: true
        )
        let downloadID = UUID()
        let launchedExecutablePath = "/Applications/Harbor.app/Contents/Resources/MediaRuntime/bin/yt-dlp"
        let executablePath = "/usr/bin/python3"
        let temporaryFolder = temporaryRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let command = "\(executablePath) \(launchedExecutablePath) --paths temp:\(temporaryFolder.path) https://example.test/video"
        let manifest = MediaProcessOwnershipManifest(
            downloadID: downloadID,
            attemptIdentifier: UUID(),
            pid: 9_001,
            processGroupIdentifier: 9_001,
            launchedExecutablePath: launchedExecutablePath,
            executablePath: executablePath,
            temporaryFolderPath: temporaryFolder.path,
            startSignature: "1786420000:123456",
            command: command
        )
        let exactOwner = MediaRunningProcess(
            pid: 9_001,
            parentPID: 1,
            processGroupIdentifier: 9_001,
            executablePath: executablePath,
            startSignature: manifest.startSignature,
            command: command
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                MediaProcessOwnershipManifest.self,
                from: JSONEncoder().encode(manifest)
            ),
            manifest
        )

        XCTAssertTrue(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                exactOwner,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let unrelatedReader = MediaRunningProcess(
            pid: manifest.pid,
            parentPID: 1,
            processGroupIdentifier: manifest.processGroupIdentifier,
            executablePath: "/usr/bin/tail",
            startSignature: manifest.startSignature,
            command: "/usr/bin/tail -f \(temporaryFolder.appendingPathComponent("payload.part").path)"
        )
        XCTAssertFalse(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                unrelatedReader,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let reusedIdentity = MediaRunningProcess(
            pid: exactOwner.pid,
            parentPID: exactOwner.parentPID,
            processGroupIdentifier: exactOwner.processGroupIdentifier,
            executablePath: exactOwner.executablePath,
            startSignature: "1786420000:123457",
            command: exactOwner.command
        )
        XCTAssertFalse(
            MediaDownloadService.isVerifiedOwnedRootProcess(
                reusedIdentity,
                manifest: manifest,
                currentProcessIdentifier: 8_000,
                currentProcessGroupIdentifier: 8_000,
                temporaryRoot: temporaryRoot
            )
        )

        let survivingChild = MediaRunningProcess(
            pid: 9_002,
            parentPID: manifest.pid,
            processGroupIdentifier: manifest.processGroupIdentifier,
            executablePath: "/Applications/Harbor.app/Contents/Resources/MediaRuntime/bin/ffmpeg",
            startSignature: "1786420001:123456",
            command: "ffmpeg -i \(temporaryFolder.appendingPathComponent("payload.part").path)"
        )
        XCTAssertTrue(
            MediaDownloadService.hasLiveProcessGroupMember(
                manifest.processGroupIdentifier,
                in: [survivingChild]
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasLiveProcessGroupMember(
                manifest.processGroupIdentifier,
                in: []
            )
        )
        XCTAssertTrue(
            MediaDownloadService.hasProcessReferencingRecoveryFolder(
                temporaryFolder,
                in: [unrelatedReader]
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasProcessReferencingRecoveryFolder(
                temporaryFolder,
                in: [
                    MediaRunningProcess(
                        pid: 9_003,
                        parentPID: 1,
                        processGroupIdentifier: 9_003,
                        executablePath: "/usr/bin/true",
                        startSignature: "1786420002:123456",
                        command: "/usr/bin/true"
                    )
                ]
            )
        )
        XCTAssertTrue(
            MediaDownloadService.hasUntrackedProcessReferencingRecoveryRoot(
                temporaryRoot,
                in: [survivingChild],
                trackedProcessGroups: []
            )
        )
        XCTAssertFalse(
            MediaDownloadService.hasUntrackedProcessReferencingRecoveryRoot(
                temporaryRoot,
                in: [survivingChild],
                trackedProcessGroups: [manifest.processGroupIdentifier]
            )
        )
    }

    func testMediaRecoveryCleanupPreservesDurableProcessOwnershipMarker() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaOwnedCleanup-\(UUID().uuidString)")
        let downloadID = UUID()
        let recoveryFolder = root
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let ownershipMarker = recoveryFolder
            .appendingPathComponent(".harbor-process-owner.json")
        defer { try? fileManager.removeItem(at: root) }

        try fileManager.createDirectory(
            at: recoveryFolder,
            withIntermediateDirectories: true
        )
        try Data("unverifiable-owner".utf8).write(to: ownershipMarker)
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: root
        )

        do {
            try await service.discardRecoveryData(id: downloadID)
            XCTFail("Cleanup must fail closed while durable process ownership remains")
        } catch {
            XCTAssertTrue(fileManager.fileExists(atPath: recoveryFolder.path))
            XCTAssertTrue(fileManager.fileExists(atPath: ownershipMarker.path))
        }

        // A process scan is the authority that can retire malformed ownership
        // metadata: with no writer referencing the recovery root, cleanup can
        // safely remove the marker and then the recovery directory.
        try await service.terminateOrphanedMediaProcesses()
        XCTAssertFalse(fileManager.fileExists(atPath: ownershipMarker.path))
        try await service.discardRecoveryData(id: downloadID)
        XCTAssertFalse(fileManager.fileExists(atPath: recoveryFolder.path))

        let redirectedID = UUID()
        let redirectedTarget = root.appendingPathComponent("redirected", isDirectory: true)
        let redirectedFolder = root.appendingPathComponent(
            redirectedID.uuidString,
            isDirectory: true
        )
        try fileManager.createDirectory(at: redirectedTarget, withIntermediateDirectories: true)
        try Data("external-fragment".utf8).write(
            to: redirectedTarget.appendingPathComponent("payload.part")
        )
        try fileManager.createSymbolicLink(
            at: redirectedFolder,
            withDestinationURL: redirectedTarget
        )
        let redirectedBytes = await service.recoverableByteCount(id: redirectedID)
        XCTAssertNil(redirectedBytes)
        do {
            try await service.discardRecoveryData(id: redirectedID)
            XCTFail("Cleanup must not remove a symlinked media recovery folder")
        } catch {}
        XCTAssertEqual(
            try Data(contentsOf: redirectedTarget.appendingPathComponent("payload.part")),
            Data("external-fragment".utf8)
        )
        XCTAssertTrue(fileManager.fileExists(atPath: redirectedFolder.path))
    }

    func testMediaRecoveryCleanupRejectsSymlinkedRootWithoutDeletingTarget() async throws {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaSymlinkedRoot-\(UUID().uuidString)")
        let recoveryRoot = container.appendingPathComponent("Recovery", isDirectory: true)
        let externalRoot = container.appendingPathComponent("External", isDirectory: true)
        let downloadID = UUID()
        let externalFolder = externalRoot
            .appendingPathComponent(downloadID.uuidString, isDirectory: true)
        let externalPayload = externalFolder.appendingPathComponent("payload.part")
        defer { try? fileManager.removeItem(at: container) }

        try fileManager.createDirectory(
            at: externalFolder,
            withIntermediateDirectories: true
        )
        let payload = Data("not-owned-by-harbor".utf8)
        try payload.write(to: externalPayload)
        try fileManager.createSymbolicLink(
            at: recoveryRoot,
            withDestinationURL: externalRoot
        )
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: recoveryRoot
        )

        do {
            try await service.discardRecoveryData(id: downloadID)
            XCTFail("Item cleanup must reject a symlinked media recovery root")
        } catch {}
        do {
            try await service.discardOrphanedRecoveryData(retaining: [])
            XCTFail("Orphan cleanup must reject a symlinked media recovery root")
        } catch {}
        do {
            try await service.terminateOrphanedMediaProcesses()
            XCTFail("Ownership cleanup must reject a symlinked media recovery root")
        } catch {}

        XCTAssertTrue(fileManager.fileExists(atPath: externalFolder.path))
        XCTAssertEqual(try Data(contentsOf: externalPayload), payload)
    }

    func testMediaCompletionRejectsUnchangedPreexistingDestinationIdentity() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("HarborMediaOutputIdentity-\(UUID().uuidString)")
        let outputURL = root.appendingPathComponent("video.mp4")
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("existing-output".utf8).write(to: outputURL)
        let service = MediaDownloadService(
            eventHandler: { _, _ in },
            fileManager: fileManager,
            temporaryRoot: root.appendingPathComponent("Recovery")
        )

        let before = try await service.regularFileIdentity(at: outputURL)
        let unchanged = try await service.regularFileIdentity(at: outputURL)
        XCTAssertFalse(
            MediaDownloadService.isAttemptProducedOutput(
                previousIdentity: before,
                currentIdentity: unchanged
            )
        )

        try Data("new-attempt-output".utf8).write(to: outputURL, options: .atomic)
        let replaced = try await service.regularFileIdentity(at: outputURL)
        XCTAssertTrue(
            MediaDownloadService.isAttemptProducedOutput(
                previousIdentity: before,
                currentIdentity: replaced
            )
        )
    }

    func testManagedChildProcessDrainsFinalOutputBeforeTermination() async throws {
        let state = ManagedProcessTestState()
        let terminated = expectation(description: "child process terminated")
        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "printf 'stdout-first\\nstdout-tail'; printf 'stderr-tail' >&2"
            ],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { state.appendStdout($0) },
            onStderr: { state.appendStderr($0) },
            onTermination: { termination in
                state.recordTermination(termination)
                terminated.fulfill()
            }
        )

        await fulfillment(of: [terminated], timeout: 3)
        let snapshot = state.snapshot
        XCTAssertEqual(snapshot.stdout, "stdout-first\nstdout-tail")
        XCTAssertEqual(snapshot.stderr, "stderr-tail")
        XCTAssertEqual(snapshot.stdoutAtTermination, snapshot.stdout)
        XCTAssertEqual(snapshot.stderrAtTermination, snapshot.stderr)
        XCTAssertTrue(snapshot.termination?.isSuccess == true)
        withExtendedLifetime(process) {}
    }

    func testManagedChildProcessStopsWhenOneOutputLineExceedsLimit() async throws {
        let state = ManagedProcessTestState()
        let exceededLimit = expectation(description: "output limit exceeded")
        let terminated = expectation(description: "limited child process terminated")
        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '%4096s' x"],
            environment: ProcessInfo.processInfo.environment,
            maximumBufferedLineBytes: 1_024,
            onOutputLimitExceeded: {
                exceededLimit.fulfill()
            },
            onStdout: { state.appendStdout($0) },
            onStderr: { state.appendStderr($0) },
            onTermination: { termination in
                state.recordTermination(termination)
                terminated.fulfill()
            }
        )

        await fulfillment(of: [exceededLimit, terminated], timeout: 4)
        XCTAssertTrue(state.snapshot.stdout.isEmpty)
        XCTAssertNotNil(state.snapshot.termination)
        withExtendedLifetime(process) {}
    }

    func testMetadataCommandStateReleasesFinishedProcessAndBoundsOutput() async throws {
        let state = MetadataCommandState(maximumCapturedBytes: 16)
        XCTAssertTrue(state.appendStdout("12345678"))
        XCTAssertFalse(state.appendStderr("123456789"))
        let limitedResult = state.finish(
            termination: ManagedChildProcessTermination(waitStatus: 0)
        )
        guard case let .failure(error)? = limitedResult else {
            return XCTFail("Expected oversized metadata output to fail")
        }
        XCTAssertTrue(error.localizedDescription.contains("too much metadata"))

        let processState = MetadataCommandState()
        let terminated = expectation(description: "metadata child process terminated")
        var process: ManagedChildProcess? = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "printf '{}\\n'"],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { _ = processState.appendStdout($0) },
            onStderr: { _ = processState.appendStderr($0) },
            onTermination: { termination in
                _ = processState.finish(termination: termination)
                terminated.fulfill()
            }
        )
        processState.process = process
        weak var weakProcess = process

        await fulfillment(of: [terminated], timeout: 3)
        process = nil
        for _ in 0 ..< 40 where weakProcess != nil {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertNil(weakProcess)
    }

    func testManagedChildProcessTerminatesProcessGroup() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborProcessGroupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }

        let childPIDURL = temporaryDirectory.appendingPathComponent("child.pid")
        let state = ManagedProcessTestState()
        let terminated = expectation(description: "managed process group terminated")
        let process = try ManagedChildProcess(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "sleep 30 & echo $! > '\(childPIDURL.path)'; wait"],
            environment: ProcessInfo.processInfo.environment,
            onStdout: { state.appendStdout($0) },
            onStderr: { state.appendStderr($0) },
            onTermination: { termination in
                state.recordTermination(termination)
                terminated.fulfill()
            }
        )
        defer { process.terminate(grace: 0) }

        var childPID: pid_t?
        for _ in 0 ..< 40 {
            if let text = try? String(contentsOf: childPIDURL, encoding: .utf8),
               let parsedPID = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                childPID = parsedPID
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let unwrappedChildPID = try XCTUnwrap(childPID)

        process.terminate(grace: 0.2)
        await fulfillment(of: [terminated], timeout: 4)
        try await Task.sleep(for: .milliseconds(400))

        let childStillExists = kill(unwrappedChildPID, 0) == 0
        if childStillExists {
            _ = kill(unwrappedChildPID, SIGKILL)
        }
        XCTAssertFalse(childStillExists)
        XCTAssertNotNil(state.snapshot.termination)
        withExtendedLifetime(process) {}
    }

}
