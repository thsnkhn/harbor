import Foundation

extension DownloadCenter {
    func checkTorrentFiles(id: UUID) {
        guard let item = item(for: id), item.backend == .aria2, !isShuttingDown else { return }
        checkingTorrentID = id
    }

    func queueTorrentForChecking(_ request: AddDownloadRequest, location: URL) {
        let checkRequest = AddDownloadRequest(
            sourceKind: request.sourceKind, sourceURL: request.sourceURL,
            customFilename: nil, destinationFolder: request.destinationFolder,
            shouldStartImmediately: false, requestHeaders: request.requestHeaders,
            torrentFileSelection: request.torrentFileSelection,
            preparedTorrentMetainfo: request.preparedTorrentMetainfo,
            torrentMetadataName: request.torrentMetadataName,
            torrentOperation: .checkOnly, torrentExistingDataPath: location.path
        )
        queueDownload(checkRequest)
    }

    func loadTorrentCheckPreview(id: UUID) async throws -> TorrentContentsPreview {
        guard let item = item(for: id), item.backend == .aria2 else {
            throw TorrentEngineError.invalidSource
        }
        await applyNetworkBindingBeforeEngineUse()
        let preview = try await previewTorrentContents(
            sourceKind: torrentEngineSourceKind(for: item),
            sourceURL: torrentEngineSourceURL(for: item),
            requestHeaders: item.requestHeaders
        )
        guard self.item(for: id) === item, !isShuttingDown else { throw CancellationError() }
        let managed = try await managedTorrentSourceStore.prepareTorrentData(
            preview.metainfoData, originalURL: item.sourceURL
        )
        guard self.item(for: id) === item else { throw CancellationError() }
        item.managedTorrentSourcePath = managed.managedURL.path
        item.torrentFingerprint = managed.fingerprint
        item.torrentSourceFingerprint = managed.sourceFingerprint
        try await saveRecordsNow()
        return preview
    }

