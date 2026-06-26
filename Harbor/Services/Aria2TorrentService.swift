import Foundation
import Darwin
import OSLog

enum TorrentEngineError: LocalizedError {
    case binaryNotFound
    case startupFailed(String)
    case invalidSource
    case invalidResponse
    case rpc(String)

    var errorDescription: String? {
        switch self {
        case .binaryNotFound:
            "Torrent support requires aria2c. \(Aria2BinaryResolver.installHint)"
        case let .startupFailed(message):
            "Couldn’t start the torrent engine. \(message)"
        case .invalidSource:
            "This download source isn’t valid for the torrent engine."
        case .invalidResponse:
            "The torrent engine returned an invalid response."
        case let .rpc(message):
            message
        }
    }
}

struct TorrentStatusSnapshot: Sendable {
    let gid: String
    let status: String
    let totalLength: Int64
    let completedLength: Int64
    let downloadSpeed: Double
    let uploadSpeed: Double
    let errorMessage: String?
    let metadataName: String?
    let primaryPath: String?
}

actor Aria2TorrentService {
    private struct RPCEnvelope<Result: Decodable>: Decodable {
        let result: Result?
        let error: RPCFailure?
    }

    private struct RPCFailure: Decodable {
        let code: Int
        let message: String
    }

    private struct VersionPayload: Decodable {
        let version: String
    }

    private struct StatusPayload: Decodable {
        let gid: String
        let status: String
        let totalLength: String?
        let completedLength: String?
        let downloadSpeed: String?
        let uploadSpeed: String?
        let errorMessage: String?
        let files: [FilePayload]?
        let bittorrent: BittorrentPayload?
    }

    private struct FilePayload: Decodable {
        let path: String?
        let selected: String?
    }

    private struct BittorrentPayload: Decodable {
        let info: InfoPayload?
    }

    private struct InfoPayload: Decodable {
        let name: String?
    }

    private struct RunningDaemon {
        let pid: pid_t
        let parentPID: pid_t
        let command: String
    }

    nonisolated private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Harbor",
        category: "TorrentEngine"
    )

    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 10
        return URLSession(configuration: configuration)
    }()

    private var process: Process?
    private var rpcPort: Int?
    private var rpcSecret: String?
    private var stderrPipe: Pipe?
    private var transferSettings: DownloadTransferSettings

    init(transferSettings: DownloadTransferSettings = .default) {
        self.transferSettings = transferSettings
    }

    deinit {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process, process.isRunning {
            terminateDaemonProcess(process)
        }
    }

    func resolvedBinaryPath() -> String? {
        Aria2BinaryResolver.resolveBinaryURL()?.path
    }

    func updateTransferSettings(
        _ transferSettings: DownloadTransferSettings,
        activeGIDs: [String]
    ) async {
        self.transferSettings = transferSettings

        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            return
        }

        do {
            try await applyGlobalOptions(transferSettings)

            for gid in activeGIDs {
                try? await applyDownloadOptions(transferSettings, gid: gid)
            }
        } catch {
            logger.warning("Failed to update aria2 transfer settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func shutdown() {
        resetDaemon(terminateIfRunning: true)
    }

    func addDownload(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        destinationFolderPath: String
    ) async throws -> String {
        logger.info("Starting torrent add request for source kind \(String(describing: sourceKind), privacy: .public)")
        try await ensureDaemonRunning()

        let options = downloadOptions(destinationFolderPath: destinationFolderPath)

        switch sourceKind {
        case .magnetLink:
            let gid = try await rpcCallWithDaemonRestart(
                method: "aria2.addUri",
                params: {
                    [
                        try authorizedToken(),
                        [sourceURL.absoluteString],
                        options
                    ]
                },
                as: String.self
            )
            logger.info("aria2 accepted magnet download with gid \(gid, privacy: .public)")
            return gid
        case .torrentFile:
            let torrentData = try Data(contentsOf: sourceURL)
            let gid = try await rpcCallWithDaemonRestart(
                method: "aria2.addTorrent",
                params: {
                    [
                        try authorizedToken(),
                        torrentData.base64EncodedString(),
                        [],
                        options
                    ]
                },
                as: String.self
            )
            logger.info("aria2 accepted torrent file with gid \(gid, privacy: .public)")
            return gid
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }
    }

    func pause(gid: String) async throws {
        _ = try await rpcCallWithDaemonRestart(
            method: "aria2.forcePause",
            params: {
                [
                    try authorizedToken(),
                    gid
                ]
            },
            as: String.self
        )
    }

    func unpause(gid: String) async throws {
        _ = try await rpcCallWithDaemonRestart(
            method: "aria2.unpause",
            params: {
                [
                    try authorizedToken(),
                    gid
                ]
            },
            as: String.self
        )
    }

    func remove(gid: String) async {
        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil,
              let token = try? authorizedToken() else {
            return
        }

        _ = try? await rpcCall(method: "aria2.forceRemove", params: [
            token,
            gid
        ], as: String.self)
        _ = try? await rpcCall(method: "aria2.removeDownloadResult", params: [
            token,
            gid
        ], as: String.self)
    }

    func status(for gid: String) async throws -> TorrentStatusSnapshot {
        let payload = try await rpcCallWithDaemonRestart(
            method: "aria2.tellStatus",
            params: {
                [
                    try authorizedToken(),
                    gid,
                    [
                        "gid",
                        "status",
                        "totalLength",
                        "completedLength",
                        "downloadSpeed",
                        "uploadSpeed",
                        "errorMessage",
                        "files",
                        "bittorrent"
                    ]
                ]
            },
            as: StatusPayload.self
        )

        let filePaths = payload.files?
            .compactMap(\.path)
            .filter { $0.isEmpty == false } ?? []

        return TorrentStatusSnapshot(
            gid: payload.gid,
            status: payload.status,
            totalLength: Int64(payload.totalLength ?? "") ?? 0,
            completedLength: Int64(payload.completedLength ?? "") ?? 0,
            downloadSpeed: Double(payload.downloadSpeed ?? "") ?? 0,
            uploadSpeed: Double(payload.uploadSpeed ?? "") ?? 0,
            errorMessage: payload.errorMessage,
            metadataName: payload.bittorrent?.info?.name,
            primaryPath: preferredPath(from: filePaths)
        )
    }

    private func ensureDaemonRunning() async throws {
        if let process, process.isRunning, rpcPort != nil, rpcSecret != nil {
            return
        }

        if process != nil || rpcPort != nil || rpcSecret != nil || stderrPipe != nil {
            resetDaemon(terminateIfRunning: process?.isRunning == true)
        }

        guard let binaryURL = Aria2BinaryResolver.resolveBinaryURL() else {
            throw TorrentEngineError.binaryNotFound
        }

        terminateOrphanedDaemons(matching: binaryURL)
        logger.info("Launching aria2 from \(binaryURL.path, privacy: .public)")

        let port = Int.random(in: 18_000 ... 28_000)
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(port)",
            "--rpc-secret=\(secret)",
            "--seed-time=0",
            "--bt-save-metadata=true",
            "--follow-torrent=true",
            "--allow-overwrite=false",
            "--auto-file-renaming=true",
            "--summary-interval=0",
            "--max-concurrent-downloads=\(transferSettings.maxConcurrentDownloads)",
            "--max-overall-download-limit=\(aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond))",
            "--max-download-limit=\(aria2LimitString(transferSettings.perDownloadSpeedLimitBytesPerSecond))",
            "--max-connection-per-server=\(transferSettings.perDownloadConnectionCount)",
            "--split=\(transferSettings.perDownloadConnectionCount)",
            "--check-certificate=true",
            "--console-log-level=notice"
        ]
        process.standardOutput = Pipe()
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        installReadabilityHandler(for: stderrPipe)

        do {
            try process.run()
        } catch {
            logger.error("Failed to launch aria2: \(error.localizedDescription, privacy: .public)")
            throw TorrentEngineError.startupFailed(error.localizedDescription)
        }

        self.process = process
        self.rpcPort = port
        self.rpcSecret = secret
        self.stderrPipe = stderrPipe
        logger.info("aria2 process started on RPC port \(port, privacy: .public)")

        for _ in 0 ..< 20 {
            if process.isRunning == false {
                logger.error("aria2 exited before RPC became available")
                resetDaemon(terminateIfRunning: false)
                throw TorrentEngineError.startupFailed("aria2c exited before opening RPC.")
            }

            do {
                _ = try await rpcCall(method: "aria2.getVersion", params: [
                    authorizedToken()
                ], as: VersionPayload.self)
                try await applyGlobalOptions(transferSettings)
                logger.info("aria2 RPC is ready")
                return
            } catch {
                logger.debug("aria2 RPC not ready yet: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        logger.error("Timed out waiting for aria2 RPC readiness")
        resetDaemon(terminateIfRunning: true)
        throw TorrentEngineError.startupFailed("Timed out waiting for aria2 RPC.")
    }

    private func rpcURL() throws -> URL {
        guard let rpcPort else {
            throw TorrentEngineError.invalidResponse
        }

        return URL(string: "http://127.0.0.1:\(rpcPort)/jsonrpc")!
    }

    private func authorizedToken() throws -> String {
        guard let rpcSecret else {
            throw TorrentEngineError.invalidResponse
        }

        return "token:\(rpcSecret)"
    }

    private func downloadOptions(destinationFolderPath: String) -> [String: String] {
        var options = [
            "dir": destinationFolderPath,
            "continue": "true",
            "pause": "false"
        ]

        perDownloadOptions(transferSettings).forEach { key, value in
            options[key] = value
        }

        return options
    }

    private func globalOptions(_ transferSettings: DownloadTransferSettings) -> [String: String] {
        [
            "max-concurrent-downloads": "\(transferSettings.maxConcurrentDownloads)",
            "max-overall-download-limit": aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond)
        ]
    }

    private func perDownloadOptions(_ transferSettings: DownloadTransferSettings) -> [String: String] {
        [
            "max-download-limit": aria2LimitString(transferSettings.perDownloadSpeedLimitBytesPerSecond),
            "max-connection-per-server": "\(transferSettings.perDownloadConnectionCount)",
            "split": "\(transferSettings.perDownloadConnectionCount)"
        ]
    }

    private func applyGlobalOptions(_ transferSettings: DownloadTransferSettings) async throws {
        _ = try await rpcCall(method: "aria2.changeGlobalOption", params: [
            authorizedToken(),
            globalOptions(transferSettings)
        ], as: String.self)
    }

    private func applyDownloadOptions(
        _ transferSettings: DownloadTransferSettings,
        gid: String
    ) async throws {
        _ = try await rpcCall(method: "aria2.changeOption", params: [
            authorizedToken(),
            gid,
            perDownloadOptions(transferSettings)
        ], as: String.self)
    }

    private func aria2LimitString(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else {
            return "0"
        }

        return "\(max(bytesPerSecond, 0))"
    }

    private func rpcCallWithDaemonRestart<Result: Decodable>(
        method: String,
        params makeParams: () throws -> [Any],
        as type: Result.Type
    ) async throws -> Result {
        try await ensureDaemonRunning()

        do {
            return try await rpcCall(method: method, params: try makeParams(), as: type)
        } catch {
            guard shouldRestartDaemon(after: error) else {
                throw error
            }

            logger.warning("Restarting aria2 after RPC failure: \(error.localizedDescription, privacy: .public)")
            resetDaemon(terminateIfRunning: true)
            try await ensureDaemonRunning()
            return try await rpcCall(method: method, params: try makeParams(), as: type)
        }
    }

    private func rpcCall<Result: Decodable>(
        method: String,
        params: [Any],
        as type: Result.Type
    ) async throws -> Result {
        let body: [String: Any] = [
            "jsonrpc": "2.0",
            "id": UUID().uuidString,
            "method": method,
            "params": params
        ]

        var request = URLRequest(url: try rpcURL())
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 5

        let (data, _) = try await session.data(for: request)
        let envelope = try JSONDecoder().decode(RPCEnvelope<Result>.self, from: data)

        if let error = envelope.error {
            throw TorrentEngineError.rpc(error.message)
        }

        guard let result = envelope.result else {
            throw TorrentEngineError.invalidResponse
        }

        return result
    }

    private func shouldRestartDaemon(after error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut,
                 .cannotConnectToHost,
                 .cannotFindHost,
                 .networkConnectionLost,
                 .notConnectedToInternet:
                return true
            default:
                return false
            }
        }

        if case TorrentEngineError.invalidResponse = error {
            return true
        }

        return false
    }

    private func resetDaemon(terminateIfRunning: Bool) {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if terminateIfRunning,
           let process,
           process.isRunning {
            terminateDaemonProcess(process)
        }

        process = nil
        rpcPort = nil
        rpcSecret = nil
        stderrPipe = nil
    }

    private nonisolated func terminateDaemonProcess(_ process: Process) {
        process.terminate()

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            logger.warning("Force killing aria2 daemon with pid \(process.processIdentifier, privacy: .public)")
            _ = kill(process.processIdentifier, SIGKILL)
        }
    }

    private func terminateOrphanedDaemons(matching binaryURL: URL) {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let binaryPath = binaryURL.path

        for daemon in runningDaemons(matching: binaryPath) {
            guard daemon.parentPID == 1,
                  daemon.pid != currentPID,
                  process?.processIdentifier != daemon.pid else {
                continue
            }

            logger.warning("Terminating orphaned aria2 daemon with pid \(daemon.pid, privacy: .public)")
            _ = kill(daemon.pid, SIGTERM)
        }
    }

    private func runningDaemons(matching binaryPath: String) -> [RunningDaemon] {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.warning("Could not inspect aria2 processes: \(error.localizedDescription, privacy: .public)")
            return []
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            return []
        }

        guard let output = String(data: data, encoding: .utf8) else {
            return []
        }

        return output
            .split(separator: "\n")
            .compactMap { line in
                daemon(from: String(line), binaryPath: binaryPath)
            }
    }

    private func daemon(from processLine: String, binaryPath: String) -> RunningDaemon? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)

        guard parts.count == 3,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]) else {
            return nil
        }

        let command = String(parts[2])
        guard command.contains("--enable-rpc=true"),
              isHarborManagedDaemon(command: command, binaryPath: binaryPath) else {
            return nil
        }

        // TODO: Replace process-list cleanup with a persisted daemon lock if Harbor later supports multiple concurrent app instances.
        return RunningDaemon(pid: pid, parentPID: parentPID, command: command)
    }

    private func isHarborManagedDaemon(command: String, binaryPath: String) -> Bool {
        command.hasPrefix(binaryPath)
            || (
                command.contains("/Harbor.app/Contents/Resources/TorrentRuntime/")
                    && command.contains("/bin/aria2c")
            )
    }

    private nonisolated func installReadabilityHandler(for pipe: Pipe) {
        let logger = self.logger
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  output.isEmpty == false else {
                return
            }

            logger.notice("aria2: \(output, privacy: .public)")
        }
    }

    private func preferredPath(from filePaths: [String]) -> String? {
        guard filePaths.isEmpty == false else {
            return nil
        }

        if filePaths.count == 1 {
            return filePaths[0]
        }

        let splitComponents = filePaths.map {
            URL(fileURLWithPath: $0).pathComponents
        }

        guard var sharedComponents = splitComponents.first else {
            return filePaths[0]
        }

        for components in splitComponents.dropFirst() {
            while sharedComponents.isEmpty == false,
                  components.starts(with: sharedComponents) == false {
                sharedComponents.removeLast()
            }
        }

        guard sharedComponents.isEmpty == false else {
            return URL(fileURLWithPath: filePaths[0]).deletingLastPathComponent().path
        }

        let commonPath = NSString.path(withComponents: sharedComponents)
        return commonPath.isEmpty ? filePaths[0] : commonPath
    }
}
