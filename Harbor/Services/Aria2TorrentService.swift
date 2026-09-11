import Foundation
import Darwin
import OSLog

enum TorrentEngineError: LocalizedError {
    case binaryNotFound
    case startupFailed(String)
    case invalidSource
    case invalidResponse
    case rpc(String)
    case networkInterfaceUnavailable(String)

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
        case let .networkInterfaceUnavailable(displayName):
            """
            Harbor can’t transfer torrents because the network \(displayName) \
            isn’t available. Reconnect it, or choose a different network \
            interface in Settings › Torrents.
            """
        }
    }
}

struct TorrentSubmissionUncertainError: LocalizedError, Sendable {
    let gid: String
    let detail: String

    init(gid: String, underlyingError: Error) {
        self.gid = gid
        self.detail = underlyingError.localizedDescription
    }

    var errorDescription: String? {
        "Harbor submitted torrent \(gid), but could not confirm its recovery state: \(detail)"
    }
}

struct TorrentUnpauseUncertainError: LocalizedError, Sendable {
    let gid: String
    let detail: String

    init(gid: String, underlyingError: Error) {
        self.gid = gid
        self.detail = underlyingError.localizedDescription
    }

    var errorDescription: String? {
        "Harbor could not confirm whether torrent \(gid) resumed: \(detail)"
    }
}

struct TorrentStatusSnapshot: Sendable {
    let gid: String
    let status: String
    let totalLength: Int64
    let completedLength: Int64
    let uploadLength: Int64
    let downloadSpeed: Double
    let uploadSpeed: Double
    let isSeeder: Bool
    let infoHash: String?
    let errorMessage: String?
    let metadataName: String?
    let filePaths: [String]
    let primaryPath: String?
    let followedBy: [String]
    let following: String?

    nonisolated var isMetadataDownload: Bool {
        filePaths.contains { path in
            URL(fileURLWithPath: path).lastPathComponent.hasPrefix("[METADATA]")
        }
    }
}

struct TorrentStatusLineage: Sendable {
    let rootGID: String
    let gids: [String]
    let currentSnapshot: TorrentStatusSnapshot

    nonisolated var isMetadataOnly: Bool {
        gids.count == 1 && currentSnapshot.isMetadataDownload
    }
}

struct TorrentTransferOptions: Equatable, Sendable {
    let downloadLimitBytesPerSecond: Int64?
    let uploadLimitBytesPerSecond: Int64?
    let shouldSeed: Bool
    let seedRatioLimit: Double?
    let verifyExistingData: Bool
    let selectedFileIndexes: [Int]?
    let existingDataPath: String?

    init(
        downloadLimitBytesPerSecond: Int64?,
        uploadLimitBytesPerSecond: Int64?,
        shouldSeed: Bool,
        seedRatioLimit: Double? = nil,
        verifyExistingData: Bool = false,
        selectedFileIndexes: [Int]? = nil,
        existingDataPath: String? = nil
    ) {
        self.downloadLimitBytesPerSecond = downloadLimitBytesPerSecond
        self.uploadLimitBytesPerSecond = uploadLimitBytesPerSecond
        self.shouldSeed = shouldSeed
        self.seedRatioLimit = seedRatioLimit
        self.verifyExistingData = verifyExistingData
        self.selectedFileIndexes = selectedFileIndexes
        self.existingDataPath = existingDataPath
    }
}

private enum TorrentPreviewError: LocalizedError {
    case invalidMagnet
    case metadataUnavailable(String?)
    case fingerprintMismatch

    var errorDescription: String? {
        switch self {
        case .invalidMagnet:
            "The magnet link does not include a supported BitTorrent info hash."
        case let .metadataUnavailable(detail):
            detail ?? "Harbor could not resolve metadata for this magnet link."
        case .fingerprintMismatch:
            "The resolved torrent metadata does not match the magnet link."
        }
    }
}

final class TorrentEngineLogBuffer: @unchecked Sendable {
    nonisolated private let lock = NSLock()
    nonisolated private let maximumCharacterCount: Int
    nonisolated(unsafe) private var output = ""
    nonisolated(unsafe) private var isCapturing = true

    nonisolated init(maximumCharacterCount: Int = 262_144) {
        self.maximumCharacterCount = max(maximumCharacterCount, 0)
    }

    nonisolated func reset() {
        lock.lock()
        output = ""
        isCapturing = true
        lock.unlock()
    }

    nonisolated func append(_ value: String) {
        lock.lock()
        guard isCapturing, maximumCharacterCount > 0 else {
            lock.unlock()
            return
        }
        output.append(value)
        output.append("\n")
        if output.count > maximumCharacterCount {
            output.removeFirst(output.count - maximumCharacterCount)
        }
        lock.unlock()
    }

    nonisolated func stopCapturing() {
        lock.lock()
        output = ""
        isCapturing = false
        lock.unlock()
    }

    nonisolated func snapshot() -> String {
        lock.lock()
        defer { lock.unlock() }
        return output
    }
}

