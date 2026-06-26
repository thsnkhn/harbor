import Darwin
import Foundation
import OSLog

enum MediaDownloadEvent: Sendable {
    case started(id: UUID, processIdentifier: Int32, expectedBytes: Int64, title: String?, platform: String?)
    case progress(id: UUID, bytesWritten: Int64, expectedBytes: Int64, speedBytesPerSecond: Double)
    case paused(id: UUID)
    case cancelled(id: UUID)
    case finished(id: UUID, fileURL: URL, expectedBytes: Int64)
    case failed(id: UUID, message: String)
}

enum MediaDownloadError: LocalizedError {
    case runtimeNotFound
    case unsupported(String)
    case unavailable(String)
    case processFailed(String)

    var errorDescription: String? {
        switch self {
        case .runtimeNotFound:
            MediaRuntimeResolver.installHint
        case let .unsupported(message), let .unavailable(message), let .processFailed(message):
            message
        }
    }
}

actor MediaDownloadService {
    typealias EventHandler = @Sendable (MediaDownloadEvent) -> Void

    private enum TerminationReason {
        case pause
        case cancel
    }

    private struct RunningDownload {
        let id: UUID
        let process: ManagedChildProcess
        let destinationFolder: URL
        let temporaryFolder: URL
        let metadata: MediaDownloadMetadata?
        var terminationReason: TerminationReason?
        var stdoutBuffer = ""
        var stderrBuffer = ""
        var lastFileURL: URL?
        var expectedBytes: Int64
    }

    private struct RunningProcess {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
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
    private var hasCleanedOrphans = false

    init(
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.temporaryRoot = Self.defaultTemporaryRoot(fileManager: fileManager)
    }

    func metadata(for url: URL) async throws -> MediaDownloadMetadata {
        let runtime = try resolvedRuntime()
        let output = try await runMetadataCommand(runtime: runtime, url: url)
        return try MediaDownloadMetadataParser.metadata(from: output, sourceURL: url)
    }

    func startDownload(
        id: UUID,
        sourceURL: URL,
        destinationFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference
    ) async throws -> Int32 {
        if let existing = runningDownloads[id] {
            return existing.process.processIdentifier
        }

        let runtime = try resolvedRuntime()
        cleanupOrphanedMediaProcessesIfNeeded(runtime: runtime)

        let temporaryFolder = temporaryFolder(for: id)
        try fileManager.createDirectory(at: temporaryFolder, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: destinationFolder, withIntermediateDirectories: true)

        let arguments = downloadArguments(
            runtime: runtime,
            sourceURL: sourceURL,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            metadata: metadata,
            formatPreference: formatPreference
        )

        let environment = processEnvironment(runtime: runtime)
        let process = try ManagedChildProcess(
            executableURL: runtime.ytDlpURL,
            arguments: arguments,
            environment: environment,
            onStdout: { [weak self] output in
                Task { await self?.handleOutput(output, stream: .stdout, for: id) }
            },
            onStderr: { [weak self] output in
                Task { await self?.handleOutput(output, stream: .stderr, for: id) }
            },
            onTermination: { [weak self] termination in
                Task { await self?.handleTermination(termination, for: id) }
            }
        )

        let expectedBytes = metadata?.expectedBytes ?? 0
        runningDownloads[id] = RunningDownload(
            id: id,
            process: process,
            destinationFolder: destinationFolder,
            temporaryFolder: temporaryFolder,
            metadata: metadata,
            expectedBytes: expectedBytes
        )

        logger.info("Started media download \(id.uuidString, privacy: .public) with pid \(process.processIdentifier, privacy: .public)")
        eventHandler(
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
            cleanupTemporaryFolder(for: id)
            return false
        }

        download.terminationReason = .cancel
        runningDownloads[id] = download
        download.process.terminate()
        return true
    }

    @discardableResult
    func remove(id: UUID) -> Bool {
        cancel(id: id)
    }

    func shutdown() async {
        let downloads = Array(runningDownloads.values)
        for download in downloads {
            var updatedDownload = download
            updatedDownload.terminationReason = .pause
            runningDownloads[download.id] = updatedDownload
            download.process.terminate(grace: 0.6)
        }

        // ponytail: short bounded wait lets process-group SIGTERM/SIGKILL fire during app quit without inventing a shutdown coordinator.
        try? await Task.sleep(for: .milliseconds(750))
    }

    private enum OutputStream {
        case stdout
        case stderr
    }

    private func handleOutput(
        _ output: String,
        stream: OutputStream,
        for id: UUID
    ) {
        guard var download = runningDownloads[id] else {
            return
        }

        switch stream {
        case .stdout:
            download.stdoutBuffer += output
            let lines = completeLines(from: &download.stdoutBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id)
        case .stderr:
            download.stderrBuffer += output
            let lines = completeLines(from: &download.stderrBuffer)
            runningDownloads[id] = download
            process(lines: lines, for: id)
        }
    }

    private func process(lines: [String], for id: UUID) {
        for line in lines {
            if let progress = MediaDownloadProgressParser.progress(from: line) {
                apply(progress: progress, to: id)
                continue
            }

            if let fileURL = MediaDownloadFinalPathParser.fileURL(from: line) {
                guard var download = runningDownloads[id] else {
                    continue
                }

                download.lastFileURL = fileURL
                runningDownloads[id] = download
            }
        }
    }

    private func apply(
        progress: MediaDownloadProgress,
        to id: UUID
    ) {
        guard var download = runningDownloads[id] else {
            return
        }

        let expectedBytes = max(progress.expectedBytes, download.expectedBytes)
        download.expectedBytes = expectedBytes
        runningDownloads[id] = download

        eventHandler(
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
        for id: UUID
    ) {
        guard let download = runningDownloads.removeValue(forKey: id) else {
            return
        }

        logger.info("Media download \(id.uuidString, privacy: .public) exited with status \(termination.waitStatus, privacy: .public)")

        switch download.terminationReason {
        case .pause:
            eventHandler(.paused(id: id))
            return
        case .cancel:
            cleanupTemporaryFolder(download.temporaryFolder)
            eventHandler(.cancelled(id: id))
            return
        case nil:
            break
        }

        guard termination.isSuccess else {
            cleanupTemporaryFolder(download.temporaryFolder)
            eventHandler(.failed(id: id, message: MediaDownloadErrorClassifier.message(from: download.stderrBuffer)))
            return
        }

        cleanupTemporaryFolder(download.temporaryFolder)

        let fileURL = download.metadata?.isCollection == true
            ? download.destinationFolder
            : (download.lastFileURL ?? newestFile(in: download.destinationFolder) ?? download.destinationFolder)

        eventHandler(
            .finished(
                id: id,
                fileURL: fileURL,
                expectedBytes: download.expectedBytes
            )
        )
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
            "--socket-timeout",
            "15",
            "--dump-single-json",
            "--flat-playlist",
            "--skip-download",
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
                        onStdout: { output in
                            state.appendStdout(output)
                        },
                        onStderr: { output in
                            state.appendStderr(output)
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

                    Task {
                        try? await Task.sleep(for: .seconds(45))
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

    private func downloadArguments(
        runtime: MediaRuntimeResolution,
        sourceURL: URL,
        destinationFolder: URL,
        temporaryFolder: URL,
        metadata: MediaDownloadMetadata?,
        formatPreference: MediaDownloadFormatPreference
    ) -> [String] {
        var arguments = [
            "--ignore-config",
            "--no-cache-dir",
            "--newline",
            "--continue",
            "--no-overwrites",
            "--socket-timeout",
            "15",
            "--paths",
            "home:\(destinationFolder.path)",
            "--paths",
            "temp:\(temporaryFolder.path)",
            "--output",
            "%(title).180B [%(id)s].%(ext)s",
            "--print",
            "after_move:harbor-file:%(filepath)j",
            "--progress-template",
            "download:harbor-progress:%(progress.downloaded_bytes|0)s\t%(progress.total_bytes,progress.total_bytes_estimate|0)s\t%(progress.speed|0)s",
            "--ffmpeg-location",
            runtime.ffmpegURL.deletingLastPathComponent().path
        ]

        if metadata?.isCollection != true {
            arguments.append("--no-playlist")
        }

        switch formatPreference {
        case .bestMP4:
            arguments.append(contentsOf: [
                "--format",
                "bv*[ext=mp4]+ba[ext=m4a]/b[ext=mp4]/bestvideo+bestaudio/best",
                "--merge-output-format",
                "mp4"
            ])
        case .original:
            break
        }

        arguments.append(sourceURL.absoluteString)
        return arguments
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

    private func cleanupTemporaryFolder(for id: UUID) {
        cleanupTemporaryFolder(temporaryFolder(for: id))
    }

    private func cleanupTemporaryFolder(_ folder: URL) {
        try? fileManager.removeItem(at: folder)
    }

    private func newestFile(in directory: URL) -> URL? {
        guard let fileURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey]
        ) else {
            return nil
        }

        return fileURLs
            .filter { url in
                (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true
            }
            .max { lhs, rhs in
                let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return lhsDate < rhsDate
            }
    }

    private func cleanupOrphanedMediaProcessesIfNeeded(runtime: MediaRuntimeResolution) {
        guard hasCleanedOrphans == false else {
            return
        }

        hasCleanedOrphans = true
        let currentPID = ProcessInfo.processInfo.processIdentifier

        for process in runningProcesses() {
            guard process.parentPID == 1,
                  process.pid != currentPID,
                  isHarborManagedMediaProcess(process.command, runtime: runtime) else {
                continue
            }

            logger.warning("Terminating orphaned media process with pid \(process.pid, privacy: .public)")
            _ = kill(process.pid, SIGTERM)
        }
    }

    private func runningProcesses() -> [RunningProcess] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.warning("Could not inspect media processes: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0,
              let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { runningProcess(from: String($0)) }
    }

    private func runningProcess(from processLine: String) -> RunningProcess? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)

        guard parts.count == 3,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]) else {
            return nil
        }

        return RunningProcess(
            pid: pid,
            parentPID: parentPID,
            command: String(parts[2])
        )
    }

    private func isHarborManagedMediaProcess(
        _ command: String,
        runtime: MediaRuntimeResolution
    ) -> Bool {
        if command.contains(temporaryRoot.path) {
            return true
        }

        guard command.contains("/Harbor.app/Contents/Resources/MediaRuntime/")
            || command.contains("/MediaRuntime/") else {
            return false
        }

        return command.hasPrefix(runtime.ytDlpURL.path)
            || command.hasPrefix(runtime.ffmpegURL.path)
            || command.hasPrefix(runtime.ffprobeURL.path)
            || command.contains("/Harbor.app/Contents/Resources/MediaRuntime/")
    }

    private static func defaultTemporaryRoot(fileManager: FileManager) -> URL {
        let applicationSupportURL = (try? fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ))
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupportURL
            .appendingPathComponent("Harbor", isDirectory: true)
            .appendingPathComponent("MediaDownloads", isDirectory: true)
    }
}

