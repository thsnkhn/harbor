import Darwin
import CryptoKit
import Foundation
import OSLog

nonisolated enum MediaDownloadFailureDisposition: Sendable {
    case ordinary
    case outputConflict
}

enum MediaDownloadEvent: Sendable {
    case started(id: UUID, processIdentifier: Int32, expectedBytes: Int64, title: String?, platform: String?)
    case progress(id: UUID, bytesWritten: Int64, expectedBytes: Int64, speedBytesPerSecond: Double)
    case paused(id: UUID)
    case cancelled(id: UUID)
    case finished(id: UUID, fileURL: URL, payloadURLs: [URL], expectedBytes: Int64)
    case failed(id: UUID, message: String, disposition: MediaDownloadFailureDisposition)
}

struct MediaTerminalOutcome: Sendable {
    let attemptIdentifier: UUID
    let event: MediaDownloadEvent
}

nonisolated struct MediaCompletedFileManifest: Codable, Sendable {
    let path: String
    let byteCount: Int64
    let sha256: String
}

nonisolated struct MediaCompletionManifest: Codable, Sendable {
    static let currentVersion = 1

    let version: Int
    let downloadID: UUID
    let attemptIdentifier: UUID
    let sourceURL: URL
    let destinationFolderPath: String
    let fileLocationPath: String
    let payloads: [MediaCompletedFileManifest]
    let actualBytes: Int64
    let createdAt: Date

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolderPath: String,
        fileLocationPath: String,
        payloads: [MediaCompletedFileManifest],
        actualBytes: Int64,
        createdAt: Date = .now
    ) {
        self.version = Self.currentVersion
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.sourceURL = sourceURL
        self.destinationFolderPath = destinationFolderPath
        self.fileLocationPath = fileLocationPath
        self.payloads = payloads
        self.actualBytes = actualBytes
        self.createdAt = createdAt
    }
}

nonisolated enum MediaCompletionEntry: Sendable {
    case valid(MediaCompletionManifest)
    case invalid(downloadID: UUID, message: String)
    case unavailable(downloadID: UUID, message: String)
}

nonisolated struct MediaProcessOwnershipManifest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    let version: Int
    let downloadID: UUID
    let attemptIdentifier: UUID
    let pid: pid_t
    let processGroupIdentifier: pid_t
    let launchedExecutablePath: String
    let executablePath: String
    let temporaryFolderPath: String
    let startSignature: String
    let command: String
    let createdAt: Date

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        pid: pid_t,
        processGroupIdentifier: pid_t,
        launchedExecutablePath: String,
        executablePath: String,
        temporaryFolderPath: String,
        startSignature: String,
        command: String,
        createdAt: Date = .now
    ) {
        self.version = Self.currentVersion
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.pid = pid
        self.processGroupIdentifier = processGroupIdentifier
        self.launchedExecutablePath = launchedExecutablePath
        self.executablePath = executablePath
        self.temporaryFolderPath = temporaryFolderPath
        self.startSignature = startSignature
        self.command = command
        self.createdAt = createdAt
    }
}

nonisolated struct MediaRunningProcess: Equatable, Sendable {
    let pid: pid_t
    let parentPID: pid_t
    let processGroupIdentifier: pid_t
    let executablePath: String?
    let startSignature: String?
    let command: String
}

enum MediaDownloadError: LocalizedError {
    case runtimeNotFound
    case unsupported(String)
    case unavailable(String)
    case processFailed(String)
    case outputConflict(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            MediaRuntimeResolver.installHint
        case let .unsupported(message),
             let .unavailable(message),
             let .processFailed(message),
             let .outputConflict(message):
            message
        }
    }
}