actor Aria2TorrentService {
    typealias DaemonStartupOperation = @Sendable (Aria2TorrentService) async throws -> Void

    private struct DaemonStartupState {
        let identifier: UUID
        let task: Task<Void, Error>
    }

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

    private struct GIDPayload: Decodable {
        let gid: String
    }

    private struct StatusPayload: Decodable {
        let gid: String
        let status: String
        let totalLength: String?
        let completedLength: String?
        let uploadLength: String?
        let downloadSpeed: String?
        let uploadSpeed: String?
        let seeder: String?
        let infoHash: String?
        let errorMessage: String?
        let files: [FilePayload]?
        let bittorrent: BittorrentPayload?
        let followedBy: [String]?
        let following: String?
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
        let startSignature: String
        let command: String
    }

    private struct DaemonOwnershipManifest: Codable {
        static let currentVersion = 1

        let version: Int
        let pid: pid_t
        let binaryPath: String
        let sessionFilePath: String
        let rpcPort: Int
        let startSignature: String

        init(
            pid: pid_t,
            binaryPath: String,
            sessionFilePath: String,
            rpcPort: Int,
            startSignature: String
        ) {
            self.version = Self.currentVersion
            self.pid = pid
            self.binaryPath = binaryPath
            self.sessionFilePath = sessionFilePath
            self.rpcPort = rpcPort
            self.startSignature = startSignature
        }
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
    private var isDaemonReady = false
    private var daemonStartupState: DaemonStartupState?
    private let daemonStartupOperation: DaemonStartupOperation
    private let startupLogBuffer = TorrentEngineLogBuffer()
    private var transferSettings: DownloadTransferSettings
    private var networkBinding: NetworkBindingStatus = .unrestricted
    private var isRetryingAfterSessionRecovery = false

    init(
        transferSettings: DownloadTransferSettings = .default,
        daemonStartupOperation: DaemonStartupOperation? = nil
    ) {
        self.transferSettings = transferSettings
        self.daemonStartupOperation = daemonStartupOperation ?? { service in
            try await service.startDaemonUntilReady()
        }
    }

    deinit {
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        if let process {
            let didStop = process.isRunning
                ? terminateDaemonProcess(process)
                : true
            if didStop {
                discardDaemonOwnershipManifest()
            }
        }
    }

    func resolvedBinaryPath() -> String? {
        Aria2BinaryResolver.resolveBinaryURL()?.path
    }

    /// aria2 fixes `--interface` at launch and caches the address it resolves
    /// to, so a changed binding can only be applied by restarting the daemon.
    func setNetworkBinding(_ networkBinding: NetworkBindingStatus) async {
        guard self.networkBinding != networkBinding else {
            return
        }
        self.networkBinding = networkBinding

        guard let process, process.isRunning else {
            return
        }

        // Persist first so the restart, or the refusal to restart while the
        // interface is gone, keeps every torrent recoverable.
        try? await saveSession()
        resetDaemon(terminateIfRunning: true)
    }

    func updateTransferSettings(
        _ transferSettings: DownloadTransferSettings,
        activeGIDs: [String],
        transferOptionsByGID: [String: TorrentTransferOptions] = [:]
    ) async {
        self.transferSettings = transferSettings

        guard isDaemonReady,
              process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            return
        }

        do {
            try await applyGlobalOptions(transferSettings)

            for rootGID in activeGIDs {
                let lineage = try? await followedStatus(for: rootGID)
                let gid = lineage?.currentSnapshot.gid ?? rootGID
                try? await applyDownloadOptions(
                    transferSettings,
                    transferOptions: transferOptionsByGID[rootGID],
                    gid: gid
                )
            }

            await persistSessionAfterMutation("transfer settings update")
        } catch {
            logger.warning("Failed to update aria2 transfer settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    func saveSession() async throws {
        if let daemonStartupState {
            try await awaitDaemonStartup(daemonStartupState)
        }
        guard isDaemonReady,
              process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            throw TorrentEngineError.rpc(
                "The torrent engine stopped before its recovery session could be saved."
            )
        }

        _ = try await rpcCall(method: "aria2.saveSession", params: [
            authorizedToken()
        ], as: String.self)
    }

    func allKnownGIDs() async throws -> Set<String> {
        try await ensureDaemonRunning()
        let token = try authorizedToken()
        let active = try await rpcCall(
            method: "aria2.tellActive",
            params: [token, ["gid"]],
            as: [GIDPayload].self
        )
        let waiting = try await rpcCall(
            method: "aria2.tellWaiting",
            params: [token, 0, 1_000, ["gid"]],
            as: [GIDPayload].self
        )
        let stopped = try await rpcCall(
            method: "aria2.tellStopped",
            params: [token, 0, 1_000, ["gid"]],
            as: [GIDPayload].self
        )

        return Set((active + waiting + stopped).map(\.gid))
    }

    func shutdown() async throws {
        if let daemonStartupState {
            try await awaitDaemonStartup(daemonStartupState)
        }
        guard let process, process.isRunning else {
            if self.process == nil {
                // A previous termination escalation may have dropped the
                // in-memory Process while deliberately retaining its durable
                // ownership marker. Do not approve app termination until that
                // exact persisted owner is confirmed gone.
                try terminatePersistedOwnedDaemonIfNeeded()
            }
            resetDaemon(terminateIfRunning: false)
            return
        }
        guard rpcPort != nil, rpcSecret != nil else {
            throw TorrentEngineError.rpc(
                "The torrent engine is still running, but Harbor cannot save its recovery session."
            )
        }

        // Do not terminate the only in-memory owner of current torrent state
        // until aria2 confirms that its recovery session is durable. The app
        // delegate can then refuse termination and let the user retry instead
        // of silently accepting a stale session file.
        try await saveSession()

        do {
            _ = try await rpcCall(method: "aria2.shutdown", params: [
                authorizedToken()
            ], as: String.self)

            for _ in 0 ..< 20 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
        } catch {
            logger.warning("Failed to gracefully shut down aria2: \(error.localizedDescription, privacy: .public)")
        }

        if process.isRunning {
            terminateDaemonProcess(process)
        }
        guard process.isRunning == false else {
            throw TorrentEngineError.rpc(
                "Harbor could not confirm that the torrent engine stopped before quitting."
            )
        }
        resetDaemon(terminateIfRunning: false)
    }

    func addDownload(
        sourceKind: DownloadSourceKind,
        sourceURL: URL,
        destinationFolderPath: String,
        requestHeaders: [RequestHeader],
        transferOptions: TorrentTransferOptions? = nil
    ) async throws -> String {
        logger.info("Starting torrent add request for source kind \(String(describing: sourceKind), privacy: .public)")
        let torrentData: Data?
        switch sourceKind {
        case .magnetLink:
            torrentData = nil
        case .torrentFile:
            torrentData = try ManagedTorrentSourceStore.loadTorrentData(at: sourceURL)
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }
        let gid = Self.makeSubmissionGID()
        try await ensureDaemonRunning()

        var options = downloadOptions(
            destinationFolderPath: destinationFolderPath,
            requestHeaders: requestHeaders,
            transferOptions: transferOptions
        )
        options["gid"] = gid
        if let existingDataPath = transferOptions?.existingDataPath, let torrentData {
            let mapping = try TorrentCheckPathMapping.resolve(metainfo: torrentData, existingDataPath: existingDataPath)
            options["dir"] = mapping.directoryURL.path
            options["index-out"] = mapping.indexOut
            options["check-integrity"] = "true"
            options["allow-overwrite"] = "false"
            options["auto-file-renaming"] = "false"
        }

        let returnedGID: String
        try Task.checkCancellation()
        switch sourceKind {
        case .magnetLink:
            returnedGID = try await submitDownload(
                method: "aria2.addUri",
                params: [
                    authorizedToken(),
                    [sourceURL.absoluteString],
                    options
                ],
                gid: gid
            )
        case .torrentFile:
            guard let torrentData else {
                throw TorrentEngineError.invalidSource
            }
            returnedGID = try await submitDownload(
                method: "aria2.addTorrent",
                params: [
                    authorizedToken(),
                    torrentData.base64EncodedString(),
                    [],
                    options
                ],
                gid: gid
            )
        case .directURL, .mediaURL:
            throw TorrentEngineError.invalidSource
        }
        guard returnedGID == gid else {
            // The add request may still have committed under the caller-owned
            // reserved GID. Treat a contradictory response as uncertain
            // ownership so the model keeps that GID slot-occupying instead of
            // declaring failure while aria2 may be writing in the background.
            throw TorrentSubmissionUncertainError(
                gid: gid,
                underlyingError: TorrentEngineError.invalidResponse
            )
        }
        // A successful add is not handed to the model until aria confirms the
        // session file contains it.
        do {
            try await saveSession()
        } catch {
            throw TorrentSubmissionUncertainError(
                gid: returnedGID,
                underlyingError: error
            )
        }
        logger.info("aria2 accepted torrent with reserved gid \(returnedGID, privacy: .public)")
        return returnedGID
    }

    func previewMagnetMetainfo(
        at sourceURL: URL,
        requestHeaders: [RequestHeader]
    ) async throws -> Data {
        guard let expectedInfoHash = ManagedTorrentSourceStore.normalizedInfoHash(
            MagnetLinkMetadata(url: sourceURL).infoHash
        ) else {
            throw TorrentPreviewError.invalidMagnet
        }

        let previewDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborTorrentPreview", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: previewDirectory,
            withIntermediateDirectories: true
        )

        let gid = Self.makeSubmissionGID()
        do {
            try await ensureDaemonRunning()
            var options: [String: Any] = [
                "gid": gid,
                "dir": previewDirectory.path,
                "pause": "false",
                "pause-metadata": "true",
                "bt-metadata-only": "true",
                "bt-save-metadata": "true",
                "seed-time": "0"
            ]
            if requestHeaders.isEmpty == false {
                options["header"] = requestHeaders.map(\.aria2HeaderValue)
            }
            let returnedGID = try await submitDownload(
                method: "aria2.addUri",
                params: [
                    authorizedToken(),
                    [sourceURL.absoluteString],
                    options
                ],
                gid: gid
            )
            guard returnedGID == gid else {
                throw TorrentEngineError.invalidResponse
            }

            let expectedMetadataURL = previewDirectory
                .appendingPathComponent("\(expectedInfoHash).torrent", isDirectory: false)

            while true {
                try Task.checkCancellation()

                let metadataURL: URL? = if FileManager.default.fileExists(
                    atPath: expectedMetadataURL.path
                ) {
                    expectedMetadataURL
                } else {
                    try FileManager.default.contentsOfDirectory(
                        at: previewDirectory,
                        includingPropertiesForKeys: nil
                    ).first { $0.pathExtension.lowercased() == "torrent" }
                }

                if let metadataURL {
                    let data = try ManagedTorrentSourceStore.loadTorrentData(at: metadataURL)
                    let preview = try TorrentMetainfoParser.preview(from: data)
                    guard preview.infoHash == expectedInfoHash else {
                        throw TorrentPreviewError.fingerprintMismatch
                    }
                    await cleanupTorrentPreview(gid: gid, directoryURL: previewDirectory)
                    return data
                }

                let snapshot = try await status(for: gid)
                if snapshot.status == "error" || snapshot.status == "removed" {
                    throw TorrentPreviewError.metadataUnavailable(snapshot.errorMessage)
                }

                try await Task.sleep(for: .milliseconds(250))
            }
        } catch {
            await cleanupTorrentPreview(gid: gid, directoryURL: previewDirectory)
            throw error
        }
    }

    private func cleanupTorrentPreview(gid: String, directoryURL: URL) async {
        // A fresh task does not inherit caller cancellation, so a dismissed
        // selector still removes its temporary aria2 job and durable session entry.
        let cleanupTask = Task {
            try? await removeAndConfirmStopped(gid: gid)
        }
        await cleanupTask.value
        try? FileManager.default.removeItem(at: directoryURL)
    }

    func pause(gid: String) async throws {
        let lineage = try await followedStatus(for: gid)
        guard lineage.currentSnapshot.status == "active"
                || lineage.currentSnapshot.status == "waiting" else {
            return
        }
        let currentGID = lineage.currentSnapshot.gid
        _ = try await rpcCallWithDaemonRestart(
            method: "aria2.forcePause",
            params: {
                [
                    try authorizedToken(),
                    currentGID
                ]
            },
            as: String.self
        )
        try await saveSession()
    }

    func unpause(gid: String) async throws {
        let lineage = try await followedStatus(for: gid)
        let currentGID = lineage.currentSnapshot.gid
        do {
            _ = try await rpcCall(
                method: "aria2.unpause",
                params: [authorizedToken(), currentGID],
                as: String.self
            )
            try await saveSession()
            return
        } catch {
            let originalError = error
            var lastProbeError: Error?
            var lastObservedStatus: String?

            for delay in [Duration.zero, .milliseconds(150), .milliseconds(500)] {
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                do {
                    let snapshot = try await followedStatus(for: gid)
                    let currentStatus = snapshot.currentSnapshot.status
                    lastObservedStatus = currentStatus
                    lastProbeError = nil
                    if currentStatus == "active" || currentStatus == "waiting" {
                        do {
                            try await saveSession()
                        } catch {
                            throw TorrentUnpauseUncertainError(
                                gid: gid,
                                underlyingError: error
                            )
                        }
                        return
                    }
                } catch let uncertain as TorrentUnpauseUncertainError {
                    throw uncertain
                } catch {
                    lastProbeError = error
                }
            }

            if lastProbeError == nil,
               lastObservedStatus == "paused",
               Self.mutationFailureWasExplicitlyRejected(originalError) {
                throw originalError
            }
            throw TorrentUnpauseUncertainError(
                gid: gid,
                underlyingError: lastProbeError ?? originalError
            )
        }
    }

    func remove(gid: String) async {
        guard process?.isRunning == true,
              rpcPort != nil,
              rpcSecret != nil else {
            return
        }

        let lineage = try? await followedStatus(for: gid)
        guard let token = try? authorizedToken() else {
            return
        }
        let gids = lineage?.gids.reversed() ?? [gid].reversed()
        var didRemove = false

        for targetGID in gids {
            didRemove = await removeSingle(gid: targetGID, token: token) || didRemove
        }

        if didRemove {
            await persistSessionAfterMutation("remove")
        }
    }

    func removeAndConfirmStopped(gid: String) async throws {
        try await ensureDaemonRunning()
        let gids: [String]
        do {
            gids = Array(try await followedStatus(for: gid).gids.reversed())
        } catch {
            guard isMissingGIDError(error) else {
                // A transient lineage lookup must not be treated as proof that
                // removing only the root GID stopped a followed magnet payload.
                throw error
            }
            gids = [gid]
        }
        // followedStatus may restart the daemon and rotate its RPC secret.
        // Resolve authorization only after lineage discovery has settled.
        let token = try authorizedToken()

        for targetGID in gids {
            try await removeSingleAndConfirmStopped(gid: targetGID, token: token)
        }

        // A confirmed runtime removal is not durable until aria2 rewrites its
        // session. Propagate this failure so the owning record retains the GID
        // and cleanup can be retried safely.
        try await saveSession()
    }

    private func removeSingle(gid: String, token: String) async -> Bool {
        var didRemove = false

        do {
            _ = try await rpcCall(method: "aria2.forceRemove", params: [
                token,
                gid
            ], as: String.self)
            didRemove = true
        } catch {
            logger.debug("aria2 forceRemove did not remove gid \(gid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        do {
            _ = try await rpcCall(method: "aria2.removeDownloadResult", params: [
                token,
                gid
            ], as: String.self)
            didRemove = true
        } catch {
            logger.debug("aria2 removeDownloadResult did not remove gid \(gid, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }

        return didRemove
    }

    private func removeSingleAndConfirmStopped(gid: String, token: String) async throws {
        do {
            _ = try await rpcCall(method: "aria2.forceRemove", params: [
                token,
                gid
            ], as: String.self)
        } catch {
            do {
                let snapshot = try await status(for: gid)
                if snapshot.status == "active"
                    || snapshot.status == "waiting"
                    || snapshot.status == "paused" {
                    throw error
                }
            } catch let statusError {
                guard isMissingGIDError(statusError) else {
                    throw statusError
                }
            }
        }

        do {
            _ = try await rpcCall(method: "aria2.removeDownloadResult", params: [
                token,
                gid
            ], as: String.self)
        } catch {
            guard isMissingGIDError(error) else {
                throw error
            }
        }
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
                        "uploadLength",
                        "downloadSpeed",
                        "uploadSpeed",
                        "seeder",
                        "infoHash",
                        "errorMessage",
                        "files",
                        "bittorrent",
                        "followedBy",
                        "following"
                    ]
                ]
            },
            as: StatusPayload.self
        )

        let filePaths = payload.files?
            .filter { $0.selected != "false" }
            .compactMap(\.path)
            .filter { $0.isEmpty == false } ?? []

        return TorrentStatusSnapshot(
            gid: payload.gid,
            status: payload.status,
            totalLength: Int64(payload.totalLength ?? "") ?? 0,
            completedLength: Int64(payload.completedLength ?? "") ?? 0,
            uploadLength: Int64(payload.uploadLength ?? "") ?? 0,
            downloadSpeed: Double(payload.downloadSpeed ?? "") ?? 0,
            uploadSpeed: Double(payload.uploadSpeed ?? "") ?? 0,
            isSeeder: payload.seeder == "true",
            infoHash: payload.infoHash,
            errorMessage: payload.errorMessage,
            metadataName: payload.bittorrent?.info?.name,
            filePaths: filePaths,
            primaryPath: preferredPath(from: filePaths),
            followedBy: payload.followedBy ?? [],
            following: payload.following
        )
    }

    func followedStatus(for rootGID: String) async throws -> TorrentStatusLineage {
        var gids = [rootGID]
        var visited = Set(gids)
        var snapshot = try await status(for: rootGID)

        while let nextGID = snapshot.followedBy.first(where: { visited.contains($0) == false }) {
            do {
                snapshot = try await status(for: nextGID)
                gids.append(nextGID)
                visited.insert(nextGID)
            } catch {
                guard isMissingGIDError(error) else {
                    throw error
                }
                break
            }
        }

        return TorrentStatusLineage(
            rootGID: rootGID,
            gids: gids,
            currentSnapshot: snapshot
        )
    }

    private func ensureDaemonRunning() async throws {
        if isDaemonReady,
           let process,
           process.isRunning,
           rpcPort != nil,
           rpcSecret != nil {
            return
        }

        if let daemonStartupState {
            try await awaitDaemonStartup(daemonStartupState)
            return
        }

        let daemonStartupOperation = daemonStartupOperation
        let startupTask = Task { [weak self, daemonStartupOperation] in
            guard let self else {
                throw TorrentEngineError.startupFailed(
                    "The torrent engine service was released during startup."
                )
            }
            try await daemonStartupOperation(self)
        }
        let startupState = DaemonStartupState(
            identifier: UUID(),
            task: startupTask
        )
        daemonStartupState = startupState
        try await awaitDaemonStartup(startupState)
    }

    private func awaitDaemonStartup(_ startupState: DaemonStartupState) async throws {
        do {
            try await startupState.task.value
        } catch {
            if daemonStartupState?.identifier == startupState.identifier {
                isDaemonReady = false
                daemonStartupState = nil
            }
            throw error
        }

        // Any waiter can resume first after the shared task completes. Make
        // readiness publication part of the shared await instead of relying
        // on the caller that happened to create the task to run first.
        if daemonStartupState?.identifier == startupState.identifier {
            isDaemonReady = true
            daemonStartupState = nil
        }
    }

    private func startDaemonUntilReady() async throws {
        // aria2 exits immediately when --interface names a missing interface.
        // Refusing here turns that into an explanation the user can act on.
        if case let .unavailable(displayName) = networkBinding {
            throw TorrentEngineError.networkInterfaceUnavailable(displayName)
        }

        if process != nil || rpcPort != nil || rpcSecret != nil || stderrPipe != nil {
            resetDaemon(terminateIfRunning: process?.isRunning == true)
        }

        guard let binaryURL = Aria2BinaryResolver.resolveBinaryURL() else {
            throw TorrentEngineError.binaryNotFound
        }

        let sessionFileURL = try prepareSessionFile()
        try terminateOrphanedDaemons(
            matching: binaryURL,
            sessionFileURL: sessionFileURL
        )
        logger.info("Launching aria2 from \(binaryURL.path, privacy: .public)")

        let port = Int.random(in: 18_000 ... 28_000)
        let secret = UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let arguments = Self.daemonArguments(
            sessionFilePath: sessionFileURL.path,
            rpcPort: port,
            rpcSecret: secret,
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            transferSettings: transferSettings,
            networkBinding: networkBinding
        )

        let process = Process()
        process.executableURL = binaryURL
        process.arguments = arguments
        startupLogBuffer.reset()
        let stderrPipe = Pipe()
        process.standardOutput = stderrPipe
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
        do {
            try await persistDaemonOwnership(
                process: process,
                binaryURL: binaryURL,
                sessionFileURL: sessionFileURL,
                rpcPort: port
            )
        } catch {
            terminateDaemonProcess(process)
            resetDaemon(terminateIfRunning: false)
            throw TorrentEngineError.startupFailed(
                "Harbor could not durably record ownership of the torrent engine: \(error.localizedDescription)"
            )
        }
        logger.info("aria2 process started on RPC port \(port, privacy: .public)")

        for _ in 0 ..< 20 {
            if process.isRunning == false {
                logger.error("aria2 exited before RPC became available")
                resetDaemon(terminateIfRunning: false)
                if try recoverCorruptSessionIfPossible(
                    at: sessionFileURL,
                    startupOutput: startupLogBuffer.snapshot()
                ) {
                    try await startDaemonUntilReady()
                    return
                }
                throw TorrentEngineError.startupFailed("aria2c exited before opening RPC.")
            }

            do {
                _ = try await rpcCall(method: "aria2.getVersion", params: [
                    authorizedToken()
                ], as: VersionPayload.self)
                try await applyGlobalOptions(transferSettings)
                isRetryingAfterSessionRecovery = false
                isDaemonReady = true
                startupLogBuffer.stopCapturing()
                logger.info("aria2 RPC is ready")
                return
            } catch {
                logger.debug("aria2 RPC not ready yet: \(error.localizedDescription, privacy: .public)")
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        logger.error("Timed out waiting for aria2 RPC readiness")
        resetDaemon(terminateIfRunning: true)
        if try recoverCorruptSessionIfPossible(
            at: sessionFileURL,
            startupOutput: startupLogBuffer.snapshot()
        ) {
            try await startDaemonUntilReady()
            return
        }
        throw TorrentEngineError.startupFailed("Timed out waiting for aria2 RPC.")
    }

    nonisolated static func daemonArguments(
        sessionFilePath: String,
        rpcPort: Int,
        rpcSecret: String,
        hostProcessIdentifier: pid_t,
        transferSettings: DownloadTransferSettings,
        networkBinding: NetworkBindingStatus
    ) -> [String] {
        var arguments = [
            "--enable-rpc=true",
            "--rpc-listen-all=false",
            "--rpc-listen-port=\(rpcPort)",
            "--rpc-secret=\(rpcSecret)",
            "--input-file=\(sessionFilePath)",
            "--save-session=\(sessionFilePath)",
            "--save-session-interval=5",
            "--force-save=true",
            "--stop-with-process=\(hostProcessIdentifier)",
            "--bt-detach-seed-only=true",
            // Per-download options override this unlimited daemon default.
            // TODO: Add per-torrent ratio overrides if one global preference becomes too limiting.
            "--seed-ratio=0.0",
            "--bt-save-metadata=true",
            "--bt-load-saved-metadata=true",
            "--follow-torrent=true",
            "--pause=true",
            "--allow-overwrite=false",
            "--auto-file-renaming=true"
        ]
        arguments.append(contentsOf: [
            "--summary-interval=0",
            "--max-concurrent-downloads=\(transferSettings.maxConcurrentDownloads)",
            "--max-overall-download-limit=\(aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond))",
            "--max-overall-upload-limit=\(aria2LimitString(transferSettings.globalUploadSpeedLimitBytesPerSecond))",
            "--max-download-limit=\(aria2LimitString(transferSettings.perDownloadSpeedLimitBytesPerSecond))",
            "--max-upload-limit=\(aria2LimitString(transferSettings.perDownloadUploadSpeedLimitBytesPerSecond))",
            "--max-connection-per-server=\(transferSettings.perDownloadConnectionCount)",
            "--split=\(transferSettings.perDownloadConnectionCount)",
            "--check-certificate=true",
            "--console-log-level=notice"
        ])

        // Local Peer Discovery stays off by default in aria2, so --interface is
        // the only socket binding the daemon needs.
        if case let .bound(_, binding) = networkBinding {
            arguments.append("--interface=\(binding.interfaceName)")
        }

        return arguments
    }

    private func recoverCorruptSessionIfPossible(
        at sessionFileURL: URL,
        startupOutput: String
    ) throws -> Bool {
        guard isRetryingAfterSessionRecovery == false,
              Self.shouldRecoverSession(from: startupOutput),
              let attributes = try? FileManager.default.attributesOfItem(atPath: sessionFileURL.path),
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0 else {
            return false
        }

        isRetryingAfterSessionRecovery = true
        let quarantineURL = sessionFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("aria2.session.corrupt-\(UUID().uuidString)")
        try FileManager.default.moveItem(at: sessionFileURL, to: quarantineURL)
        guard FileManager.default.createFile(atPath: sessionFileURL.path, contents: Data()) else {
            throw TorrentEngineError.startupFailed(
                String(
                    localized: "torrent.session.fileRecreationFailed",
                    defaultValue: "Couldn’t recreate the torrent session file.",
                    comment: "Torrent engine startup detail shown when a corrupt session file cannot be replaced."
                )
            )
        }
        logger.warning("Recovered from an unreadable aria2 session file")
        return true
    }

    nonisolated static func shouldRecoverSession(from startupOutput: String) -> Bool {
        let output = startupOutput.lowercased()
        return output.contains("unrecognized uri or unsupported protocol")
            || output.contains("failed to parse")
            || output.contains("parse error")
            || output.contains("error while loading session")
            || output.contains("failed to load session")
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

    private func prepareSessionFile() throws -> URL {
        let fileManager = FileManager.default
        let harborDirectoryURL = HarborApplicationSupport.directoryURL(fileManager: fileManager)
        let sessionFileURL = harborDirectoryURL.appendingPathComponent(
            "aria2.session",
            isDirectory: false
        )

        do {
            try fileManager.createDirectory(
                at: harborDirectoryURL,
                withIntermediateDirectories: true
            )
        } catch {
            throw TorrentEngineError.startupFailed(
                String(
                    format: String(
                        localized: "torrent.session.directoryCreationFailed",
                        defaultValue: "Couldn’t create the torrent session directory: %@",
                        comment: "Torrent engine startup detail shown when its session directory cannot be created."
                    ),
                    error.localizedDescription
                )
            )
        }

        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: sessionFileURL.path, isDirectory: &isDirectory) {
            guard isDirectory.boolValue == false else {
                throw TorrentEngineError.startupFailed(
                    String(
                        localized: "torrent.session.pathIsDirectory",
                        defaultValue: "The torrent session path is a directory.",
                        comment: "Torrent engine startup detail shown when the session file path is occupied by a directory."
                    )
                )
            }
        } else if fileManager.createFile(atPath: sessionFileURL.path, contents: Data()) == false {
            throw TorrentEngineError.startupFailed(
                String(
                    localized: "torrent.session.fileCreationFailed",
                    defaultValue: "Couldn’t create the torrent session file.",
                    comment: "Torrent engine startup detail shown when its session file cannot be created."
                )
            )
        }

        return sessionFileURL
    }

    private func downloadOptions(
        destinationFolderPath: String,
        requestHeaders: [RequestHeader],
        transferOptions: TorrentTransferOptions?
    ) -> [String: Any] {
        let options = Self.downloadOptions(
            destinationFolderPath: destinationFolderPath,
            transferSettings: transferSettings,
            transferOptions: transferOptions
        )

        var rpcOptions = options.reduce(into: [String: Any]()) { result, option in
            result[option.key] = option.value
        }

        if requestHeaders.isEmpty == false {
            rpcOptions["header"] = requestHeaders.map(\.aria2HeaderValue)
        }

        return rpcOptions
    }

    nonisolated static func downloadOptions(
        destinationFolderPath: String,
        transferSettings: DownloadTransferSettings,
        transferOptions: TorrentTransferOptions?
    ) -> [String: String] {
        var options = [
            "dir": destinationFolderPath,
            "pause": "false"
        ]

        perDownloadOptions(
            transferSettings,
            transferOptions: transferOptions
        ).forEach { key, value in
            options[key] = value
        }

        if transferOptions?.verifyExistingData == true {
            options["check-integrity"] = "true"
            options["bt-hash-check-seed"] = "true"
            options["allow-overwrite"] = "false"
            options["auto-file-renaming"] = "false"
        }

        if let selectedFileIndexes = transferOptions?.selectedFileIndexes,
           let selection = selectFileOption(from: selectedFileIndexes) {
            options["select-file"] = selection
        }

        return options
    }

    nonisolated static func selectFileOption(from indexes: [Int]) -> String? {
        let indexes = Array(Set(indexes.filter { $0 > 0 })).sorted()
        guard let first = indexes.first else {
            return nil
        }

        var ranges: [String] = []
        var rangeStart = first
        var previous = first

        for index in indexes.dropFirst() {
            if index == previous + 1 {
                previous = index
                continue
            }
            ranges.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
            rangeStart = index
            previous = index
        }
        ranges.append(rangeStart == previous ? "\(rangeStart)" : "\(rangeStart)-\(previous)")
        return ranges.joined(separator: ",")
    }

    private func globalOptions(_ transferSettings: DownloadTransferSettings) -> [String: String] {
        [
            "max-concurrent-downloads": "\(transferSettings.maxConcurrentDownloads)",
            "max-overall-download-limit": Self.aria2LimitString(transferSettings.globalSpeedLimitBytesPerSecond),
            "max-overall-upload-limit": Self.aria2LimitString(transferSettings.globalUploadSpeedLimitBytesPerSecond)
        ]
    }

    nonisolated static func perDownloadOptions(
        _ transferSettings: DownloadTransferSettings,
        transferOptions: TorrentTransferOptions?
    ) -> [String: String] {
        let downloadLimit: Int64?
        let uploadLimit: Int64?

        if let transferOptions {
            downloadLimit = transferOptions.downloadLimitBytesPerSecond
            uploadLimit = transferOptions.uploadLimitBytesPerSecond
        } else {
            downloadLimit = transferSettings.perDownloadSpeedLimitBytesPerSecond
            uploadLimit = transferSettings.perDownloadUploadSpeedLimitBytesPerSecond
        }

        var options = [
            "max-download-limit": aria2LimitString(downloadLimit),
            "max-upload-limit": aria2LimitString(uploadLimit),
            "max-connection-per-server": "\(transferSettings.perDownloadConnectionCount)",
            "split": "\(transferSettings.perDownloadConnectionCount)"
        ]

        if let transferOptions {
            if transferOptions.shouldSeed {
                options["seed-ratio"] = aria2RatioString(transferOptions.seedRatioLimit)
            } else {
                options["seed-time"] = "0"
            }

        }

        return options
    }

    private func applyGlobalOptions(_ transferSettings: DownloadTransferSettings) async throws {
        _ = try await rpcCall(method: "aria2.changeGlobalOption", params: [
            authorizedToken(),
            globalOptions(transferSettings)
        ], as: String.self)
    }

    private func applyDownloadOptions(
        _ transferSettings: DownloadTransferSettings,
        transferOptions: TorrentTransferOptions?,
        gid: String
    ) async throws {
        _ = try await rpcCall(method: "aria2.changeOption", params: [
            authorizedToken(),
            gid,
            Self.perDownloadOptions(
                transferSettings,
                transferOptions: transferOptions
            )
        ], as: String.self)
    }

    private func persistSessionAfterMutation(_ action: String) async {
        do {
            try await saveSession()
        } catch {
            logger.warning("Failed to save aria2 session after \(action, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    nonisolated private static func aria2LimitString(_ bytesPerSecond: Int64?) -> String {
        guard let bytesPerSecond else {
            return "0"
        }

        return "\(max(bytesPerSecond, 0))"
    }

    nonisolated private static func aria2RatioString(_ ratio: Double?) -> String {
        guard let ratio, ratio.isFinite, ratio > 0 else {
            return "0.0"
        }

        return String(ratio)
    }

    private func isMissingGIDError(_ error: Error) -> Bool {
        let message = error.localizedDescription.lowercased()
        return message.contains("gid")
            && (message.contains("not found")
                || message.contains("does not exist")
                || message.contains("cannot be found"))
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

    private func submitDownload(
        method: String,
        params: [Any],
        gid: String
    ) async throws -> String {
        do {
            return try await rpcCall(
                method: method,
                params: params,
                as: String.self
            )
        } catch {
            // The request may have committed before its response was lost.
            // Never replay a non-idempotent add here. Probe the caller-chosen
            // GID; a later user retry uses the same durable reservation.
            var lastProbeError: Error?
            var lastProbeConfirmedMissing = false
            for delay in [Duration.zero, .milliseconds(150), .milliseconds(500)] {
                if delay != .zero {
                    try? await Task.sleep(for: delay)
                }
                do {
                    if try await reservedGIDExists(gid) {
                        return gid
                    }
                    lastProbeConfirmedMissing = true
                    lastProbeError = nil
                } catch {
                    lastProbeConfirmedMissing = false
                    lastProbeError = error
                }
            }
            if lastProbeConfirmedMissing,
               Self.mutationFailureWasExplicitlyRejected(error) {
                throw error
            }
            throw TorrentSubmissionUncertainError(
                gid: gid,
                underlyingError: lastProbeError ?? error
            )
        }
    }

    private static func makeSubmissionGID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16))
    }

    /// A decoded JSON-RPC error is an authoritative response from aria2 that
    /// the requested mutation was rejected. Transport failures and malformed
    /// responses remain ambiguous even if short-lived probes still show the
    /// old state: the original request can be delayed and commit afterward.
    nonisolated static func mutationFailureWasExplicitlyRejected(
        _ error: Error
    ) -> Bool {
        guard let torrentError = error as? TorrentEngineError else {
            return false
        }
        if case .rpc = torrentError {
            return true
        }
        return false
    }

    private func reservedGIDExists(_ gid: String) async throws -> Bool {
        do {
            _ = try await rpcCall(
                method: "aria2.tellStatus",
                params: [authorizedToken(), gid, ["gid"]],
                as: StatusPayload.self
            )
            return true
        } catch {
            if isMissingGIDError(error) {
                return false
            }
            throw error
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
                // A single ambiguous transport response is not evidence that
                // a live daemon is dead. Killing it can discard committed
                // mutations that have not yet reached the session file.
                return process?.isRunning != true
            default:
                return false
            }
        }

        if case TorrentEngineError.invalidResponse = error {
            return process?.isRunning != true
        }

        return false
    }

    private func resetDaemon(terminateIfRunning: Bool) {
        isDaemonReady = false
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        let ownedProcess = process
        let didConfirmOwnedProcessStopped: Bool
        if let ownedProcess {
            if terminateIfRunning, ownedProcess.isRunning {
                didConfirmOwnedProcessStopped = terminateDaemonProcess(ownedProcess)
            } else {
                didConfirmOwnedProcessStopped = ownedProcess.isRunning == false
            }
        } else {
            didConfirmOwnedProcessStopped = false
        }

        process = nil
        rpcPort = nil
        rpcSecret = nil
        stderrPipe = nil
        if didConfirmOwnedProcessStopped {
            discardDaemonOwnershipManifest()
        }
    }

    @discardableResult
    private nonisolated func terminateDaemonProcess(_ process: Process) -> Bool {
        process.terminate()

        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if process.isRunning {
            logger.warning("Force killing aria2 daemon with pid \(process.processIdentifier, privacy: .public)")
            _ = kill(process.processIdentifier, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(1)
            while process.isRunning, Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }
        return process.isRunning == false
    }

    private func terminateOrphanedDaemons(
        matching binaryURL: URL,
        sessionFileURL: URL
    ) throws {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let binaryPath = binaryURL.path
        let ownership = try daemonOwnershipManifest()
        let inspectionBinaryPath = ownership?.binaryPath ?? binaryPath
        var candidates = try runningDaemons(matching: inspectionBinaryPath).filter {
            daemonUsesHarborSession($0, sessionFileURL: sessionFileURL)
                && $0.pid != currentPID
                && process?.processIdentifier != $0.pid
        }
        if inspectionBinaryPath != binaryPath {
            candidates.append(contentsOf: try runningDaemons(matching: binaryPath).filter {
                daemonUsesHarborSession($0, sessionFileURL: sessionFileURL)
                    && $0.pid != currentPID
                    && process?.processIdentifier != $0.pid
            })
        }
        guard candidates.isEmpty == false else {
            discardDaemonOwnershipManifest()
            return
        }
        guard let ownership,
              ownership.version == DaemonOwnershipManifest.currentVersion,
              ownership.binaryPath == binaryPath,
              ownership.sessionFilePath == sessionFileURL.path,
              let daemon = candidates.first(where: {
                  $0.pid == ownership.pid
                      && $0.startSignature == ownership.startSignature
                      && $0.command.contains("--rpc-listen-port=\(ownership.rpcPort)")
              }),
              Self.isVerifiedOwnershipParent(
                  daemon.parentPID,
                  currentProcessIdentifier: currentPID
              ),
              candidates.count == 1 else {
            throw TorrentEngineError.startupFailed(
                "Harbor found an aria2 process using its session file but could not verify that Harbor owns it. The process was left running."
            )
        }

        logger.warning("Terminating verified orphaned aria2 daemon with pid \(daemon.pid, privacy: .public)")
        _ = kill(daemon.pid, SIGTERM)
        let gracefulDeadline = Date().addingTimeInterval(1)
        while try daemonStillMatches(daemon, binaryPath: binaryPath),
              Date() < gracefulDeadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        if try daemonStillMatches(daemon, binaryPath: binaryPath) {
            logger.warning("Force killing verified orphaned aria2 daemon with pid \(daemon.pid, privacy: .public)")
            _ = kill(daemon.pid, SIGKILL)
            let forcedDeadline = Date().addingTimeInterval(1)
            while try daemonStillMatches(daemon, binaryPath: binaryPath),
                  Date() < forcedDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
        }

        guard try daemonStillMatches(daemon, binaryPath: binaryPath) == false else {
            throw TorrentEngineError.startupFailed(
                "Harbor could not stop its earlier aria2 process before opening the saved session."
            )
        }
        discardDaemonOwnershipManifest()
    }

    nonisolated static func isVerifiedOwnershipParent(
        _ parentProcessIdentifier: pid_t,
        currentProcessIdentifier: pid_t
    ) -> Bool {
        parentProcessIdentifier == currentProcessIdentifier
            || parentProcessIdentifier == 1
    }

    private func terminatePersistedOwnedDaemonIfNeeded() throws {
        guard let ownership = try daemonOwnershipManifest() else {
            return
        }
        try terminateOrphanedDaemons(
            matching: URL(fileURLWithPath: ownership.binaryPath),
            sessionFileURL: URL(fileURLWithPath: ownership.sessionFilePath)
        )
    }

    private func daemonStillMatches(
        _ expected: RunningDaemon,
        binaryPath: String
    ) throws -> Bool {
        try runningDaemons(matching: binaryPath).contains { current in
            current.pid == expected.pid
                && current.startSignature == expected.startSignature
                && current.command == expected.command
        }
    }

    private func persistDaemonOwnership(
        process: Process,
        binaryURL: URL,
        sessionFileURL: URL,
        rpcPort: Int
    ) async throws {
        var verifiedDaemon: RunningDaemon?

        // Process.run() can return before the new executable is visible in a
        // separate ps snapshot. Keep every identity check exact while giving
        // macOS a short, bounded window to publish the launched process.
        for attempt in 0 ..< 20 {
            verifiedDaemon = try runningDaemon(
                processIdentifier: process.processIdentifier,
                matching: binaryURL.path
            ).flatMap { daemon in
                daemonUsesHarborSession(daemon, sessionFileURL: sessionFileURL)
                    && daemon.command.contains("--rpc-listen-port=\(rpcPort)")
                    ? daemon
                    : nil
            }
            if verifiedDaemon != nil || process.isRunning == false {
                break
            }
            if attempt < 19 {
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        // TODO: Share a direct Darwin process-identity reader with the media
        // backend if ps publication timing causes more ownership races.
        guard let daemon = verifiedDaemon else {
            throw TorrentEngineError.startupFailed(
                "Harbor could not verify the newly launched aria2 process."
            )
        }
        let manifest = DaemonOwnershipManifest(
            pid: daemon.pid,
            binaryPath: binaryURL.path,
            sessionFilePath: sessionFileURL.path,
            rpcPort: rpcPort,
            startSignature: daemon.startSignature
        )
        let url = daemonOwnershipManifestURL()
        try JSONEncoder().encode(manifest).write(to: url, options: .atomic)
        try DurableFileSystem.synchronizeFile(at: url)
        try DurableFileSystem.synchronizeParentDirectory(of: url)
    }

    private func daemonOwnershipManifest() throws -> DaemonOwnershipManifest? {
        let url = daemonOwnershipManifestURL()
        do {
            let values = try url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true else {
                throw CocoaError(.fileReadCorruptFile)
            }
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        } catch let error as POSIXError where error.code == .ENOENT {
            return nil
        }
        let manifest = try JSONDecoder().decode(
            DaemonOwnershipManifest.self,
            from: Data(contentsOf: url)
        )
        guard manifest.version == DaemonOwnershipManifest.currentVersion else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return manifest
    }

    private nonisolated func discardDaemonOwnershipManifest() {
        let url = daemonOwnershipManifestURL()
        do {
            try FileManager.default.removeItem(at: url)
            try DurableFileSystem.synchronizeParentDirectory(of: url)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            return
        } catch let error as POSIXError where error.code == .ENOENT {
            return
        } catch {
            logger.warning("Could not remove the aria2 ownership marker: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated func daemonOwnershipManifestURL() -> URL {
        HarborApplicationSupport.directoryURL()
            .appendingPathComponent("aria2.daemon-owner.json", isDirectory: false)
    }

    private func daemonUsesHarborSession(
        _ daemon: RunningDaemon,
        sessionFileURL: URL
    ) -> Bool {
        daemon.command.contains("--input-file=\(sessionFileURL.path)")
            && daemon.command.contains("--save-session=\(sessionFileURL.path)")
            && daemon.command.contains("--enable-rpc=true")
    }

    private func runningDaemons(matching binaryPath: String) throws -> [RunningDaemon] {
        try processListOutput(arguments: [
            "-axo", "pid=,ppid=,lstart=,command=", "-ww"
        ])
        .split(separator: "\n")
        .compactMap { line in
            daemon(from: String(line), binaryPath: binaryPath)
        }
    }

    private func runningDaemon(
        processIdentifier: pid_t,
        matching binaryPath: String
    ) throws -> RunningDaemon? {
        let output = try processListOutput(arguments: [
            "-p", "\(processIdentifier)",
            "-o", "pid=,ppid=,lstart=,command=",
            "-ww"
        ])
        return output.split(separator: "\n")
        .compactMap { line in
            daemon(from: String(line), binaryPath: binaryPath)
        }
        .first
    }

    private func processListOutput(arguments: [String]) throws -> String {
        let process = Process()
        let outputPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            logger.warning("Could not inspect aria2 processes: \(error.localizedDescription, privacy: .public)")
            throw TorrentEngineError.startupFailed(
                "Harbor could not inspect earlier aria2 processes: \(error.localizedDescription)"
            )
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw TorrentEngineError.startupFailed(
                "Harbor could not inspect earlier aria2 processes."
            )
        }

        guard let output = String(data: data, encoding: .utf8) else {
            throw TorrentEngineError.startupFailed(
                "Harbor could not decode the process list while checking aria2."
            )
        }

        return output
    }

    private func daemon(from processLine: String, binaryPath: String) -> RunningDaemon? {
        let parts = processLine
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", maxSplits: 7, omittingEmptySubsequences: true)

        guard parts.count == 8,
              let pid = pid_t(parts[0]),
              let parentPID = pid_t(parts[1]) else {
            return nil
        }

        let startSignature = parts[2 ... 6].joined(separator: " ")
        let command = String(parts[7])
            .trimmingCharacters(in: .whitespaces)
        guard command.contains("--enable-rpc=true"),
              isHarborManagedDaemon(command: command, binaryPath: binaryPath) else {
            return nil
        }

        // TODO: Replace process-list cleanup with a persisted daemon lock if Harbor later supports multiple concurrent app instances.
        return RunningDaemon(
            pid: pid,
            parentPID: parentPID,
            startSignature: startSignature,
            command: command
        )
    }

    private func isHarborManagedDaemon(command: String, binaryPath: String) -> Bool {
        command == binaryPath || command.hasPrefix(binaryPath + " ")
    }

    private nonisolated func installReadabilityHandler(for pipe: Pipe) {
        let logger = self.logger
        let startupLogBuffer = self.startupLogBuffer
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard data.isEmpty == false,
                  let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                  output.isEmpty == false else {
                return
            }

            startupLogBuffer.append(output)
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