private final class MetadataCommandState: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated(unsafe) private var stdoutBuffer = ""
    nonisolated(unsafe) private var stderrBuffer = ""
    nonisolated(unsafe) private var isCompleted = false
    nonisolated(unsafe) private var storedProcess: ManagedChildProcess?

    nonisolated init() {}

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

    nonisolated func appendStdout(_ output: String) {
        lock.withLock {
            stdoutBuffer += output
        }
    }

    nonisolated func appendStderr(_ output: String) {
        lock.withLock {
            stderrBuffer += output
        }
    }

    nonisolated func markTimedOut() -> Bool {
        lock.withLock {
            guard isCompleted == false else {
                return false
            }

            isCompleted = true
            return true
        }
    }

    nonisolated func finish(termination: ManagedChildProcessTermination) -> Result<Data, Error>? {
        lock.withLock {
            guard isCompleted == false else {
                return nil
            }

            isCompleted = true

            if termination.isSuccess {
                return .success(Data(stdoutBuffer.utf8))
            }

            return .failure(
                MediaDownloadError.unsupported(
                    MediaDownloadErrorClassifier.message(from: stderrBuffer)
                )
            )
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
    nonisolated static func message(from stderr: String) -> String {
        let normalized = stderr.lowercased()

        if normalized.contains("unsupported url") || normalized.contains("no suitable extractor") {
            return "Harbor doesn’t support this media link yet."
        }

        if normalized.contains("login")
            || normalized.contains("sign in")
            || normalized.contains("private")
            || normalized.contains("authentication") {
            return "This media requires sign-in or is private. Harbor only downloads public media you have permission to save."
        }

        if normalized.contains("copyright") || normalized.contains("drm") {
            return "This media is protected and can’t be downloaded by Harbor."
        }

        if normalized.contains("requested format is not available")
            || normalized.contains("no video formats found")
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

private extension NSLock {
    nonisolated func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