    func beginTorrentCheck(id: UUID, location: URL) async {
        guard let item = item(for: id), item.backend == .aria2,
              canBeginTorrentCheck(id: id) else { return }
        let identifier = UUID()
        setTorrentCheckIdentifier(identifier, for: id)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performTorrentCheck(id: id, location: location, identifier: identifier)
        }
        setTorrentCheckTask(task, for: id)
        await task.value
        if torrentCheckIdentifier(for: id) == identifier {
            setTorrentCheckTask(nil, for: id)
            setTorrentCheckIdentifier(nil, for: id)
        }
    }

    private func performTorrentCheck(id: UUID, location: URL, identifier: UUID) async {
        guard let item = item(for: id) else { return }
        func isCurrent() -> Bool {
            self.item(for: id) === item && torrentCheckIdentifier(for: id) == identifier
                && !Task.isCancelled && !isShuttingDown
        }
        do {
            // Persist the approval gate before stopping the previous writer.
            // A crash must never turn a requested check into an automatic repair.
            item.torrentCheckState = .pending
            item.shouldSeedAfterDownload = false
            item.wasSuspendedForNetworkBinding = false
            try await saveRecordsNow()
            for task in torrentTasksToQuiesce(for: id) { await task.value }
            guard isCurrent() else { throw CancellationError() }
            if let gid = item.backendIdentifier {
                try await torrentService.removeAndConfirmStopped(gid: gid)
                item.backendIdentifier = nil
            }
            item.status = .paused
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            try await saveRecordsNow()
            let preview = try await loadTorrentCheckPreview(id: id)
            guard isCurrent() else { throw CancellationError() }
            let layout = try TorrentCheckPathMapping.resolve(preview: preview, location: location)
            try validateTorrentCheckOwnership(id: id, location: location)
            item.torrentExistingDataPath = location.standardizedFileURL.path
            item.destinationFolderPath = layout.directoryURL.path
            item.fileLocationPath = location.standardizedFileURL.path
            let selected = item.torrentFileSelection.map { Set($0.selectedIndexes) }
            item.torrentPayloadPaths = zip(preview.files, layout.payloadURLs)
                .filter { selected == nil || selected!.contains($0.0.index) }
                .map { $0.1.path }
            item.torrentCheckState = .checking
            item.torrentCheckProgress = nil
            item.lastError = nil
            item.updatedAt = .now
            try await saveRecordsNow()
            let result = try await torrentService.checkExistingData(
                metainfo: preview.metainfoData, location: location,
                selection: item.torrentFileSelection
            ) { progress in
                await MainActor.run {
                    guard self.torrentCheckIdentifier(for: id) == identifier,
                          self.item(for: id)?.torrentCheckState == .checking else { return }
                    self.item(for: id)?.torrentCheckProgress = progress
                }
            }
            guard isCurrent() else { throw CancellationError() }
            item.torrentCheckState = result.state
            item.torrentCheckProgress = nil
            item.bytesWritten = result.verifiedBytes
            item.expectedBytes = result.totalBytes
            item.progress = result.totalBytes > 0
                ? Double(result.verifiedBytes) / Double(result.totalBytes) : 0
            item.lastError = result.errorMessage
            item.status = result.state == .complete ? .completed : .paused
            item.finishedAt = result.state == .complete ? .now : nil
            item.metadataName = preview.name
            item.updatedAt = .now
            try await saveRecordsNow()
        } catch {
            guard self.item(for: id) === item else { return }
            if let uncertain = error as? TorrentSubmissionUncertainError {
                item.backendIdentifier = uncertain.gid
            }
            var failure: Error = error
            if let gid = item.backendIdentifier {
                do {
                    try await torrentService.removeAndConfirmStopped(gid: gid)
                    item.backendIdentifier = nil
                } catch { failure = error }
            }
            item.torrentCheckState = failure is CancellationError ? .pending : .error
            item.torrentCheckProgress = nil
            item.status = .paused
            item.lastError = failure is CancellationError ? nil : failure.localizedDescription
            item.updatedAt = .now
            do { try await saveRecordsNow() }
            catch { item.lastError = error.localizedDescription; schedulePersist() }
        }
    }

    func keepTorrentStopped(id: UUID) {
        guard let item = item(for: id), item.backend == .aria2 else { return }
        torrentCheckTask(for: id)?.cancel()
        item.shouldSeedAfterDownload = false
        item.wasSuspendedForNetworkBinding = false
        if torrentCheckTask(for: id) == nil {
            if item.torrentCheckState == .complete { item.status = .completed }
            else { pauseDownloads(ids: [id]) }
        }
        schedulePersist()
    }

    func downloadMissingTorrentPieces(id: UUID) {
        guard let item = item(for: id), item.torrentCheckState == .incomplete,
              torrentCheckTask(for: id) == nil, !isShuttingDown else { return }
        approveCheckedTorrent(id: id, seed: false)
    }

    func approveCheckedTorrent(id: UUID, seed: Bool) {
        guard let item = item(for: id), item.backend == .aria2,
              item.torrentCheckState == (seed ? .complete : .incomplete),
              canBeginTorrentCheck(id: id) else { return }
        let identifier = UUID()
        setTorrentCheckIdentifier(identifier, for: id)
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var approved = false
            do {
                if let path = item.torrentExistingDataPath {
                    try validateTorrentCheckOwnership(id: id, location: URL(fileURLWithPath: path))
                }
                if seed {
                    guard let path = item.torrentExistingDataPath else { throw TorrentEngineError.invalidSource }
                    let preview = try await loadTorrentCheckPreview(id: id)
                    let result = try await torrentService.checkExistingData(
                        metainfo: preview.metainfoData, location: URL(fileURLWithPath: path),
                        selection: item.torrentFileSelection
                    )
                    guard result.state == .complete else {
                        item.torrentCheckState = result.state
                        item.finishedAt = nil
                        item.lastError = result.errorMessage
                        checkingTorrentID = id
                        try await saveRecordsNow()
                        throw TorrentEngineError.rpc("The files need repair. Choose Download Missing Pieces to continue.")
                    }
                }
                if let gid = item.backendIdentifier {
                    try await torrentService.removeAndConfirmStopped(gid: gid)
                    item.backendIdentifier = nil
                }
                try Task.checkCancellation()
                guard self.item(for: id) === item, !isShuttingDown else { throw CancellationError() }
                await performSerializedDurableMutation {
                    let original = item.makeRecord()
                    do {
                        try Task.checkCancellation()
                        item.shouldSeedAfterDownload = seed || self.settings.seedNewTorrents
                        item.torrentCheckState = nil
                        item.status = .paused
                        item.updatedAt = .now
                        try await self.saveRecordsNow()
                        try Task.checkCancellation()
                        guard !self.isShuttingDown else { throw CancellationError() }
                        approved = true
                    } catch {
                        item.restorePersistedState(from: original)
                        item.lastError = error is CancellationError ? nil : error.localizedDescription
                        // This gate is reentrant while cancellation is set.
                        // Restore the durable approval gate before ownership ends.
                        do { try await self.saveRecordsNow() }
                        catch {
                            item.lastError = error.localizedDescription
                            self.schedulePersist()
                        }
                    }
                }
            } catch {
                item.lastError = error is CancellationError ? nil : error.localizedDescription
            }
            if torrentCheckIdentifier(for: id) == identifier {
                setTorrentCheckTask(nil, for: id)
                setTorrentCheckIdentifier(nil, for: id)
                if approved { startOrQueueDownload(id: id) }
            }
        }
        setTorrentCheckTask(task, for: id)
    }

    private func validateTorrentCheckOwnership(id: UUID, location: URL) throws {
        let path = location.resolvingSymlinksInPath().standardizedFileURL.path
        for other in downloads where other.id != id && other.backend == .aria2 {
            var paths = other.torrentPayloadPaths + [other.torrentExistingDataPath, other.fileLocationPath].compactMap { $0 }
            if let name = other.metadataName, !name.isEmpty {
                paths.append(other.destinationFolderURL.appendingPathComponent(name).path)
            }
            if paths.contains(where: {
                let candidate = URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path
                return candidate == path || candidate.hasPrefix(path + "/") || path.hasPrefix(candidate + "/")
            }) {
                throw TorrentEngineError.rpc("These files already belong to another torrent in Harbor.")
            }
        }
    }
}