actor MediaDownloadService {
    typealias EventHandler = @Sendable (UUID, MediaDownloadEvent) -> Void

    private enum TerminationReason {
        case pause
        case cancel
    }

    private enum CompletionManifestIntegrityError: LocalizedError {
        case invalid(String)

        var errorDescription: String? {
            switch self {
            case let .invalid(message):
                message
            }
        }
    }

    typealias RegularFileIdentity = DurableFileSystem.RegularFileIdentity

    private struct MediaAttemptManifest: Codable, Equatable, Sendable {
        static let currentVersion = 1

        let version: Int
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let destinationFolderPath: String
        let isCollection: Bool
        let preexistingDestinationFiles: [String: RegularFileIdentity]
        let createdAt: Date

        init(
            downloadID: UUID,
            attemptIdentifier: UUID,
            sourceURL: URL,
            destinationFolderPath: String,
            isCollection: Bool,
            preexistingDestinationFiles: [String: RegularFileIdentity],
            createdAt: Date = .now
        ) {
            self.version = Self.currentVersion
            self.downloadID = downloadID
            self.attemptIdentifier = attemptIdentifier
            self.sourceURL = sourceURL
            self.destinationFolderPath = destinationFolderPath
            self.isCollection = isCollection
            self.preexistingDestinationFiles = preexistingDestinationFiles
            self.createdAt = createdAt
        }
    }

    private struct RunningDownload {
        let id: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let process: ManagedChildProcess
        let processOwnership: MediaProcessOwnershipManifest
        let destinationFolder: URL
        let temporaryFolder: URL
        let preexistingDestinationFiles: [String: RegularFileIdentity]
        let metadata: MediaDownloadMetadata?
        var terminationReason: TerminationReason?
        var stdoutBuffer = ""
        var stderrBuffer = ""
        var expectedBytes: Int64
    }

    private struct StartingDownload {
        let attemptIdentifier: UUID
        let destinationPath: String
    }

    private struct ChildCompletionEvidence {
        let attempt: MediaAttemptManifest
        let reportedURLs: [URL]
    }

    nonisolated private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Harbor",
        category: "MediaEngine"
    )

    private let eventHandler: EventHandler
    private let fileManager: FileManager
    private let temporaryRoot: URL
    private var runtime: MediaRuntimeResolution?
    private var runningDownloads: [UUID: RunningDownload] = [:]
    private var startingDownloads: [UUID: StartingDownload] = [:]
    private var terminationWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]
    private var terminalOutcomes: [UUID: MediaTerminalOutcome] = [:]
    private static let completionManifestFilename = ".harbor-completion.json"
    private static let processOwnershipManifestFilename = ".harbor-process-owner.json"
    private static let attemptManifestFilename = ".harbor-attempt.json"
    private static let finalPathReceiptFilename = ".harbor-final-paths.jsonl"
    private static let processSucceededMarkerFilename = ".harbor-process-succeeded"
    private static let completionMonitorURL = URL(fileURLWithPath: "/bin/sh")
    nonisolated static let completionMonitorPublicationFailureExitCode: Int32 = 74

    init(
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default,
        temporaryRoot: URL? = nil
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.temporaryRoot = temporaryRoot ?? Self.defaultTemporaryRoot(fileManager: fileManager)
    }

    func metadata(for url: URL) async throws -> MediaDownloadMetadata {
        let runtime = try resolvedRuntime()
        let output = try await runMetadataCommand(runtime: runtime, url: url)
        let metadata = try MediaDownloadMetadataParser.metadata(from: output, sourceURL: url)

        guard metadata.supportsMediaDownload else {
            throw MediaDownloadError.unsupported(
                "yt-dlp couldn’t verify downloadable media for this link."
            )
        }

        return metadata
    }

    func startDownload(
        id: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference,
        customFilename: String? = nil,
        outputConflictIdentifier: UUID? = nil,
        speedLimitBytesPerSecond: Int64? = nil
    ) async throws -> Int32 {
        try Task.checkCancellation()
        if let existing = runningDownloads[id] {
            guard existing.attemptIdentifier == attemptIdentifier else {
                throw MediaDownloadError.unavailable(
                    "The previous media process is still stopping. Try again after it exits."
                )
            }
            return existing.process.processIdentifier
        }
        guard startingDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "The previous media start is still being prepared."
            )
        }
        if try completionEvidenceExists(id: id) {
            throw MediaDownloadError.unavailable(
                "A completed media result is still awaiting durable reconciliation."
            )
        }
        terminalOutcomes.removeValue(forKey: id)

        guard metadata?.supportsMediaDownload == true else {
            throw MediaDownloadError.unsupported(
                "yt-dlp couldn’t verify downloadable media for this download."
            )
        }

        let destinationPath = destinationFolder.standardizedFileURL
            .resolvingSymlinksInPath().path
        let hasCompetingDestination = runningDownloads.values.contains {
            $0.destinationFolder.standardizedFileURL
                .resolvingSymlinksInPath().path == destinationPath
        } || startingDownloads.values.contains {
            $0.destinationPath == destinationPath
        }
        startingDownloads[id] = StartingDownload(
            attemptIdentifier: attemptIdentifier,
            destinationPath: destinationPath
        )
        defer {
            if startingDownloads[id]?.attemptIdentifier == attemptIdentifier {
                startingDownloads.removeValue(forKey: id)
            }
        }
        let effectiveOutputIdentifier = Self.outputIdentifier(
            requested: outputConflictIdentifier,
            downloadID: id,
            hasCompetingDestination: hasCompetingDestination
        )

        let runtime = try resolvedRuntime()
        let temporaryFolder = temporaryFolder(for: id)
        try await cleanupOrphanedMediaProcessesIfNeeded()
        // A quit, pause, or removal can cancel the owning start task while
        // orphan reconciliation is suspended. Do not cross the non-idempotent
        // process-spawn boundary after that cancellation.
        try Task.checkCancellation()
        let processes = try runningProcesses()
        let trackedProcessGroups = Set(
            runningDownloads.values.map(\.processOwnership.processGroupIdentifier)
        )
        guard Self.hasUntrackedProcessReferencingRecoveryRoot(
            temporaryRoot,
            in: processes,
            trackedProcessGroups: trackedProcessGroups
        ) == false else {
            throw MediaDownloadError.unavailable(
                "A previous unverified media process may still be writing. Harbor left it untouched and did not start another download."
            )
        }
        guard Self.hasProcessReferencingRecoveryFolder(
            temporaryFolder,
            in: processes
        ) == false else {
            // A crash can occur after spawn but before the exact ownership
            // marker is durable. The UUID recovery path is still a reliable
            // per-item exclusion key, but it is not authority to signal an
            // unknown process. Preserve the existing writer and refuse to
            // create a second one.
            throw MediaDownloadError.unavailable(
                "A previous media process may still be using this download’s recovery data. Harbor left it untouched."
            )
        }
        guard try DurableFileSystem.itemExists(at: processOwnershipManifestURL(id: id)) == false else {
            throw MediaDownloadError.unavailable(
                "Harbor found an unverifiable owner for this download’s recovery data and left it untouched."
            )
        }
        // Orphan cleanup can promote a child-owned success receipt after the
        // first check above. Recheck at the spawn boundary so that recovery
        // and a replacement process can never win the same start attempt.
        guard try completionEvidenceExists(id: id) == false else {
            throw MediaDownloadError.unavailable(
                "A completed media result is still awaiting durable reconciliation."
            )
        }

        try createAndValidateTemporaryFolder(temporaryFolder)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)
        let preexistingDestinationFiles = try destinationFileIdentities(
            in: destinationFolder
        )
        try prepareCompletionAttempt(
            id: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolder: destinationFolder,
            isCollection: metadata?.isCollection == true,
            preexistingDestinationFiles: preexistingDestinationFiles
        )

        let arguments = try Self.downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            metadata: metadata,
            formatPreference: formatPreference,
            customFilename: customFilename,
            outputConflictIdentifier: effectiveOutputIdentifier,
            completionReceiptURL: finalPathReceiptURL(id: id),
            speedLimitBytesPerSecond: speedLimitBytesPerSecond
        )
        let processArguments = Self.completionMonitorArguments(
            mediaExecutableURL: runtime.ytDlpURL,
            successMarkerURL: processSucceededMarkerURL(id: id),
            attemptIdentifier: attemptIdentifier,
            mediaArguments: arguments
        )

        let environment = processEnvironment(runtime: runtime)
        let outputCapture = MediaProcessOutputCapture()
        let process = try ManagedChildProcess(
            executableURL: Self.completionMonitorURL,
            arguments: processArguments,
            environment: environment,
            onStdout: { [weak self] output in
                outputCapture.appendStdout(output)
                Task {
                    await self?.handleOutput(
                        output,
                        stream: .stdout,
                        for: id,
                        attemptIdentifier: attemptIdentifier
                    )
                }
            },
            onStderr: { [weak self] output in
                outputCapture.appendStderr(output)
                Task {
                    await self?.handleOutput(
                        output,
                        stream: .stderr,
                        for: id,
                        attemptIdentifier: attemptIdentifier
                    )
                }
            },
            onTermination: { [weak self] termination in
                let capturedOutput = outputCapture.snapshot()
                Task {
                    await self?.handleTermination(
                        termination,
                        for: id,
                        attemptIdentifier: attemptIdentifier,
                        capturedStdout: capturedOutput.stdout,
                        capturedStderr: capturedOutput.stderr
                    )
                }
            }
        )

        let processOwnership: MediaProcessOwnershipManifest
        do {
            processOwnership = try persistProcessOwnership(
                processIdentifier: process.processIdentifier,
                downloadID: id,
                attemptIdentifier: attemptIdentifier,
                executableURL: Self.completionMonitorURL,
                temporaryFolder: temporaryFolder
            )
        } catch {
            // A child without a durable identity must never be treated as a
            // recoverable background writer. Stop the still-owned direct child;
            // its callback cannot publish because no RunningDownload exists.
            process.terminate(grace: 0.2)
            throw MediaDownloadError.outputConflict(
                "Harbor could not durably record the media process owner after it started. "
                    + "The process was stopped and the next attempt will use a collision-safe filename. "
                    + error.localizedDescription
            )
        }

        let expectedBytes = formatPreference.initialExpectedBytes(
            metadataEstimate: metadata?.expectedBytes ?? 0
        )
        runningDownloads[id] = RunningDownload(
            id: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            process: process,
            processOwnership: processOwnership,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            preexistingDestinationFiles: preexistingDestinationFiles,
            metadata: metadata,
            expectedBytes: expectedBytes
        )

        logger.info("Started media download \(id.uuidString, privacy: .public) with pid \(process.processIdentifier, privacy: .public)")
        eventHandler(
            attemptIdentifier,
            .started(
                id: id,
                processIdentifier: process.processIdentifier,
                expectedBytes: expectedBytes,
                title: metadata?.title,
                platform: metadata?.platform
            )
        )
        return process.processIdentifier
    }

    @discardableResult
    func pause(id: UUID) -> Bool {
        guard var download = runningDownloads[id] else {
            return false
        }

        download.terminationReason = .pause
        runningDownloads[id] = download
        download.process.terminate()
        return true
    }

    @discardableResult
    func cancel(id: UUID) -> Bool {
        guard var download = runningDownloads[id] else {
            return false
        }

        download.terminationReason = .cancel
        runningDownloads[id] = download
        download.process.terminate()
        return true
    }

    func pauseAndWait(id: UUID) async {
        guard pause(id: id) else {
            return
        }

        await waitForTermination(id: id)
    }

    func discardRecoveryData(id: UUID) throws {
        guard runningDownloads[id] == nil,
              startingDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "Harbor couldn’t clear the previous media download while it was still running."
            )
        }

        // After relaunch, an owned child is no longer represented by
        // `runningDownloads`. Its durable marker is the only evidence that a
        // writer may still exist, so explicit cleanup must fail closed until
        // orphan reconciliation verifies the process has stopped and retires
        // that marker.
        guard try DurableFileSystem.itemExists(at: processOwnershipManifestURL(id: id)) == false else {
            throw MediaDownloadError.unavailable(
                "Harbor couldn’t clear this media download while a previous process may still own its recovery data."
            )
        }

        terminalOutcomes.removeValue(forKey: id)
        let folder = temporaryFolder(for: id)
        guard try DurableFileSystem.itemExists(at: folder) else {
            return
        }
        try validateTemporaryFolder(folder)
        try fileManager.removeItem(at: folder)
        try DurableFileSystem.synchronizeParentDirectory(of: folder)
    }

    func discardOrphanedRecoveryData(retaining retainedIDs: Set<UUID>) throws {
        guard try DurableFileSystem.itemExists(at: temporaryRoot) else {
            return
        }
        try validateTemporaryRoot()
        let entries = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        // Process discovery is part of the deletion precondition. If it is
        // unavailable, preserve every recovery directory rather than treating
        // an empty process list as proof that no writer still owns one.
        let runningProcessCommands = try runningProcesses().map(\.command)
        for entry in entries {
            guard let id = UUID(uuidString: entry.lastPathComponent) else {
                continue
            }
            let values = try entry.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            )
            guard values.isDirectory == true,
                  values.isSymbolicLink != true,
                  retainedIDs.contains(id) == false,
                  try DurableFileSystem.itemExists(at: processOwnershipManifestURL(id: id)) == false,
                  runningProcessCommands.contains(where: { $0.contains(entry.path) }) == false,
                  runningDownloads[id] == nil else {
                continue
            }

            try fileManager.removeItem(at: entry)
            try DurableFileSystem.synchronizeParentDirectory(of: entry)
        }
    }

    func recoverableByteCount(id: UUID) -> Int64? {
        let folder = temporaryFolder(for: id)
        guard (try? validateTemporaryFolder(folder)) != nil,
              let enumerator = fileManager.enumerator(
                  at: folder,
                  includingPropertiesForKeys: [
                      .fileSizeKey,
                      .isRegularFileKey,
                      .isSymbolicLinkKey
                  ],
                  options: [.skipsHiddenFiles]
              ) else {
            return nil
        }

        var total: Int64 = 0
        var foundPayload = false
        for case let url as URL in enumerator {
            guard url.pathExtension.lowercased() != "ytdl",
                  let values = try? url.resourceValues(
                      forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                  ),
                  values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let size = values.fileSize,
                  size >= 0 else {
                continue
            }
            foundPayload = true
            total += Int64(size)
        }
        return foundPayload ? total : nil
    }

    func terminateOrphanedMediaProcesses() async throws {
        try await cleanupOrphanedMediaProcessesIfNeeded()
    }

    func cancelAndWait(id: UUID) async {
        guard cancel(id: id) else {
            return
        }

        await waitForTermination(id: id)
    }

    func cancelAndDiscardRecoveryData(id: UUID) async throws {
        await cancelAndWait(id: id)
        try discardRecoveryData(id: id)
    }

    func terminalOutcome(id: UUID) -> MediaTerminalOutcome? {
        terminalOutcomes[id]
    }

    func completedDownloadEntries() throws -> [MediaCompletionEntry] {
        guard try DurableFileSystem.itemExists(at: temporaryRoot) else {
            return []
        }
        try validateTemporaryRoot()
        let folders = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )

        var entries: [MediaCompletionEntry] = []
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent) else {
                continue
            }
            let hasCompletionEvidence: Bool
            do {
                hasCompletionEvidence = try completionEvidenceExists(id: id)
            } catch {
                entries.append(
                    .unavailable(downloadID: id, message: error.localizedDescription)
                )
                continue
            }
            guard hasCompletionEvidence else {
                continue
            }

            do {
                guard let manifest = try materializeChildCompletionManifestIfNeeded(id: id) else {
                    continue
                }
                entries.append(.valid(manifest))
            } catch let error as CompletionManifestIntegrityError {
                entries.append(
                    .invalid(downloadID: id, message: error.localizedDescription)
                )
            } catch {
                entries.append(
                    .unavailable(downloadID: id, message: error.localizedDescription)
                )
            }
        }
        return entries
    }

    func completedDownloadEntry(id: UUID) throws -> MediaCompletionEntry? {
        do {
            guard try completionEvidenceExists(id: id) else {
                return nil
            }
        } catch {
            return .unavailable(downloadID: id, message: error.localizedDescription)
        }

        do {
            guard let manifest = try materializeChildCompletionManifestIfNeeded(id: id) else {
                return nil
            }
            return .valid(manifest)
        } catch let error as CompletionManifestIntegrityError {
            return .invalid(downloadID: id, message: error.localizedDescription)
        } catch {
            return .unavailable(downloadID: id, message: error.localizedDescription)
        }
    }

    func acknowledgeCompletion(id: UUID, attemptIdentifier: UUID) throws {
        guard runningDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "The media process is still active while Harbor is acknowledging completion."
            )
        }

        let manifestURL = completionManifestURL(id: id)
        if try DurableFileSystem.itemExists(at: manifestURL) {
            let manifest = try validatedCompletionManifest(id: id)
            guard manifest.attemptIdentifier == attemptIdentifier else {
                throw MediaDownloadError.unavailable(
                    "A newer media completion owns this recovery directory."
                )
            }
        } else if let outcome = terminalOutcomes[id],
                  outcome.attemptIdentifier != attemptIdentifier {
            throw MediaDownloadError.unavailable(
                "A newer media attempt owns this recovery directory."
            )
        }

        terminalOutcomes.removeValue(forKey: id)
        let folder = temporaryFolder(for: id)
        if try DurableFileSystem.itemExists(at: folder) {
            try validateTemporaryFolder(folder)
            try fileManager.removeItem(at: folder)
            try DurableFileSystem.synchronizeParentDirectory(of: folder)
        }
    }

    func discardCompletionMarker(id: UUID) throws {
        guard runningDownloads[id] == nil,
              startingDownloads[id] == nil else {
            throw MediaDownloadError.unavailable(
                "Harbor could not reset media completion evidence while its process was active."
            )
        }
        let folder = temporaryFolder(for: id)
        guard try DurableFileSystem.itemExists(at: folder) else {
            return
        }
        try validateTemporaryFolder(folder)
        guard try DurableFileSystem.itemExists(at: processOwnershipManifestURL(id: id)) == false else {
            throw MediaDownloadError.unavailable(
                "Harbor could not reset media completion evidence while an earlier process owner remained."
            )
        }
        for url in [
            completionManifestURL(id: id),
            processSucceededMarkerURL(id: id),
            processSucceededTemporaryMarkerURL(id: id),
            finalPathReceiptURL(id: id),
            attemptManifestURL(id: id)
        ] {
            try removeOwnedCompletionEvidenceFileIfPresent(url, in: folder)
        }
        try DurableFileSystem.synchronizeDirectory(at: folder)
    }

    private func waitForTermination(id: UUID) async {
        await withCheckedContinuation { continuation in
            guard runningDownloads[id] != nil else {
                continuation.resume()
                return
            }

            terminationWaiters[id, default: []].append(continuation)
        }
    }

    func shutdown() async {
        let downloads = Array(runningDownloads.values)
        for download in downloads {
            var updatedDownload = download
            if updatedDownload.terminationReason == nil {
                updatedDownload.terminationReason = .pause
            }
            runningDownloads[download.id] = updatedDownload
            download.process.terminate(grace: 0.6)
        }

        for download in downloads {
            await waitForTermination(id: download.id)
        }
    }

    private enum OutputStream {
        case stdout
        case stderr
    }

    private func handleOutput(
        _ output: String,
        stream: OutputStream,
        for id: UUID,
        attemptIdentifier: UUID
    ) {
        guard var download = runningDownloads[id],
              download.attemptIdentifier == attemptIdentifier else {
            return
        }

        switch stream {
        case .stdout:
            download.stdoutBuffer += output
            let lines = completeLines(from: &download.stdoutBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id, attemptIdentifier: attemptIdentifier)
        case .stderr:
            download.stderrBuffer += output
            let lines = completeLines(from: &download.stderrBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id, attemptIdentifier: attemptIdentifier)
        }
    }

    private func process(
        lines: [String],
        for id: UUID,
        attemptIdentifier: UUID
    ) {
        for line in lines {
            if let progress = MediaDownloadProgressParser.progress(from: line) {
                apply(
                    progress: progress,
                    to: id,
                    attemptIdentifier: attemptIdentifier
                )
                continue
            }

            // Final paths are consumed from the child-owned receipt only after
            // the completion monitor exits. Progress output remains actor-fed.
        }
    }

    private func apply(
        progress: MediaDownloadProgress,
        to id: UUID,
        attemptIdentifier: UUID
    ) {
        guard var download = runningDownloads[id],
              download.attemptIdentifier == attemptIdentifier else {
            return
        }

        let expectedBytes = max(progress.expectedBytes, download.expectedBytes)
        download.expectedBytes = expectedBytes
        runningDownloads[id] = download

        eventHandler(
            download.attemptIdentifier,
            .progress(
                id: id,
                bytesWritten: progress.bytesWritten,
                expectedBytes: expectedBytes,
                speedBytesPerSecond: progress.speedBytesPerSecond
            )
        )
    }

    private func handleTermination(
        _ termination: ManagedChildProcessTermination,
        for id: UUID,
        attemptIdentifier: UUID,
        capturedStdout _: String,
        capturedStderr: String
    ) {
        guard let current = runningDownloads[id],
              current.attemptIdentifier == attemptIdentifier else {
            return
        }
        let download = current
        runningDownloads.removeValue(forKey: id)

        let waiters = terminationWaiters.removeValue(forKey: id) ?? []
        defer {
            waiters.forEach { $0.resume() }
        }
        defer {
            do {
                // Keep the writer-exclusion marker until this callback has
                // either published a parent manifest or left child-owned
                // terminal evidence for relaunch reconciliation.
                try discardProcessOwnershipManifest(download.processOwnership)
            } catch {
                // The child has already been reaped. A stale exact-identity
                // marker is harmless and will be retired by the next scan.
                logger.warning(
                    "Could not retire media process ownership for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        logger.info("Media download \(id.uuidString, privacy: .public) exited with status \(termination.waitStatus, privacy: .public)")

        var successfulCompletionError: Error?
        let childSuccessMarkerExists: Bool
        do {
            childSuccessMarkerExists = try DurableFileSystem.itemExists(
                at: processSucceededMarkerURL(id: id)
            )
        } catch {
            childSuccessMarkerExists = false
            successfulCompletionError = error
        }
        if termination.isSuccess || childSuccessMarkerExists {
            do {
                let event = try successfulCompletionEvent(
                    for: download
                )
                // Completion is not publishable until its payload manifest is
                // durable. A visible destination file alone cannot survive a
                // crash between this callback and record persistence.
                do {
                    try persistCompletionManifest(event, for: download)
                } catch {
                    // The process already produced and validated its terminal
                    // output. A simultaneous Pause or Cancel cannot turn that
                    // completed representation back into resumable partial
                    // state merely because journaling failed late.
                    emitTerminal(
                        .failed(
                            id: id,
                            message: error.localizedDescription,
                            disposition: .outputConflict
                        ),
                        for: download
                    )
                    return
                }
                emitTerminal(event, for: download)
                return
            } catch {
                successfulCompletionError = error
            }
        }

        if childSuccessMarkerExists || successfulCompletionError != nil {
            // The child claimed a complete result, or Harbor could not safely
            // determine whether it did. Preserve every receipt and destination
            // byte instead of allowing a simultaneous Cancel to erase the only
            // recovery evidence.
            emitTerminal(
                .failed(
                    id: id,
                    message: successfulCompletionError?.localizedDescription
                        ?? "Harbor could not verify the child-owned media completion receipt.",
                    disposition: .outputConflict
                ),
                for: download
            )
            return
        }

        if termination.exitCode == Self.completionMonitorPublicationFailureExitCode {
            emitTerminal(
                .failed(
                    id: id,
                    message: "yt-dlp finished, but Harbor could not publish its durable completion receipt.",
                    disposition: .outputConflict
                ),
                for: download
            )
            return
        }

        // A process that reached a validated successful output wins a
        // simultaneous Pause/Cancel request above. If it did not publish a
        // complete output, preserve the user's termination intent here.
        switch download.terminationReason {
        case .pause:
            emitTerminal(.paused(id: id), for: download)
            return
        case .cancel:
            cleanupTemporaryFolder(download.temporaryFolder)
            emitTerminal(.cancelled(id: id), for: download)
            return
        case nil:
            break
        }

        if termination.isSuccess == false {
            emitTerminal(
                .failed(
                    id: id,
                    message: MediaDownloadErrorClassifier.message(from: capturedStderr),
                    disposition: .ordinary
                ),
                for: download
            )
            return
        }

        // A clean process exit may already have placed destination bytes even
        // when path parsing, validation, hashing, or journal publication fails.
        // The next attempt must therefore use a collision-safe output name;
        // retrying the original --no-overwrites path can only rediscover stale
        // bytes and require a second user-visible retry.
        emitTerminal(
            .failed(
                id: id,
                message: successfulCompletionError?.localizedDescription
                    ?? "yt-dlp finished without reporting a completed file.",
                disposition: .outputConflict
            ),
            for: download
        )
    }

    private func successfulCompletionEvent(
        for download: RunningDownload
    ) throws -> MediaDownloadEvent {
        let evidence = try validatedChildCompletionEvidence(id: download.id)
        guard evidence.attempt.attemptIdentifier == download.attemptIdentifier,
              evidence.attempt.sourceURL == download.sourceURL,
              evidence.attempt.destinationFolderPath
                == download.destinationFolder.standardizedFileURL.path,
              evidence.attempt.isCollection == (download.metadata?.isCollection == true) else {
            throw CompletionManifestIntegrityError.invalid(
                "The child-owned media completion receipt does not match the active attempt."
            )
        }
        let reportedURLs = evidence.reportedURLs

        let fileURL: URL
        let payloadURLs: [URL]
        let actualBytes: Int64
        if download.metadata?.isCollection == true {
            fileURL = download.destinationFolder
            let validatedFiles = try reportedURLs.map {
                try validatedFinalFile(
                    $0,
                    destinationFolder: download.destinationFolder
                )
            }
            guard validatedFiles.isEmpty == false else {
                throw MediaDownloadError.processFailed(
                    "yt-dlp finished without reporting any completed files."
                )
            }
            try validatedFiles.forEach {
                try requireAttemptProduced($0.url, for: download)
            }
            let uniqueFiles = Dictionary(
                validatedFiles.map { ($0.url.standardizedFileURL.path, $0.byteCount) },
                uniquingKeysWith: { _, latest in latest }
            )
            payloadURLs = uniqueFiles.keys
                .sorted()
                .map { URL(fileURLWithPath: $0) }
            actualBytes = uniqueFiles.values.reduce(0) { partial, bytes in
                let (sum, overflow) = partial.addingReportingOverflow(bytes)
                return overflow ? Int64.max : sum
            }
        } else {
            guard let reportedURL = reportedURLs.last else {
                throw MediaDownloadError.processFailed(
                    "yt-dlp finished without reporting the completed file path."
                )
            }

            let validatedFile = try validatedFinalFile(
                reportedURL,
                destinationFolder: download.destinationFolder
            )
            try requireAttemptProduced(validatedFile.url, for: download)
            fileURL = validatedFile.url
            payloadURLs = [validatedFile.url]
            actualBytes = validatedFile.byteCount
        }

        return .finished(
            id: download.id,
            fileURL: fileURL,
            payloadURLs: payloadURLs,
            expectedBytes: actualBytes
        )
    }

    private func emitTerminal(
        _ event: MediaDownloadEvent,
        for download: RunningDownload
    ) {
        terminalOutcomes[download.id] = MediaTerminalOutcome(
            attemptIdentifier: download.attemptIdentifier,
            event: event
        )
        eventHandler(download.attemptIdentifier, event)
    }

    private func resolvedRuntime() throws -> MediaRuntimeResolution {
        if let runtime {
            return runtime
        }

        guard let runtime = MediaRuntimeResolver.resolveRuntime() else {
            throw MediaDownloadError.runtimeNotFound
        }

        self.runtime = runtime
        return runtime
    }

    private func runMetadataCommand(
        runtime: MediaRuntimeResolution,
        url: URL
    ) async throws -> Data {
        let arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--no-warnings",
            "--js-runtimes",
            "deno:\(runtime.denoURL.path)",
            "--socket-timeout",
            "15",
            "--retries",
            "3",
            "--extractor-retries",
            "3",
            "--retry-sleep",
            "http:linear=2:10:4",
            "--retry-sleep",
            "extractor:linear=2:10:4",
            "--dump-single-json",
            "--flat-playlist",
            "--simulate",
            "--check-all-formats",
            "--ffmpeg-location",
            runtime.ffmpegURL.deletingLastPathComponent().path,
            url.absoluteString
        ]

        let state = MetadataCommandState()

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                do {
                    let process = try ManagedChildProcess(
                        executableURL: runtime.ytDlpURL,
                        arguments: arguments,
                        environment: processEnvironment(runtime: runtime),
                        maximumBufferedLineBytes: MetadataCommandState.maximumCapturedBytes,
                        onOutputLimitExceeded: {
                            state.markOutputLimitExceeded()
                        },
                        onStdout: { output in
                            if state.appendStdout(output) == false {
                                state.process?.terminate(grace: 0.2)
                            }
                        },
                        onStderr: { output in
                            if state.appendStderr(output) == false {
                                state.process?.terminate(grace: 0.2)
                            }
                        },
                        onTermination: { termination in
                            guard let result = state.finish(termination: termination) else {
                                return
                            }

                            switch result {
                            case let .success(output):
                                continuation.resume(returning: output)
                            case let .failure(error):
                                continuation.resume(throwing: error)
                            }
                        }
                    )

                    state.process = process
                    if Task.isCancelled || state.shouldTerminateProcess {
                        process.terminate(grace: 0.2)
                    }

                    Task {
                        try? await Task.sleep(for: .seconds(120))
                        guard state.markTimedOut() else {
                            return
                        }

                        process.terminate(grace: 0.5)
                        continuation.resume(
                            throwing: MediaDownloadError.unavailable(
                                "Timed out while checking this media link."
                            )
                        )
                    }
                } catch {
                    continuation.resume(throwing: MediaDownloadError.processFailed(error.localizedDescription))
                }
            }
        } onCancel: {
            state.process?.terminate(grace: 0.2)
        }
    }

    nonisolated static func downloadArguments(
        runtime: MediaRuntimeResolution,
        sourceURL: URL,
        destinationFolder: URL,
        temporaryFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference,
        customFilename: String? = nil,
        outputConflictIdentifier: UUID? = nil,
        completionReceiptURL: URL,
        speedLimitBytesPerSecond: Int64?
    ) throws -> [String] {
        var outputStem = "%(title).180B [%(id)s]"
        if let customFilename,
           !customFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            outputStem = DownloadDestinationResolver().sanitize(customFilename).replacingOccurrences(of: "%", with: "%%")
            if metadata?.isCollection == true {
                outputStem += " [%(id)s]"
            }
        }
        if let outputConflictIdentifier {
            outputStem += " [Harbor \(outputConflictIdentifier.uuidString)]"
        }
        let outputTemplate = outputStem + ".%(ext)s"
        var arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--js-runtimes",
            "deno:\(runtime.denoURL.path)",
            "--newline",
            "--progress",
            "--continue",
            "--no-overwrites",
            "--socket-timeout",
            "15",
            "--retries",
            "10",
            "--fragment-retries",
            "10",
            "--file-access-retries",
            "3",
            "--extractor-retries",
            "3",
            "--retry-sleep",
            "http:exp=2:60",
            "--retry-sleep",
            "fragment:exp=2:60",
            "--retry-sleep",
            "file_access:exp=2:60",
            "--retry-sleep",
            "extractor:exp=2:60",
            "--paths",
            "home:\(destinationFolder.path)",
            "--paths",
            "temp:\(temporaryFolder.path)",
            "--output",
            outputTemplate,
            "--print-to-file",
            "after_move:harbor-file:%(filepath)j",
            outputTemplatePath(for: completionReceiptURL),
            "--progress-template",
            "download:harbor-progress:%(progress.downloaded_bytes|0)s\t%(progress.total_bytes,progress.total_bytes_estimate|0)s\t%(progress.speed|0)s",
            "--ffmpeg-location",
            runtime.ffmpegURL.deletingLastPathComponent().path
        ]

        if metadata?.isCollection != true {
            arguments.append("--no-playlist")
        }

        if let speedLimitBytesPerSecond, speedLimitBytesPerSecond > 0 {
            arguments.append(contentsOf: [
                "--limit-rate",
                "\(speedLimitBytesPerSecond)"
            ])
        }

        if case let .specific(selection) = formatPreference {
            arguments.append(contentsOf: [
                "--format",
                selection.selector
            ])

            if let mergeOutputFormat = selection.mergeOutputFormat {
                arguments.append(contentsOf: [
                    "--merge-output-format",
                    mergeOutputFormat
                ])
            }
        }

        arguments.append(sourceURL.absoluteString)
        return arguments
    }

    nonisolated static func completionMonitorArguments(
        mediaExecutableURL: URL,
        successMarkerURL: URL,
        attemptIdentifier: UUID,
        mediaArguments: [String]
    ) -> [String] {
        let publicationFailureExitCode = completionMonitorPublicationFailureExitCode
        let script = #"""
        media_executable=$1
        success_marker=$2
        attempt_identifier=$3
        shift 3

        # Harbor signals the entire private process group on Pause/Cancel. Keep
        # this monitor alive long enough to observe the child's real status and
        # publish success once yt-dlp has returned zero. The subshell resets
        # signal handling before exec so yt-dlp and its descendants still stop.
        trap '' HUP INT TERM
        (
            trap - HUP INT TERM
            exec "$media_executable" "$@"
        )
        status=$?
        if [ "$status" -ne 0 ]; then
            # Harbor classifies failures from stderr, not the executable's
            # numeric status. Collapse child failures so the reserved receipt
            # publication status below cannot collide with a yt-dlp exit code.
            exit 1
        fi

        temporary_marker="${success_marker}.tmp"
        umask 077
        if ! (set -C; printf '%s\n' "$attempt_identifier" > "$temporary_marker"); then
            exit \#(publicationFailureExitCode)
        fi
        if ! /bin/mv -f "$temporary_marker" "$success_marker"; then
            /bin/rm -f "$temporary_marker"
            exit \#(publicationFailureExitCode)
        fi
        exit 0
        """#
        return [
            "-c",
            script,
            "harbor-media-completion-monitor",
            mediaExecutableURL.path,
            successMarkerURL.path,
            attemptIdentifier.uuidString
        ] + mediaArguments
    }

    nonisolated private static func outputTemplatePath(for url: URL) -> String {
        url.path.replacingOccurrences(of: "%", with: "%%")
    }

    nonisolated static func outputIdentifier(
        requested: UUID?,
        downloadID: UUID,
        hasCompetingDestination: Bool
    ) -> UUID? {
        requested ?? (hasCompetingDestination ? downloadID : nil)
    }

    private func processEnvironment(runtime: MediaRuntimeResolution) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let runtimeBinPath = runtime.ytDlpURL.deletingLastPathComponent().path
        let path = environment["PATH"].map { "\(runtimeBinPath):\($0)" } ?? runtimeBinPath
        environment["PATH"] = path
        environment["PYTHONNOUSERSITE"] = "1"
        return environment
    }

    private func completeLines(from buffer: inout String) -> [String] {
        let parts = buffer.components(separatedBy: .newlines)
        guard parts.count > 1 else {
            return []
        }

        buffer = parts.last ?? ""
        return parts.dropLast().map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func temporaryFolder(for id: UUID) -> URL {
        temporaryRoot.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    private func attemptManifestURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.attemptManifestFilename)
    }

    private func finalPathReceiptURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.finalPathReceiptFilename)
    }

    private func processSucceededMarkerURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.processSucceededMarkerFilename)
    }

    private func processSucceededTemporaryMarkerURL(id: UUID) -> URL {
        URL(fileURLWithPath: processSucceededMarkerURL(id: id).path + ".tmp")
    }

    private func completionManifestURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.completionManifestFilename)
    }

    private func completionManifestExists(id: UUID) throws -> Bool {
        try DurableFileSystem.itemExists(at: completionManifestURL(id: id))
    }

    private func completionEvidenceExists(id: UUID) throws -> Bool {
        try completionManifestExists(id: id)
            || DurableFileSystem.itemExists(at: processSucceededMarkerURL(id: id))
    }

    private func prepareCompletionAttempt(
        id: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        isCollection: Bool,
        preexistingDestinationFiles: [String: RegularFileIdentity]
    ) throws {
        let folder = temporaryFolder(for: id)
        try validateTemporaryFolder(folder)
        for url in [
            finalPathReceiptURL(id: id),
            attemptManifestURL(id: id),
            processSucceededTemporaryMarkerURL(id: id)
        ] {
            try removeOwnedCompletionEvidenceFileIfPresent(url, in: folder)
        }
        try DurableFileSystem.synchronizeDirectory(at: folder)

        let manifest = MediaAttemptManifest(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolderPath: destinationFolder.standardizedFileURL.path,
            isCollection: isCollection,
            preexistingDestinationFiles: preexistingDestinationFiles
        )
        let url = attemptManifestURL(id: id)
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: url)
        try DurableFileSystem.synchronizeDirectory(at: folder)
        try DurableFileSystem.synchronizeParentDirectory(of: folder)
    }

    private func removeOwnedCompletionEvidenceFileIfPresent(
        _ url: URL,
        in folder: URL
    ) throws {
        guard try DurableFileSystem.itemExists(at: url) else {
            return
        }
        try validateTemporaryFolder(folder)
        let values = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw MediaDownloadError.unavailable(
                "Harbor found unsafe media completion evidence and left it untouched."
            )
        }
        try fileManager.removeItem(at: url)
    }

    private func persistCompletionManifest(
        _ event: MediaDownloadEvent,
        for download: RunningDownload
    ) throws {
        guard case let .finished(id, fileURL, payloadURLs, expectedBytes) = event,
              id == download.id,
              payloadURLs.isEmpty == false else {
            throw CompletionManifestIntegrityError.invalid(
                "The media completion event did not contain validated payloads."
            )
        }

        let manifest = try makeCompletionManifest(
            downloadID: download.id,
            attemptIdentifier: download.attemptIdentifier,
            sourceURL: download.sourceURL,
            destinationFolder: download.destinationFolder,
            fileLocationURL: fileURL,
            payloadURLs: payloadURLs
        )
        guard manifest.actualBytes == expectedBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media payload size did not match its terminal event."
            )
        }
        try persistCompletionManifest(manifest, id: download.id)
    }

    private func makeCompletionManifest(
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        fileLocationURL: URL,
        payloadURLs: [URL]
    ) throws -> MediaCompletionManifest {
        var payloads: [MediaCompletedFileManifest] = []
        var seenPaths = Set<String>()
        var totalBytes: Int64 = 0
        for payloadURL in payloadURLs {
            let validated = try validatedFinalFile(
                payloadURL,
                destinationFolder: destinationFolder
            )
            let path = validated.url.standardizedFileURL.path
            guard seenPaths.insert(path).inserted else {
                continue
            }
            try DurableFileSystem.synchronizeFile(at: validated.url)
            try DurableFileSystem.synchronizeParentDirectory(of: validated.url)
            let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(
                validated.byteCount
            )
            guard overflow == false else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media byte count overflowed."
                )
            }
            totalBytes = updatedTotal
            payloads.append(
                MediaCompletedFileManifest(
                    path: path,
                    byteCount: validated.byteCount,
                    sha256: try verifiedSHA256(
                        at: validated.url,
                        expectedBytes: validated.byteCount
                    )
                )
            )
        }
        guard payloads.isEmpty == false else {
            throw CompletionManifestIntegrityError.invalid(
                "The media completion evidence did not contain validated payloads."
            )
        }

        return MediaCompletionManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            destinationFolderPath: destinationFolder.standardizedFileURL.path,
            fileLocationPath: fileLocationURL.standardizedFileURL.path,
            payloads: payloads,
            actualBytes: totalBytes
        )
    }

    private func persistCompletionManifest(
        _ manifest: MediaCompletionManifest,
        id: UUID
    ) throws {
        let folder = temporaryFolder(for: id)
        try createAndValidateTemporaryFolder(folder)
        let manifestURL = completionManifestURL(id: id)
        try DurableFileSystem.writeAtomicallyWithoutReplacing(
            JSONEncoder().encode(manifest),
            to: manifestURL
        )
        try DurableFileSystem.synchronizeParentDirectory(of: folder)
    }

    private func materializeChildCompletionManifestIfNeeded(
        id: UUID
    ) throws -> MediaCompletionManifest? {
        if try completionManifestExists(id: id) {
            return try validatedCompletionManifest(id: id)
        }
        guard try DurableFileSystem.itemExists(at: processSucceededMarkerURL(id: id)) else {
            return nil
        }

        let evidence = try validatedChildCompletionEvidence(id: id)
        let destinationFolder = URL(
            fileURLWithPath: evidence.attempt.destinationFolderPath,
            isDirectory: true
        ).standardizedFileURL
        let payloadURLs: [URL]
        let fileLocationURL: URL
        if evidence.attempt.isCollection {
            payloadURLs = evidence.reportedURLs
            fileLocationURL = destinationFolder
        } else {
            guard let finalURL = evidence.reportedURLs.last else {
                throw CompletionManifestIntegrityError.invalid(
                    "The child-owned media completion receipt did not contain a final path."
                )
            }
            payloadURLs = [finalURL]
            fileLocationURL = finalURL
        }
        let manifest: MediaCompletionManifest
        do {
            try payloadURLs.forEach {
                try requireAttemptProduced(
                    $0,
                    preexistingDestinationFiles: evidence.attempt.preexistingDestinationFiles
                )
            }
            manifest = try makeCompletionManifest(
                downloadID: id,
                attemptIdentifier: evidence.attempt.attemptIdentifier,
                sourceURL: evidence.attempt.sourceURL,
                destinationFolder: destinationFolder,
                fileLocationURL: fileLocationURL,
                payloadURLs: payloadURLs
            )
        } catch let error as MediaDownloadError {
            throw CompletionManifestIntegrityError.invalid(
                error.localizedDescription
            )
        }
        try persistCompletionManifest(manifest, id: id)
        return try validatedCompletionManifest(id: id)
    }

    private func validatedChildCompletionEvidence(
        id: UUID
    ) throws -> ChildCompletionEvidence {
        let folder = temporaryFolder(for: id)
        try validateTemporaryFolder(folder)

        let attemptData = try validatedCompletionEvidenceData(
            at: attemptManifestURL(id: id),
            missingMessage: "The media attempt journal is missing."
        )
        let attempt: MediaAttemptManifest
        do {
            attempt = try JSONDecoder().decode(MediaAttemptManifest.self, from: attemptData)
        } catch let error as DecodingError {
            throw CompletionManifestIntegrityError.invalid(error.localizedDescription)
        }
        guard attempt.version == MediaAttemptManifest.currentVersion,
              attempt.downloadID == id,
              attempt.destinationFolderPath.hasPrefix("/") else {
            throw CompletionManifestIntegrityError.invalid(
                "The media attempt journal contains invalid ownership metadata."
            )
        }
        let destinationFolder = URL(
            fileURLWithPath: attempt.destinationFolderPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        guard attempt.preexistingDestinationFiles.allSatisfy({ path, identity in
            let fileURL = URL(fileURLWithPath: path)
                .standardizedFileURL.resolvingSymlinksInPath()
            return path.hasPrefix("/")
                && fileURL.deletingLastPathComponent() == destinationFolder
                && identity.size >= 0
                && identity.modificationNanoseconds >= 0
                && identity.modificationNanoseconds < 1_000_000_000
                && identity.statusChangeNanoseconds >= 0
                && identity.statusChangeNanoseconds < 1_000_000_000
        }) else {
            throw CompletionManifestIntegrityError.invalid(
                "The media attempt journal contains invalid destination identities."
            )
        }

        let successData = try validatedCompletionEvidenceData(
            at: processSucceededMarkerURL(id: id),
            missingMessage: "The child-owned media success marker is missing."
        )
        guard let successText = String(data: successData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            let succeededAttemptIdentifier = UUID(uuidString: successText),
            succeededAttemptIdentifier == attempt.attemptIdentifier else {
            throw CompletionManifestIntegrityError.invalid(
                "The child-owned media success marker does not match its attempt journal."
            )
        }

        let pathData = try validatedCompletionEvidenceData(
            at: finalPathReceiptURL(id: id),
            missingMessage: "The child-owned media final-path receipt is missing."
        )
        guard let pathText = String(data: pathData, encoding: .utf8) else {
            throw CompletionManifestIntegrityError.invalid(
                "The child-owned media final-path receipt is not valid UTF-8."
            )
        }
        let pathLines = pathText.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false }
        guard pathLines.isEmpty == false else {
            throw CompletionManifestIntegrityError.invalid(
                "The child-owned media final-path receipt is empty."
            )
        }
        let reportedURLs = try pathLines.map { line in
            guard let url = MediaDownloadFinalPathParser.fileURL(from: line) else {
                throw CompletionManifestIntegrityError.invalid(
                    "The child-owned media final-path receipt is malformed."
                )
            }
            return url
        }
        return ChildCompletionEvidence(attempt: attempt, reportedURLs: reportedURLs)
    }

    private func validatedCompletionEvidenceData(
        at url: URL,
        missingMessage: String
    ) throws -> Data {
        guard try DurableFileSystem.itemExists(at: url) else {
            throw CompletionManifestIntegrityError.invalid(missingMessage)
        }
        let identity = try regularFileIdentity(at: url)
        try DurableFileSystem.synchronizeFile(at: url)
        let data = try Data(contentsOf: url)
        guard try regularFileIdentity(at: url) == identity else {
            throw CompletionManifestIntegrityError.invalid(
                "The media completion evidence changed while it was being verified."
            )
        }
        return data
    }

    private func recoverChildCompletionBeforeRetiringOwnership(id: UUID) {
        do {
            _ = try materializeChildCompletionManifestIfNeeded(id: id)
        } catch {
            logger.warning(
                "Could not promote child-owned media completion for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func validatedCompletionManifest(id: UUID) throws -> MediaCompletionManifest {
        try validateTemporaryFolder(temporaryFolder(for: id))
        let manifestURL = completionManifestURL(id: id)
        let manifestIdentity = try regularFileIdentity(at: manifestURL)
        let values = try manifestURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal is not a regular file."
            )
        }

        let manifest: MediaCompletionManifest
        do {
            manifest = try JSONDecoder().decode(
                MediaCompletionManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch let error as DecodingError {
            throw CompletionManifestIntegrityError.invalid(error.localizedDescription)
        }
        guard manifest.version == MediaCompletionManifest.currentVersion,
              manifest.downloadID == id,
              manifest.payloads.isEmpty == false,
              manifest.actualBytes >= 0 else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal contains invalid ownership metadata."
            )
        }

        let destinationFolder = URL(
            fileURLWithPath: manifest.destinationFolderPath,
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath()
        let destinationPrefix = destinationFolder.path.hasSuffix("/")
            ? destinationFolder.path
            : destinationFolder.path + "/"
        var seenPaths = Set<String>()
        var totalBytes: Int64 = 0
        for payload in manifest.payloads {
            guard payload.byteCount >= 0,
                  payload.sha256.count == SHA256.byteCount * 2 else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media journal contains invalid payload metadata."
                )
            }
            let storedURL = URL(fileURLWithPath: payload.path).standardizedFileURL
            let storedValues: URLResourceValues
            do {
                storedValues = try storedURL.resourceValues(
                    forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
                )
            } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload is missing."
                )
            }
            guard storedValues.isRegularFile == true,
                  storedValues.isSymbolicLink != true,
                  Int64(storedValues.fileSize ?? -1) == payload.byteCount else {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload no longer matches its journal."
                )
            }
            let candidate = storedURL.resolvingSymlinksInPath()
            guard candidate.path.hasPrefix(destinationPrefix),
                  seenPaths.insert(candidate.path).inserted,
                  try verifiedSHA256(
                    at: candidate,
                    expectedBytes: payload.byteCount
                  ) == payload.sha256 else {
                throw CompletionManifestIntegrityError.invalid(
                    "A completed media payload no longer matches its journal."
                )
            }
            let (updatedTotal, overflow) = totalBytes.addingReportingOverflow(
                payload.byteCount
            )
            guard overflow == false else {
                throw CompletionManifestIntegrityError.invalid(
                    "The completed media byte count overflowed."
                )
            }
            totalBytes = updatedTotal
        }
        guard totalBytes == manifest.actualBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media byte count no longer matches its journal."
            )
        }

        let fileLocation = URL(fileURLWithPath: manifest.fileLocationPath)
            .standardizedFileURL.resolvingSymlinksInPath()
        let payloadPaths = Set(manifest.payloads.map { payload in
            URL(fileURLWithPath: payload.path)
                .standardizedFileURL.resolvingSymlinksInPath().path
        })
        guard fileLocation == destinationFolder || payloadPaths.contains(fileLocation.path) else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media location is outside its destination."
            )
        }
        guard try regularFileIdentity(at: manifestURL) == manifestIdentity else {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media journal changed while it was being verified."
            )
        }
        return manifest
    }

    func regularFileIdentity(at url: URL) throws -> RegularFileIdentity {
        do {
            return try DurableFileSystem.regularFileIdentity(at: url)
        } catch is CocoaError {
            throw CompletionManifestIntegrityError.invalid(
                "The completed media path is not a regular file."
            )
        }
    }

    private func destinationFileIdentities(
        in destinationFolder: URL
    ) throws -> [String: RegularFileIdentity] {
        let entries = try fileManager.contentsOfDirectory(
            at: destinationFolder,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var identities: [String: RegularFileIdentity] = [:]
        for entry in entries {
            let values = try entry.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                continue
            }
            let candidate = entry.standardizedFileURL.resolvingSymlinksInPath()
            identities[candidate.path] = try regularFileIdentity(at: candidate)
        }
        return identities
    }

    private func requireAttemptProduced(
        _ url: URL,
        for download: RunningDownload
    ) throws {
        try requireAttemptProduced(
            url,
            preexistingDestinationFiles: download.preexistingDestinationFiles
        )
    }

    private func requireAttemptProduced(
        _ url: URL,
        preexistingDestinationFiles: [String: RegularFileIdentity]
    ) throws {
        let candidate = url.standardizedFileURL.resolvingSymlinksInPath()
        guard let previousIdentity = preexistingDestinationFiles[candidate.path] else {
            return
        }
        let currentIdentity = try regularFileIdentity(at: candidate)
        guard Self.isAttemptProducedOutput(
            previousIdentity: previousIdentity,
            currentIdentity: currentIdentity
        ) else {
            throw MediaDownloadError.outputConflict(
                "yt-dlp reused a destination file that existed before this attempt. Retry to save the download under a collision-safe filename."
            )
        }
    }

    nonisolated static func isAttemptProducedOutput(
        previousIdentity: RegularFileIdentity?,
        currentIdentity: RegularFileIdentity
    ) -> Bool {
        previousIdentity == nil || previousIdentity != currentIdentity
    }

    private func verifiedSHA256(
        at url: URL,
        expectedBytes: Int64
    ) throws -> String {
        let before = try regularFileIdentity(at: url)
        guard Int64(before.size) == expectedBytes else {
            throw CompletionManifestIntegrityError.invalid(
                "A completed media payload no longer matches its journal."
            )
        }
        let digest = try DurableFileSystem.sha256(at: url)
        guard try regularFileIdentity(at: url) == before else {
            throw CompletionManifestIntegrityError.invalid(
                "A completed media payload changed while it was being verified."
            )
        }
        return digest
    }

    private func createAndValidateTemporaryFolder(_ folder: URL) throws {
        try fileManager.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        try validateTemporaryFolder(folder)
    }

    private func validateTemporaryFolder(_ folder: URL) throws {
        try validateTemporaryRoot()
        let folderValues = try folder.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let resolvedRoot = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
        let resolvedFolder = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard folderValues.isDirectory == true,
              folderValues.isSymbolicLink != true,
              resolvedFolder.deletingLastPathComponent() == resolvedRoot else {
            throw MediaDownloadError.unavailable(
                "Harbor’s media recovery directory is not a safe owned directory."
            )
        }
    }

    private func validateTemporaryRoot() throws {
        let values = try temporaryRoot.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard values.isDirectory == true,
              values.isSymbolicLink != true else {
            throw MediaDownloadError.unavailable(
                "Harbor’s media recovery directory is not a safe owned directory."
            )
        }
    }

    private func cleanupTemporaryFolder(_ folder: URL) {
        do {
            try validateTemporaryFolder(folder)
            try fileManager.removeItem(at: folder)
            try DurableFileSystem.synchronizeParentDirectory(of: folder)
        } catch {
            logger.warning(
                "Could not safely remove media recovery data at \(folder.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    private func validatedFinalFile(
        _ reportedURL: URL,
        destinationFolder: URL
    ) throws -> (url: URL, byteCount: Int64) {
        let destination = destinationFolder.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = reportedURL.standardizedFileURL.resolvingSymlinksInPath()
        let destinationPrefix = destination.path.hasSuffix("/")
            ? destination.path
            : destination.path + "/"
        guard reportedURL.isFileURL,
              candidate.path.hasPrefix(destinationPrefix) else {
            throw MediaDownloadError.processFailed(
                "yt-dlp reported a completed file outside the selected destination folder."
            )
        }

        let values = try candidate.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let fileSize = values.fileSize,
              fileSize >= 0 else {
            throw MediaDownloadError.processFailed(
                "yt-dlp reported a completed path that is not a regular file."
            )
        }
        return (candidate, Int64(fileSize))
    }

    private func cleanupOrphanedMediaProcessesIfNeeded() async throws {
        let ownershipMarkerIDs = try processOwnershipMarkerIDs()
        let ownershipManifests = try processOwnershipManifests()
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let currentProcessGroupIdentifier = getpgrp()
        let protectedPIDs = Set(runningDownloads.values.map { $0.process.processIdentifier })
        for manifest in ownershipManifests {
            if runningDownloads.values.contains(where: {
                $0.processOwnership == manifest
            }) {
                continue
            }

            let processes = try runningProcesses()
            guard let processAtRecordedPID = processes.first(where: {
                $0.pid == manifest.pid
            }) else {
                guard Self.hasLiveProcessGroupMember(
                    manifest.processGroupIdentifier,
                    in: processes
                ) == false else {
                    // The session leader may exit before a converter or other
                    // descendant. Without the recorded root identity Harbor
                    // cannot safely signal those descendants, but it must keep
                    // the marker so no replacement writer can start.
                    throw MediaDownloadError.unavailable(
                        "Harbor’s earlier media process exited, but members of its process group are still running. They were left untouched."
                    )
                }
                recoverChildCompletionBeforeRetiringOwnership(id: manifest.downloadID)
                try discardProcessOwnershipManifest(manifest)
                continue
            }

            guard Self.isVerifiedOwnedRootProcess(
                processAtRecordedPID,
                manifest: manifest,
                currentProcessIdentifier: currentPID,
                currentProcessGroupIdentifier: currentProcessGroupIdentifier,
                temporaryRoot: temporaryRoot
            ) else {
                if processAtRecordedPID.startSignature != manifest.startSignature
                    || processAtRecordedPID.executablePath != manifest.executablePath {
                    guard Self.hasLiveProcessGroupMember(
                        manifest.processGroupIdentifier,
                        in: processes
                    ) == false else {
                        // Do not retire the only ownership barrier while the
                        // old private group may still contain a descendant.
                        throw MediaDownloadError.unavailable(
                            "Harbor found a reused media process identifier while members of the earlier process group are still running. They were left untouched."
                        )
                    }
                    // The numeric PID was reused after Harbor's child exited.
                    // Retire only the stale marker; never signal the new owner.
                    recoverChildCompletionBeforeRetiringOwnership(id: manifest.downloadID)
                    try discardProcessOwnershipManifest(manifest)
                    continue
                }
                throw MediaDownloadError.unavailable(
                    "Harbor found a media process marker but could not verify its exact process owner. The process was left running."
                )
            }

            // POSIX_SPAWN_SETSID gives each managed download a private process
            // group. Capture every member's immutable identity while the
            // verified session leader still anchors that group, then signal
            // only those exact PIDs. A later PID/PGID reuse cannot become a
            // target of either escalation pass.
            let originalMembers = processes.filter {
                $0.processGroupIdentifier == manifest.processGroupIdentifier
                    && $0.pid != currentPID
                    && protectedPIDs.contains($0.pid) == false
            }
            guard originalMembers.allSatisfy({
                $0.executablePath != nil && $0.startSignature != nil
            }) else {
                throw MediaDownloadError.unavailable(
                    "Harbor could not capture the exact identity of every earlier media process. The process group was left untouched."
                )
            }
            for process in matchingProcesses(originalMembers, in: processes) {
                logger.warning(
                    "Terminating verified orphaned media process with pid \(process.pid, privacy: .public)"
                )
                _ = kill(process.pid, SIGTERM)
            }

            try? await Task.sleep(for: .milliseconds(600))
            let afterTerm = try runningProcesses()
            let killTargets = matchingProcesses(originalMembers, in: afterTerm)
            for process in killTargets {
                logger.warning(
                    "Force terminating verified orphaned media process with pid \(process.pid, privacy: .public)"
                )
                _ = kill(process.pid, SIGKILL)
            }
            if killTargets.isEmpty == false {
                try? await Task.sleep(for: .milliseconds(150))
            }

            let finalProcesses = try runningProcesses()
            let survivingGroupMembers = finalProcesses.filter {
                $0.processGroupIdentifier == manifest.processGroupIdentifier
            }
            guard survivingGroupMembers.isEmpty else {
                let identifiers = survivingGroupMembers
                    .map { String($0.pid) }
                    .joined(separator: ", ")
                throw MediaDownloadError.unavailable(
                    "Harbor could not confirm that its earlier media processes stopped (PIDs: \(identifiers))."
                )
            }
            recoverChildCompletionBeforeRetiringOwnership(id: manifest.downloadID)
            try discardProcessOwnershipManifest(manifest)
        }

        let remainingProcesses = try runningProcesses()
        let trackedProcessGroups = Set(
            runningDownloads.values.map(\.processOwnership.processGroupIdentifier)
        )
        guard Self.hasUntrackedProcessReferencingRecoveryRoot(
            temporaryRoot,
            in: remainingProcesses,
            trackedProcessGroups: trackedProcessGroups
        ) == false else {
            // A crash can occur between process creation and durable marker
            // publication. The recovery-root argument proves only that another
            // writer may exist; it is deliberately not sufficient authority to
            // send that process a signal.
            throw MediaDownloadError.unavailable(
                "Harbor found an unverified media process using its recovery directory. The process was left untouched."
            )
        }

        let validatedMarkerIDs = Set(ownershipManifests.map(\.downloadID))
        for id in ownershipMarkerIDs.subtracting(validatedMarkerIDs) {
            guard runningDownloads[id] == nil,
                  Self.hasProcessReferencingRecoveryFolder(
                      temporaryFolder(for: id),
                      in: remainingProcesses
                  ) == false else {
                continue
            }
            recoverChildCompletionBeforeRetiringOwnership(id: id)
            try discardUnverifiableProcessOwnershipMarker(id: id)
        }
    }

    nonisolated static func hasLiveProcessGroupMember(
        _ processGroupIdentifier: pid_t,
        in processes: [MediaRunningProcess]
    ) -> Bool {
        processes.contains {
            $0.processGroupIdentifier == processGroupIdentifier
        }
    }

    nonisolated static func hasProcessReferencingRecoveryFolder(
        _ recoveryFolder: URL,
        in processes: [MediaRunningProcess]
    ) -> Bool {
        let path = recoveryFolder.standardizedFileURL.path
        return processes.contains { $0.command.contains(path) }
    }

    nonisolated static func hasUntrackedProcessReferencingRecoveryRoot(
        _ recoveryRoot: URL,
        in processes: [MediaRunningProcess],
        trackedProcessGroups: Set<pid_t>
    ) -> Bool {
        let path = recoveryRoot.standardizedFileURL.path
        return processes.contains {
            trackedProcessGroups.contains($0.processGroupIdentifier) == false
                && $0.command.contains(path)
        }
    }

    private func matchingProcesses(
        _ expected: [MediaRunningProcess],
        in current: [MediaRunningProcess]
    ) -> [MediaRunningProcess] {
        current.filter { candidate in
            expected.contains { original in
                guard let candidateStartSignature = candidate.startSignature,
                      let originalStartSignature = original.startSignature else {
                    return false
                }
                return candidate.pid == original.pid
                    && candidate.processGroupIdentifier == original.processGroupIdentifier
                    && candidate.executablePath == original.executablePath
                    && candidateStartSignature == originalStartSignature
                    && candidate.command == original.command
            }
        }
    }

    private func runningProcesses() throws -> [MediaRunningProcess] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,pgid=,command=", "-ww"]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw MediaDownloadError.unavailable(
                "Harbor could not inspect active media processes: \(error.localizedDescription)"
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw MediaDownloadError.unavailable(
                "Harbor could not inspect active media processes (ps exited with status \(process.terminationStatus))."
            )
        }
        guard let output = String(data: data, encoding: .utf8) else {
            throw MediaDownloadError.unavailable(
                "Harbor could not decode the active media process list."
            )
        }

        return output
            .split(separator: "\n")
            .compactMap { runningProcess(from: String($0)) }
    }

    private func runningProcess(from processLine: String) -> MediaRunningProcess? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)

        guard parts.count == 4,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]),
              let processGroupIdentifier = pid_t(parts[2]) else {
            return nil
        }

        return MediaRunningProcess(
            pid: pid,
            parentPID: parentPID,
            processGroupIdentifier: processGroupIdentifier,
            executablePath: processExecutablePath(pid: pid),
            startSignature: processStartSignature(pid: pid),
            command: String(parts[3])
        )
    }

    private func processStartSignature(pid: pid_t) -> String? {
        var information = proc_bsdinfo()
        let expectedSize = MemoryLayout<proc_bsdinfo>.stride
        let actualSize = withUnsafeMutablePointer(to: &information) { pointer in
            proc_pidinfo(
                pid,
                PROC_PIDTBSDINFO,
                0,
                pointer,
                Int32(expectedSize)
            )
        }
        guard actualSize == Int32(expectedSize) else {
            return nil
        }
        return "\(information.pbi_start_tvsec):\(information.pbi_start_tvusec)"
    }

    private func processExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBytes { bytes in
            proc_pidpath(pid, bytes.baseAddress, UInt32(bytes.count))
        }
        guard length > 0 else {
            return nil
        }
        return String(cString: buffer)
    }

    nonisolated static func isVerifiedOwnedRootProcess(
        _ process: MediaRunningProcess,
        manifest: MediaProcessOwnershipManifest,
        currentProcessIdentifier: pid_t,
        currentProcessGroupIdentifier: pid_t,
        temporaryRoot: URL
    ) -> Bool {
        let expectedTemporaryFolder = temporaryRoot
            .appendingPathComponent(manifest.downloadID.uuidString, isDirectory: true)
            .standardizedFileURL.path
        return manifest.version == MediaProcessOwnershipManifest.currentVersion
            && manifest.pid > 1
            && manifest.processGroupIdentifier == manifest.pid
            && manifest.temporaryFolderPath == expectedTemporaryFolder
            && manifest.launchedExecutablePath.hasPrefix("/")
            && process.pid == manifest.pid
            && process.pid != currentProcessIdentifier
            && (process.parentPID == 1 || process.parentPID == currentProcessIdentifier)
            && process.processGroupIdentifier == manifest.processGroupIdentifier
            && process.processGroupIdentifier != currentProcessGroupIdentifier
            && process.executablePath == manifest.executablePath
            && process.startSignature == manifest.startSignature
            && process.command == manifest.command
    }

    private func persistProcessOwnership(
        processIdentifier: pid_t,
        downloadID: UUID,
        attemptIdentifier: UUID,
        executableURL: URL,
        temporaryFolder: URL
    ) throws -> MediaProcessOwnershipManifest {
        try createAndValidateTemporaryFolder(temporaryFolder)
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let launchedExecutablePath = executableURL.standardizedFileURL
            .resolvingSymlinksInPath().path
        guard let process = try runningProcesses().first(where: {
            $0.pid == processIdentifier
        }), process.parentPID == currentPID,
            process.processGroupIdentifier == processIdentifier,
            let executablePath = process.executablePath,
            let startSignature = process.startSignature else {
            throw MediaDownloadError.unavailable(
                "Harbor could not verify the newly launched media process."
            )
        }

        let manifest = MediaProcessOwnershipManifest(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            pid: process.pid,
            processGroupIdentifier: process.processGroupIdentifier,
            launchedExecutablePath: launchedExecutablePath,
            executablePath: executablePath,
            temporaryFolderPath: temporaryFolder.standardizedFileURL.path,
            startSignature: startSignature,
            command: process.command
        )
        let url = processOwnershipManifestURL(id: downloadID)
        guard try DurableFileSystem.itemExists(at: url) == false else {
            throw MediaDownloadError.unavailable(
                "A previous media process still owns this recovery directory."
            )
        }
        try DurableFileSystem.writeAtomicallyWithoutReplacing(
            JSONEncoder().encode(manifest),
            to: url
        )
        try DurableFileSystem.synchronizeParentDirectory(of: temporaryFolder)
        return manifest
    }

    private func processOwnershipManifests() throws -> [MediaProcessOwnershipManifest] {
        guard try DurableFileSystem.itemExists(at: temporaryRoot) else {
            return []
        }
        try validateTemporaryRoot()
        let folders = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        return folders.compactMap { folder in
            guard let id = UUID(uuidString: folder.lastPathComponent) else {
                return nil
            }
            do {
                return try processOwnershipManifest(id: id)
            } catch {
                // An unreadable or malformed marker cannot authorize a signal.
                // Preserve it and its recovery directory for diagnosis.
                logger.warning(
                    "Ignoring unverifiable media process ownership for \(id.uuidString, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
                return nil
            }
        }
    }

    private func processOwnershipMarkerIDs() throws -> Set<UUID> {
        guard try DurableFileSystem.itemExists(at: temporaryRoot) else {
            return []
        }
        try validateTemporaryRoot()
        let folders = try fileManager.contentsOfDirectory(
            at: temporaryRoot,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        )
        var identifiers = Set<UUID>()
        for folder in folders {
            guard let id = UUID(uuidString: folder.lastPathComponent),
                  try DurableFileSystem.itemExists(at: processOwnershipManifestURL(id: id)) else {
                continue
            }
            identifiers.insert(id)
        }
        return identifiers
    }

    private func processOwnershipManifest(
        id: UUID
    ) throws -> MediaProcessOwnershipManifest? {
        let folder = temporaryFolder(for: id)
        let url = processOwnershipManifestURL(id: id)
        guard try DurableFileSystem.itemExists(at: url) else {
            return nil
        }
        try validateTemporaryFolder(folder)
        let markerValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let manifest = try JSONDecoder().decode(
            MediaProcessOwnershipManifest.self,
            from: Data(contentsOf: url)
        )
        guard manifest.version == MediaProcessOwnershipManifest.currentVersion,
              manifest.downloadID == id,
              manifest.pid > 1,
              manifest.processGroupIdentifier == manifest.pid,
              manifest.temporaryFolderPath == folder.standardizedFileURL.path,
              manifest.startSignature.isEmpty == false,
              manifest.command.isEmpty == false,
              manifest.launchedExecutablePath.hasPrefix("/"),
              manifest.executablePath.isEmpty == false else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private func discardUnverifiableProcessOwnershipMarker(id: UUID) throws {
        let folder = temporaryFolder(for: id)
        let url = processOwnershipManifestURL(id: id)
        try validateTemporaryFolder(folder)
        let folderValues = try folder.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        let markerValues = try url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard folderValues.isDirectory == true,
              folderValues.isSymbolicLink != true,
              markerValues.isRegularFile == true,
              markerValues.isSymbolicLink != true else {
            throw MediaDownloadError.unavailable(
                "Harbor found an unsafe media process marker and left it untouched."
            )
        }
        try fileManager.removeItem(at: url)
        try DurableFileSystem.synchronizeDirectory(at: folder)
    }

    private func discardProcessOwnershipManifest(
        _ expected: MediaProcessOwnershipManifest
    ) throws {
        guard let current = try processOwnershipManifest(id: expected.downloadID) else {
            return
        }
        guard current == expected else {
            throw MediaDownloadError.unavailable(
                "A newer media attempt owns this process marker."
            )
        }
        let url = processOwnershipManifestURL(id: expected.downloadID)
        try fileManager.removeItem(at: url)
        try DurableFileSystem.synchronizeDirectory(
            at: temporaryFolder(for: expected.downloadID)
        )
    }

    private func processOwnershipManifestURL(id: UUID) -> URL {
        temporaryFolder(for: id)
            .appendingPathComponent(Self.processOwnershipManifestFilename)
    }

    private static func defaultTemporaryRoot(fileManager: FileManager) -> URL {
        HarborApplicationSupport.directoryURL(fileManager: fileManager)
            .appendingPathComponent("MediaDownloads", isDirectory: true)
    }
}

final class MetadataCommandState: @unchecked Sendable {
    nonisolated static let maximumCapturedBytes = 16 * 1_024 * 1_024

    nonisolated private let lock = NSLock()
    nonisolated private let maximumCapturedBytes: Int
    nonisolated(unsafe) private var stdoutBuffer = ""
    nonisolated(unsafe) private var stderrBuffer = ""
    nonisolated(unsafe) private var capturedByteCount = 0
    nonisolated(unsafe) private var isCompleted = false
    nonisolated(unsafe) private var outputLimitError: Error?
    nonisolated(unsafe) private var storedProcess: ManagedChildProcess?

    nonisolated init(maximumCapturedBytes: Int = MetadataCommandState.maximumCapturedBytes) {
        self.maximumCapturedBytes = max(maximumCapturedBytes, 0)
    }

    nonisolated var process: ManagedChildProcess? {
        get {
            lock.withLock { storedProcess }
        }
        set {
            lock.withLock {
                storedProcess = newValue
            }
        }
    }

    nonisolated var shouldTerminateProcess: Bool {
        lock.withLock { outputLimitError != nil }
    }

    @discardableResult
    nonisolated func appendStdout(_ output: String) -> Bool {
        lock.withLock {
            guard reserveCapacity(for: output) else {
                return false
            }
            stdoutBuffer += output
            return true
        }
    }

    @discardableResult
    nonisolated func appendStderr(_ output: String) -> Bool {
        lock.withLock {
            guard reserveCapacity(for: output) else {
                return false
            }
            stderrBuffer += output
            return true
        }
    }

    nonisolated func markOutputLimitExceeded() {
        lock.withLock {
            recordOutputLimitExceeded()
        }
    }

    nonisolated func markTimedOut() -> Bool {
        lock.withLock {
            guard isCompleted == false else {
                return false
            }

            isCompleted = true
            storedProcess = nil
            stdoutBuffer = ""
            stderrBuffer = ""
            capturedByteCount = 0
            return true
        }
    }

    nonisolated func finish(termination: ManagedChildProcessTermination) -> Result<Data, Error>? {
        lock.withLock {
            guard isCompleted == false else {
                return nil
            }

            isCompleted = true

            let result: Result<Data, Error>
            if let outputLimitError {
                result = .failure(outputLimitError)
            } else if termination.isSuccess {
                result = .success(Data(stdoutBuffer.utf8))
            } else {
                result = .failure(
                    MediaDownloadError.unsupported(
                        MediaDownloadErrorClassifier.message(from: stderrBuffer)
                    )
                )
            }

            storedProcess = nil
            stdoutBuffer = ""
            stderrBuffer = ""
            capturedByteCount = 0
            return result
        }
    }

    nonisolated private func reserveCapacity(for output: String) -> Bool {
        guard isCompleted == false, outputLimitError == nil else {
            return false
        }

        let byteCount = output.utf8.count
        guard byteCount <= maximumCapturedBytes - capturedByteCount else {
            recordOutputLimitExceeded()
            return false
        }
        capturedByteCount += byteCount
        return true
    }

    nonisolated private func recordOutputLimitExceeded() {
        guard outputLimitError == nil else {
            return
        }
        outputLimitError = MediaDownloadError.unavailable(
            "This media link returned too much metadata."
        )
        stdoutBuffer = ""
        stderrBuffer = ""
        capturedByteCount = 0
    }
}

private final class MediaProcessOutputCapture: @unchecked Sendable {
    nonisolated private static let maximumCapturedBytes = 1_048_576
    nonisolated private static let retainedCharacterCount = 200_000

    struct Snapshot: Sendable {
        let stdout: String
        let stderr: String
    }

    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var stdout = ""
    nonisolated(unsafe) private var stderr = ""
    nonisolated(unsafe) private var stdoutByteCount = 0
    nonisolated(unsafe) private var stderrByteCount = 0

    nonisolated init() {}

    nonisolated func appendStdout(_ output: String) {
        lock.withLock {
            stdout += output
            stdoutByteCount += output.utf8.count
            if stdoutByteCount > Self.maximumCapturedBytes {
                stdout = String(stdout.suffix(Self.retainedCharacterCount))
                stdoutByteCount = stdout.utf8.count
            }
        }
    }

    nonisolated func appendStderr(_ output: String) {
        lock.withLock {
            stderr += output
            stderrByteCount += output.utf8.count
            if stderrByteCount > Self.maximumCapturedBytes {
                stderr = String(stderr.suffix(Self.retainedCharacterCount))
                stderrByteCount = stderr.utf8.count
            }
        }
    }

    nonisolated func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(stdout: stdout, stderr: stderr)
        }
    }
}

struct MediaDownloadProgress: Equatable, Sendable {
    let bytesWritten: Int64
    let expectedBytes: Int64
    let speedBytesPerSecond: Double
}

enum MediaDownloadProgressParser {
    nonisolated static func progress(from line: String) -> MediaDownloadProgress? {
        guard line.hasPrefix("harbor-progress:") else {
            return nil
        }

        let payload = line.dropFirst("harbor-progress:".count)
        let parts = payload.split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 3 else {
            return nil
        }

        let bytesWritten = Int64(parts[0]) ?? 0
        let expectedBytes = Int64(parts[1]) ?? 0
        let speedBytesPerSecond = Double(parts[2]) ?? 0
        return MediaDownloadProgress(
            bytesWritten: bytesWritten,
            expectedBytes: expectedBytes,
            speedBytesPerSecond: speedBytesPerSecond
        )
    }
}

enum MediaDownloadFinalPathParser {
    nonisolated static func fileURL(from line: String) -> URL? {
        guard line.hasPrefix("harbor-file:") else {
            return nil
        }

        let payload = line.dropFirst("harbor-file:".count)
        if let data = payload.data(using: .utf8),
           let path = try? JSONDecoder().decode(String.self, from: data),
           path.isEmpty == false {
            return URL(fileURLWithPath: path)
        }

        let path = payload.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path)
    }
}

enum MediaDownloadErrorClassifier {
    nonisolated static let selectedFormatUnavailableMessage =
        "The selected media format is no longer available."

    nonisolated static func message(from stderr: String) -> String {
        let normalized = stderr.lowercased()

        if normalized.contains("unsupported url") || normalized.contains("no suitable extractor") {
            return "Harbor doesn’t support this media link yet."
        }

        if normalized.contains("login")
            || normalized.contains("sign in")
            || normalized.contains("private")
            || normalized.contains("authentication") {
            return "yt-dlp couldn’t access this link. It may need sign-in, be private, or be blocked by the platform."
        }

        if normalized.contains("copyright") || normalized.contains("drm") {
            return "yt-dlp couldn’t access a downloadable media stream for this link."
        }

        if normalized.contains("requested format is not available") {
            return selectedFormatUnavailableMessage
        }

        if normalized.contains("no video formats found")
            || normalized.contains("no formats found") {
            return "No downloadable media format was available for this link."
        }

        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false {
            return trimmed
        }

        return "The media download failed."
    }
}
