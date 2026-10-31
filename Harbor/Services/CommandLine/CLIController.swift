import AppKit
import CryptoKit
import Foundation

@MainActor
final class CLIController {
    private struct PartialFailure: Error { let result: Any; let message: String }
    private let center: DownloadCenter
    private let settings: AppSettingsStore
    private var server: CLIServer?
    private var accessEpoch = UUID()
    var showSettings: ((String) -> Void)?
    private struct AddReceipt: Codable { let digest: String; var id: UUID? }
    private let receiptURL: URL
    init(center: DownloadCenter, settings: AppSettingsStore) {
        self.center = center; self.settings = settings
        receiptURL = HarborApplicationSupport.directoryURL().appendingPathComponent("cli-add-receipts.json")
        settings.cliAccessDidChange = { [weak self] in self?.updateAccess() }
    }
    func updateAccess() {
        if !settings.cliAccessEnabled {
            accessEpoch = UUID()
            server = nil
            settings.cliStatus = nil
            return
        }
        guard server == nil else { return }
        do {
            let epoch = accessEpoch
            server = try CLIServer { [weak self] data in
                guard let self else { return CLIWire.failure(CLIError("unavailable", "Harbor closed.")) }
                return await self.handle(data, epoch: epoch)
            }
            settings.cliStatus = nil
        } catch { settings.cliStatus = error.localizedDescription }
    }
    private func handle(_ data: Data, epoch: UUID) async -> Data {
        do {
            guard settings.cliAccessEnabled, epoch == accessEpoch else { throw CLIError("disabled", "CLI access is disabled in Harbor settings.") }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  object["protocol"] as? Int == CLIWire.protocolVersion,
                  let arguments = object["arguments"] as? [String], !arguments.isEmpty,
                  let options = object["options"] as? [String: Any] else {
                throw CLIError("invalid_argument", "Expected protocol 1, arguments, and options.")
            }
            let result = try await execute(arguments, options: options)
            return try CLIWire.encode(["protocol": 1, "ok": true, "result": result])
        } catch let failure as PartialFailure {
            return (try? CLIWire.encode(["protocol": 1, "ok": false, "result": failure.result,
                "error": ["code": "partial_failure", "message": failure.message]])) ?? CLIWire.failure(CLIError("partial_failure", failure.message))
        } catch { return CLIWire.failure(error) }
    }
    private func execute(_ args: [String], options: [String: Any]) async throws -> Any {
        let command = args[0]; let tail = Array(args.dropFirst())
        let allowed: [String: Set<String>] = [
            "list": ["status", "tag", "offset", "limit"],
            "add": ["source", "kind", "destination", "name", "paused", "start", "tags", "headers", "files", "sequential", "format", "request-id"],
            "preview": ["source", "kind", "headers"],
            "import": ["destination", "paused", "start", "tags"],
            "pause": ["all"], "resume": ["all"], "retry": ["all"], "cancel": ["all"], "remove": ["all"],
            "trash": ["confirm-trash"]
        ]
        guard Set(options.keys).isSubset(of: allowed[command] ?? []) else { throw invalid("Unknown option for \(command). Run harbor help.") }
        for flag in ["all", "paused", "start", "sequential", "confirm-trash"] where options[flag] != nil {
            guard options[flag] is Bool else { throw invalid("\(flag) must be a boolean.") }
        }
        for (key, value) in options where key != "headers" && !["all", "paused", "start", "sequential", "confirm-trash"].contains(key) {
            guard value is String else { throw invalid("\(key) must be a string.") }
        }
        if options["paused"] as? Bool == true && options["start"] as? Bool == true {
            throw invalid("Choose either --start or --paused.")
        }
        if command == "doctor" || command == "capabilities" {
            try count(tail, 0)
            return ["version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
                    "protocol": 1, "ready": center.canAddDownloads, "cliEnabled": settings.cliAccessEnabled,
                    "commands": ["list", "inspect", "source", "activity", "add", "import", "preview", "pause", "resume", "retry", "cancel", "remove", "trash", "clear", "tags", "limit", "torrent", "media", "open", "reveal", "quick-look", "browser", "settings", "ui", "skill"],
                    "interactive": ["browser sign-in", "macOS permissions", "VPN profile and credentials", "updates", "default-app setup", "Safari extension management"],
                    "trashFlag": "--confirm-trash"] as [String: Any]
        }
        if command == "skill" { return try skill(tail) }
        if command == "ui" {
            try count(tail, 1)
            guard ["general", "downloads", "media", "torrents", "bandwidth", "network", "extensions", "updates"].contains(tail[0]) else { throw invalid("Unknown settings pane.") }
            showSettings?(tail[0] == "updates" ? "general" : tail[0])
            throw CLIError("needs_user_interaction", "Continue in Harbor settings. No setting was changed.")
        }
        if command == "settings" { return try CLISettings(settings: settings).run(tail) }
        guard center.canAddDownloads else { throw CLIError("unavailable", "Harbor is still loading or shutting down. Try again when it is ready.") }
        switch command {
        case "list":
            try count(tail, 0)
            let status = options["status"] as? String
            if let status, DownloadStatus(rawValue: status) == nil { throw invalid("Unknown status.") }
            let tag = options["tag"] as? String
            let items = center.downloads.filter { (status == nil || $0.status.rawValue == status) && (tag == nil || $0.tags.contains(tag!)) }
            let offset = try integer(options["offset"] as? String ?? "0", range: 0...Int.max)
            let limit = try integer(options["limit"] as? String ?? "100", range: 1...500)
            let page = items.dropFirst(offset).prefix(limit)
            return ["items": page.map(snapshot), "total": items.count, "offset": offset, "limit": limit] as [String: Any]
        case "source":
            try count(tail, 1)
            return ["source": try item(tail[0]).sourceURL.absoluteString]
        case "inspect", "activity":
            try count(tail, 1); let item = try item(tail[0])
            if command == "activity" { return try encoded(item.activityEvents) }
            var result = snapshot(item)
            result["error"] = item.lastError as Any? ?? NSNull()
            return result
        case "add":
            return try await add(tail, options: options)
        case "preview":
            let (url, kind) = try source(tail, options: options)
            let headers = try headers(options)
            if kind == .mediaURL {
                guard let metadata = try await center.previewMediaDownload(for: url) else { throw invalid("No media was found.") }
                return try encoded(metadata)
            }
            guard kind.usesAria2 else { throw invalid("Preview requires a media or torrent source.") }
            return torrentSnapshot(try await center.previewTorrentContents(sourceKind: kind, sourceURL: url, requestHeaders: headers))
        case "import":
            try count(tail, 1)
            guard settings.manifestImportEnabled else { throw invalid("Enable manifest import in Settings > Extensions first.") }
            let manifest = try await DownloadManifestImportService.read(URL(fileURLWithPath: tail[0]))
            var ids: [String] = []
            // Return partial progress on failure so callers never blindly reimport a batch.
            for url in manifest.urls {
                do {
                    let request = try await request(url: url, kind: DownloadSourceKind.detect(from: url)!, options: options)
                    ids.append(try await center.queueDownloadAndSave(request).uuidString)
                } catch {
                    throw PartialFailure(result: ["accepted": !ids.isEmpty, "ids": ids, "complete": false],
                                         message: error.localizedDescription)
                }
            }
            return ["accepted": true, "ids": ids, "complete": true, "skipped": manifest.skippedCount] as [String: Any]
        case "pause", "resume", "retry", "cancel", "remove", "trash":
            let eligible: (DownloadItem) -> Bool = { item in
                switch command {
                case "pause": return item.canPause || item.status == .queued
                case "resume": return item.canResume
                case "retry": return [.failed, .cancelled].contains(item.status)
                case "cancel": return self.center.canCancelDownloads(ids: [item.id])
                default: return true
                }
            }
            let items: [DownloadItem]
            if options["all"] as? Bool == true {
                try count(tail, 0); items = center.downloads.filter(eligible)
            } else {
                guard !tail.isEmpty else { throw invalid("Supply download IDs or --all. Trash requires explicit IDs.") }
                items = try tail.map(item)
                guard items.allSatisfy(eligible) else { throw CLIError("invalid_state", "At least one download cannot perform this action. No command was sent.") }
            }
            let ids = Set(items.map(\.id))
            switch command {
            case "pause": center.pauseDownloads(ids: ids)
            case "resume": center.resumeDownloads(ids: ids)
            case "retry": center.retryDownloads(ids: ids)
            case "cancel": center.cancelDownloads(ids: ids)
            case "remove": center.removeDownloads(ids: ids)
            default:
                guard options["confirm-trash"] as? Bool == true else { throw invalid("Moving files to Trash requires --confirm-trash.") }
                guard center.canRemoveDownloadedData(ids: ids) else { throw CLIError("invalid_state", "No downloaded files are available to move to Trash.") }
                center.removeDownloadsAndData(ids: ids)
            }
            return accepted(ids)
        case "clear":
            try count(tail, 1)
            switch tail[0] {
            case "completed": center.clearCompleted()
            case "failed": await center.clearFailed()
            default: throw invalid("Use clear completed or clear failed.")
            }
            return ["accepted": true]
        case "tags": return try tags(tail)
        case "limit":
            try count(tail, 3); let item = try item(tail[0])
            let limit: TransferLimitOverride
            switch tail[2] {
            case "inherit": limit = .inherit
            case "unlimited": limit = .unlimited
            default: limit = .limited(kilobytesPerSecond: try integer(tail[2], range: AppSettingsStore.speedLimitKilobytesRange))
            }
            if tail[1] == "download", item.backend != .ytDlp { center.setDownloadLimitOverride(limit, for: item.id) }
            else if tail[1] == "upload", item.backend == .aria2 { center.setUploadLimitOverride(limit, for: item.id) }
            else { throw invalid("This download does not support the requested limit.") }
            return accepted([item.id])
        case "torrent": return try await torrent(tail)
        case "media": return try await media(tail)
        case "open", "reveal", "quick-look", "browser":
            try count(tail, 1); let item = try item(tail[0])
            if command == "browser" {
                guard center.canContinueInBrowser(ids: [item.id]) else { throw CLIError("invalid_state", "This download does not need a browser session.") }
                center.continueInBrowser(id: item.id)
                throw CLIError("needs_user_interaction", "Continue sign-in in Harbor's browser window.")
            }
            guard item.fileLocationURL != nil else { throw CLIError("invalid_state", "No downloaded file is available.") }
            if command == "open" { center.openDownload(id: item.id) }
            if command == "reveal" { center.revealInFinder(id: item.id) }
            if command == "quick-look" {
                guard center.canQuickLookDownloads(ids: [item.id]) else { throw CLIError("invalid_state", "Quick Look is not available for this download.") }
                center.quickLookDownloads(ids: [item.id])
            }
            return accepted([item.id])
        default: throw invalid("Unknown command. Run harbor help.")
        }
    }
    private func add(_ args: [String], options: [String: Any]) async throws -> Any {
        let (url, kind) = try source(args, options: options)
        let key = options["request-id"] as? String
        if let key, UUID(uuidString: key) == nil { throw invalid("request-id must be a UUID.") }
        var fingerprintOptions = options; fingerprintOptions.removeValue(forKey: "request-id")
        let digest = AgentSkillInstaller.hash(try CLIWire.encode(["source": url.absoluteString, "options": fingerprintOptions]))
        var receipts: [String: AddReceipt] = [:]
        if FileManager.default.fileExists(atPath: receiptURL.path) {
            receipts = try JSONDecoder().decode([String: AddReceipt].self, from: Data(contentsOf: receiptURL))
        }
        if let key, let receipt = receipts[key] {
            guard receipt.digest == digest else { throw invalid("This request ID was already used with different options.") }
            guard let id = receipt.id else { throw CLIError("outcome_unknown", "This add request was interrupted. Inspect the list before creating another request.") }
            return ["accepted": true, "id": id.uuidString, "replayed": true] as [String: Any]
        }
        let request = try await request(url: url, kind: kind, options: options)
        // Write intent first. A crash between queue persistence and receipt persistence must not duplicate a download.
        if let key {
            receipts[key] = AddReceipt(digest: digest, id: nil)
            try save(receipts)
        }
        let id = try await center.queueDownloadAndSave(request)
        if let key { receipts[key] = AddReceipt(digest: digest, id: id); try save(receipts) }
        return ["accepted": true, "id": id.uuidString, "replayed": false] as [String: Any]
    }
    // TODO: Add explicit receipt pruning if long-running automation makes this journal large.
    // Never expire receipts silently: replaying an old request must not create a duplicate.
    private func save(_ receipts: [String: AddReceipt]) throws {
        try FileManager.default.createDirectory(at: receiptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(receipts).write(to: receiptURL, options: .atomic)
    }
    private func request(url: URL, kind: DownloadSourceKind, options: [String: Any]) async throws -> AddDownloadRequest {
        let destination = (options["destination"] as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? (kind.usesAria2 ? settings.torrentDestinationURL : settings.defaultDestinationURL)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &directory), directory.boolValue,
              FileManager.default.isWritableFile(atPath: destination.path) else { throw invalid("Destination must be an existing writable directory.") }
        let headers = try headers(options)
        if kind == .mediaURL && !headers.isEmpty { throw invalid("Media request headers are not supported.") }
        var metadata: MediaDownloadMetadata?
        var preference: MediaDownloadFormatPreference?
        if kind == .mediaURL {
            metadata = try await center.previewMediaDownload(for: url)
            guard let metadata else { throw invalid("No media was found.") }
            preference = try mediaPreference(options["format"] as? String, metadata: metadata)
        } else if options["format"] != nil { throw invalid("format requires a media download.") }
        var selection: TorrentFileSelection?
        var preview: TorrentContentsPreview?
        if let files = options["files"] as? String {
            guard kind.usesAria2 else { throw invalid("files requires a torrent.") }
            let result = try await center.previewTorrentContents(sourceKind: kind, sourceURL: url, requestHeaders: headers)
            let indexes = try selectedIndexes(files.split(separator: ",").map(String.init), in: result)
            selection = TorrentFileSelection.partial(selectedIndexes: indexes, in: result); preview = result
        }
        if options["sequential"] as? Bool == true && !kind.usesAria2 { throw invalid("sequential requires a torrent.") }
        return AddDownloadRequest(sourceKind: kind, sourceURL: url, customFilename: options["name"] as? String,
            destinationFolder: destination, shouldStartImmediately: options["paused"] as? Bool != true && (options["start"] as? Bool == true || settings.startDownloadsAutomatically),
            requestHeaders: headers, mediaMetadata: metadata, mediaFormatPreference: preference,
            torrentFileSelection: selection, downloadsTorrentPiecesSequentially: options["sequential"] as? Bool == true,
            preparedTorrentMetainfo: preview?.metainfoData, torrentMetadataName: preview?.name,
            tags: (options["tags"] as? String)?.split(separator: ",").map(String.init) ?? [])
    }
    private func source(_ args: [String], options: [String: Any]) throws -> (URL, DownloadSourceKind) {
        guard args.count <= 1, (args.first == nil) != (options["source"] == nil),
              let raw = args.first ?? options["source"] as? String, let url = URL(string: raw),
              let detected = DownloadSourceKind.detect(from: url) else { throw invalid("Supply one supported URL or a local .torrent file.") }
        let kind: DownloadSourceKind
        if let value = options["kind"] as? String {
            guard let parsed = DownloadSourceKind(rawValue: value) else { throw invalid("Unknown source kind.") }
            kind = parsed
        } else { kind = detected }
        guard (kind == .magnetLink && detected == .magnetLink) ||
              (kind == .torrentFile && (detected == .torrentFile || detected == .directURL)) ||
              ((kind == .directURL || kind == .mediaURL) && ["https", "http"].contains(url.scheme?.lowercased() ?? "")) else { throw invalid("Source kind does not match the URL.") }
        return (url, kind)
    }
    private func headers(_ options: [String: Any]) throws -> [RequestHeader] {
        guard let value = options["headers"] else { return [] }
        let headers = try JSONDecoder().decode([RequestHeader].self, from: JSONSerialization.data(withJSONObject: value))
        guard headers.allSatisfy({ $0.validationIssue == nil }) else { throw invalid("Invalid request header.") }
        return headers
    }
    private func tags(_ args: [String]) throws -> Any {
        guard let action = args.first else { throw invalid("A tag action is required.") }
        switch action {
        case "list": try count(args, 1); return center.availableTags
        case "set":
            guard args.count >= 2 else { throw invalid("tags set requires an ID.") }
            let item = try item(args[1]); center.setTags(Array(args.dropFirst(2)), for: item.id); return snapshot(item)
        case "rename": try count(args, 3); center.renameTag(args[1], to: args[2])
        case "delete": try count(args, 2); center.deleteTag(args[1])
        default: throw invalid("Unknown tag action.")
        }
        return ["accepted": true]
    }
    private func torrent(_ args: [String]) async throws -> Any {
        guard args.count >= 2 else { throw invalid("Torrent action and ID are required.") }
        let item = try item(args[1]); guard item.backend == .aria2 else { throw invalid("This is not a torrent.") }
        let action = args[0]
        switch action {
        case "files": try count(args, 2); return torrentSnapshot(try await center.previewTorrentContents(id: item.id))
        case "select":
            let preview = try await center.previewTorrentContents(id: item.id)
            let indexes = try selectedIndexes(Array(args.dropFirst(2)), in: preview)
            try await center.updateTorrentSelection(id: item.id, preview: preview, selection: .partial(selectedIndexes: indexes, in: preview))
        case "trackers":
            try count(args, 2)
            return try await center.torrentTrackers(for: item.id).map {
                ["url": $0.url, "status": $0.status, "removable": $0.isRemovable, "seeders": $0.seeders, "leechers": $0.leechers] as [String: Any]
            }
        case "tracker-add": try count(args, 3); try await center.addTorrentTracker(args[2], for: item.id)
        case "tracker-remove":
            try count(args, 3)
            guard let tracker = try await center.torrentTrackers(for: item.id).first(where: { $0.url == args[2] }), tracker.isRemovable else { throw invalid("This tracker cannot be removed.") }
            try await center.removeTorrentTracker(tracker, for: item.id)
        case "reannounce": try count(args, 2); try await center.reannounceTorrentTrackers(for: item.id)
        case "seed":
            try count(args, 2)
            guard settings.seedTorrents, item.finishedAt != nil else { throw CLIError("invalid_state", "Seeding requires completed files and enabled seeding in settings.") }
            if item.sourceURL.isFileURL && item.managedTorrentSourcePath == nil && !FileManager.default.fileExists(atPath: item.sourceURL.path) {
                throw CLIError("needs_user_interaction", "Select the missing torrent source in Harbor.")
            }
            center.startSeeding(id: item.id)
        case "stop-seeding":
            try count(args, 2)
            guard item.finishedAt != nil, item.shouldSeedAfterDownload else { throw CLIError("invalid_state", "This torrent is not seeding.") }
            center.stopSeeding(id: item.id)
        default: throw invalid("Unknown torrent action.")
        }
        return accepted([item.id])
    }
    private func media(_ args: [String]) async throws -> Any {
        guard args.count >= 2 else { throw invalid("Media action and ID are required.") }
        let item = try item(args[1]); guard item.backend == .ytDlp else { throw invalid("This is not a media download.") }
        switch args[0] {
        case "formats":
            try count(args, 2)
            if item.status == .failed { await center.refreshMediaFormats(for: item.id) }
            guard let metadata = item.mediaMetadata else { throw CLIError("invalid_state", "Media metadata is unavailable.") }
            return try encoded(metadata)
        case "format":
            try count(args, 3)
            guard item.status == .failed, let metadata = item.mediaMetadata else { throw CLIError("invalid_state", "Format changes require a failed media download.") }
            center.setMediaFormatPreference(try mediaPreference(args[2], metadata: metadata), for: item.id)
            return accepted([item.id])
        default: throw invalid("Unknown media action.")
        }
    }
    private func mediaPreference(_ id: String?, metadata: MediaDownloadMetadata) throws -> MediaDownloadFormatPreference {
        guard let id else { return try settings.mediaDefaults.preference(for: metadata) }
        if id == "bestAvailable" { return .bestAvailable }
        guard let option = metadata.capabilities.formatOptions.first(where: { $0.id == id }) else { throw invalid("Unknown media format ID. Preview formats first.") }
        return .specific(metadata.capabilities.defaultSelection(for: option))
    }
    private func skill(_ args: [String]) throws -> Any {
        try count(args, 1)
        guard ["status", "install", "uninstall"].contains(args[0]) else { throw invalid("Unknown skill action.") }
        let installer = AgentSkillInstaller()
        let results = installer.targets().map { target -> [String: Any] in
            do {
                if args[0] == "install" { try installer.installSkill(at: target) }
                if args[0] == "uninstall", target.status != "not installed" { try installer.uninstallSkill(at: target) }
                return ["name": target.name, "path": target.id, "status": installer.targets().first { $0.id == target.id }?.status ?? "not installed"]
            } catch { return ["name": target.name, "path": target.id, "status": "conflict", "error": error.localizedDescription] }
        }
        if results.contains(where: { $0["error"] != nil }) {
            throw PartialFailure(result: results, message: "Some skill folders were not changed. Check each result.")
        }
        return results
    }
    private func selectedIndexes(_ args: [String], in preview: TorrentContentsPreview) throws -> Set<Int> {
        let indexes = try Set(args.map { try integer($0, range: 1...Int.max) })
        guard !indexes.isEmpty, indexes.isSubset(of: Set(preview.files.map(\.index))) else { throw invalid("Select valid file indexes from torrent files.") }
        return indexes
    }
    private func torrentSnapshot(_ preview: TorrentContentsPreview) -> [String: Any] {
        ["name": preview.name, "infoHash": preview.infoHash, "totalBytes": preview.totalBytes,
         "files": preview.files.map { ["index": $0.index, "path": $0.path, "bytes": $0.byteCount,
            "selected": preview.selectedIndexes?.contains($0.index) ?? true, "completed": preview.completedIndexes.contains($0.index)] as [String: Any] }]
    }
    private func snapshot(_ item: DownloadItem) -> [String: Any] {
        // Do not serialize DownloadRecord: it contains headers, resume data and private engine state.
        ["id": item.id.uuidString, "name": item.displayName, "kind": item.sourceKind.rawValue,
         "status": item.status.rawValue, "progress": item.progress, "bytesWritten": item.bytesWritten,
         "expectedBytes": item.expectedBytes, "uploadedBytes": item.uploadedBytes,
         "downloadBytesPerSecond": item.speedBytesPerSecond, "uploadBytesPerSecond": item.uploadBytesPerSecond,
         "destination": item.destinationFolderPath, "file": item.fileLocationPath as Any? ?? NSNull(),
         "tags": item.tags, "hasError": item.lastError != nil,
         "needsUserInteraction": item.status == .browserSessionRequired]
    }
    private func item(_ value: String) throws -> DownloadItem {
        guard let id = UUID(uuidString: value) else { throw invalid("Expected a full download UUID.") }
        guard let item = center.downloads.first(where: { $0.id == id }) else { throw CLIError("not_found", "Download ID was not found.") }
        return item
    }
    private func accepted(_ ids: Set<UUID>) -> [String: Any] { ["accepted": true, "ids": ids.map(\.uuidString).sorted()] }
    private func encoded<T: Encodable>(_ value: T) throws -> Any {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(value), options: .fragmentsAllowed)
    }
    private func count(_ args: [String], _ expected: Int) throws {
        guard args.count == expected else { throw invalid("Expected \(expected) argument(s). Run harbor help.") }
    }
    private func integer(_ text: String, range: ClosedRange<Int>) throws -> Int {
        guard let value = Int(text), range.contains(value) else { throw invalid("Expected an integer from \(range.lowerBound) to \(range.upperBound).") }
        return value
    }
    private func invalid(_ message: String) -> CLIError { CLIError("invalid_argument", message) }
}
