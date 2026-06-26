import AppKit
import Foundation
import Observation

@Observable
@MainActor
final class DownloadCenter {
    @ObservationIgnored private let settings: AppSettingsStore
    @ObservationIgnored private let persistence: DownloadPersistence
    @ObservationIgnored private let destinationResolver: DownloadDestinationResolver
    @ObservationIgnored private let notificationService: DownloadNotificationService
    @ObservationIgnored private var coordinator: DownloadCoordinator! = nil
    @ObservationIgnored private var browserCoordinator: BrowserDownloadCoordinator! = nil
    @ObservationIgnored private let torrentService: Aria2TorrentService
    @ObservationIgnored private var mediaService: MediaDownloadService! = nil
    @ObservationIgnored private var hasLoaded = false
    @ObservationIgnored private var hasInstalledExternalOpenHandler = false
    @ObservationIgnored private var persistTask: Task<Void, Never>?
    @ObservationIgnored private var torrentRefreshTask: Task<Void, Never>?
    @ObservationIgnored private var hasShownTorrentBinaryAlert = false
    @ObservationIgnored private var hasShownMediaRuntimeAlert = false
    @ObservationIgnored private var isShuttingDown = false
    @ObservationIgnored private var mediaStartIDs: Set<UUID> = []
    @ObservationIgnored private var pendingExternalAddSheetDrafts: [AddDownloadSheetDraft] = []

    var downloads: [DownloadItem] = []
    var selectedFilter: DownloadFilter = .all
    var selectedDownloadID: UUID?
    var searchText = ""
    var sortMode: DownloadSortMode = .newest
    var addSheetDraft: AddDownloadSheetDraft?
    var activeBrowserSession: BrowserDownloadSession?
    var activeAlert: UserAlert?

    init(
        settings: AppSettingsStore,
        persistence: DownloadPersistence = DownloadPersistence(),
        destinationResolver: DownloadDestinationResolver = DownloadDestinationResolver(),
        notificationService: DownloadNotificationService = DownloadNotificationService(),
        torrentService: Aria2TorrentService? = nil,
        mediaService: MediaDownloadService? = nil
    ) {
        self.settings = settings
        self.persistence = persistence
        self.destinationResolver = destinationResolver
        self.notificationService = notificationService
        self.torrentService = torrentService ?? Aria2TorrentService(transferSettings: settings.transferSettings)
        self.mediaService = mediaService ?? MediaDownloadService { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        self.coordinator = DownloadCoordinator(transferSettings: settings.transferSettings) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        self.browserCoordinator = BrowserDownloadCoordinator { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }
        settings.transferSettingsDidChange = { [weak self] transferSettings in
            self?.applyTransferSettings(transferSettings)
        }
    }

    deinit {
        persistTask?.cancel()
        torrentRefreshTask?.cancel()
        Task { [mediaService] in
            await mediaService?.shutdown()
        }
    }

    func initializeIfNeeded() async {
        guard hasLoaded == false else {
            return
        }

        hasLoaded = true
        startTorrentRefreshLoopIfNeeded()

        do {
            let records = try await persistence.load()
            let restoredItems = records
                .sorted { $0.createdAt > $1.createdAt }
                .map { record in
                    let item = DownloadItem(record: record)
                    item.taskIdentifier = nil
                    item.speedBytesPerSecond = 0

                    if item.backend == .aria2 || item.backend == .ytDlp {
                        item.backendIdentifier = nil
                    }

                    if record.status == .queued || record.status == .preparing || record.status == .downloading {
                        item.status = settings.startDownloadsAutomatically ? .queued : .paused
                        if settings.startDownloadsAutomatically == false {
                            item.lastError = String(
                                localized: "download.restore.pausedAfterRelaunch",
                                defaultValue: "Paused after relaunch.",
                                comment: "Status message shown when a download is restored as paused after app relaunch."
                            )
                        }
                    }

                    return item
                }

            downloads = restoredItems
            selectedDownloadID = downloads.first?.id

            if settings.startDownloadsAutomatically {
                startNextQueuedDownloadsIfNeeded()
            }
        } catch {
            activeAlert = UserAlert(
                title: String(
                    localized: "alert.restoreDownloads.title",
                    defaultValue: "Couldn’t Restore Downloads",
                    comment: "Alert title shown when saved downloads cannot be restored."
                ),
                message: error.localizedDescription
            )
        }
    }

    var filteredDownloads: [DownloadItem] {
        let filtered = downloads.filter { item in
            guard selectedFilter.includes(item) else {
                return false
            }

            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard query.isEmpty == false else {
                return true
            }

            return item.displayName.localizedCaseInsensitiveContains(query)
                || item.sourceDisplayText.localizedCaseInsensitiveContains(query)
                || item.sourceHost.localizedCaseInsensitiveContains(query)
        }

        switch sortMode {
        case .newest:
            return filtered.sorted { $0.createdAt > $1.createdAt }
        case .oldest:
            return filtered.sorted { $0.createdAt < $1.createdAt }
        case .name:
            return filtered.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        case .progress:
            return filtered.sorted { lhs, rhs in
                (lhs.progressValue ?? 0) > (rhs.progressValue ?? 0)
            }
        case .speed:
            return filtered.sorted { lhs, rhs in
                lhs.speedBytesPerSecond > rhs.speedBytesPerSecond
            }
        }
    }

    var selectedDownload: DownloadItem? {
        guard let selectedDownloadID else {
            return nil
        }

        return downloads.first { $0.id == selectedDownloadID }
    }

    var totalActiveSpeed: Double {
        downloads
            .filter(\.isRunning)
            .reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalDownloadSpeed: Double {
        downloads.reduce(0) { $0 + $1.speedBytesPerSecond }
    }

    var totalUploadSpeed: Double {
        downloads.reduce(0) { $0 + $1.uploadBytesPerSecond }
    }

    var hasActiveDownloads: Bool {
        downloads.contains(where: \.isRunning)
    }

    var hasPausableDownloads: Bool {
        downloads.contains { item in
            item.canPause || item.status == .queued
        }
    }

    var hasResumableDownloads: Bool {
        downloads.contains(where: \.canResume)
    }

    var hasCompletedDownloads: Bool {
        downloads.contains { $0.status == .completed }
    }

    var hasFailedDownloads: Bool {
        downloads.contains { $0.status == .failed }
    }

    var activeDownloadCount: Int {
        downloads.filter { $0.status == .queued || $0.isRunning }.count
    }

    var canToggleSelectedDownload: Bool {
        guard let selectedDownload else {
            return false
        }

        return selectedDownload.status == .browserSessionRequired
            || selectedDownload.canPause
            || selectedDownload.canResume
    }

    var canRetrySelectedDownload: Bool {
        guard let selectedDownload else {
            return false
        }

        return selectedDownload.status == .failed
            || selectedDownload.status == .cancelled
    }

    var canCancelSelectedDownload: Bool {
        guard let selectedDownload else {
            return false
        }

        return selectedDownload.status != .completed
            && selectedDownload.status != .cancelled
    }

    var canOpenSelectedDownload: Bool {
        selectedDownload?.fileLocationURL != nil
    }

    func count(for filter: DownloadFilter) -> Int {
        downloads.filter { filter.includes($0) }.count
    }

    func installExternalOpenHandlerIfNeeded() {
        guard hasInstalledExternalOpenHandler == false else {
            return
        }

        hasInstalledExternalOpenHandler = true
        ExternalAddDownloadOpenCoordinator.shared.installHandler { [weak self] urls in
            self?.handleOpenedExternalAddSources(urls)
        }
    }

    func presentAddSheet() {
        guard addSheetDraft == nil else {
            return
        }

        addSheetDraft = makeBlankAddSheetDraft()
    }

    func handleAddSheetDismissal() {
        addSheetDraft = nil
        Task { @MainActor [weak self] in
            self?.presentNextQueuedExternalAddSheetIfNeeded()
        }
    }

    private func handleOpenedExternalAddSources(_ urls: [URL]) {
        let drafts = urls.compactMap { makeExternalAddSheetDraft(for: $0) }

        guard drafts.isEmpty == false else {
            return
        }

        pendingExternalAddSheetDrafts.append(contentsOf: drafts)
        presentNextQueuedExternalAddSheetIfNeeded()
    }

    func receiveExternalAddSources(_ urls: [URL]) {
        handleOpenedExternalAddSources(urls)
    }

    func addDownloadSourcesFromPasteboard() {
        receiveExternalAddSources(
            DownloadSourceImportService.supportedURLs(from: .general)
        )
    }

    func shutdownForTermination() async {
        isShuttingDown = true
        persistTask?.cancel()
        torrentRefreshTask?.cancel()

        let restoredStatus: DownloadStatus = settings.startDownloadsAutomatically ? .queued : .paused
        let pausedMessage = String(
            localized: "download.restore.pausedAfterQuit",
            defaultValue: "Paused after quit.",
            comment: "Status message shown when a download is paused because Harbor is quitting."
        )

        let activeItems = downloads.filter { item in
            item.status == .queued || item.status == .preparing || item.isRunning
        }

        for item in activeItems {
            switch item.backend {
            case .urlSession:
                if item.taskIdentifier != nil {
                    coordinator.pauseDownload(id: item.id)
                }
            case .aria2:
                if let backendIdentifier = item.backendIdentifier {
                    try? await torrentService.pause(gid: backendIdentifier)
                }
            case .ytDlp:
                await mediaService.pause(id: item.id)
            }

            setStatus(for: item, to: restoredStatus)
            item.taskIdentifier = nil
            item.backendIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            if restoredStatus == .paused {
                item.lastError = pausedMessage
            }
        }

        await mediaService.shutdown()
        await torrentService.shutdown()
        try? await persistence.save(downloads.map { $0.makeRecord() })
    }

    func previewMediaDownload(for url: URL) async throws -> MediaDownloadMetadata? {
        let scheme = url.scheme?.lowercased()
        let isHTTPURL = scheme == "http" || scheme == "https"
        guard url.isFileURL == false,
              isHTTPURL,
              url.pathExtension.lowercased() != "torrent" else {
            return nil
        }

        return try await mediaService.metadata(for: url)
    }

    func queueDownload(_ request: AddDownloadRequest) {
        let backend = backend(for: request.sourceKind)
        let preferredFilename: String?
        if request.sourceKind.supportsCustomFilename {
            preferredFilename = destinationResolver.resolvedFilename(
                custom: request.customFilename,
                responseSuggestedFilename: nil,
                sourceURL: request.sourceURL
            )
        } else {
            preferredFilename = nil
        }

        let item = DownloadItem(
            sourceURL: request.sourceURL,
            sourceKind: request.sourceKind,
            backend: backend,
            preferredFilename: preferredFilename,
            destinationFolderPath: request.destinationFolder.path,
            status: request.shouldStartImmediately ? .queued : .paused,
            metadataName: request.mediaMetadata?.title,
            mediaMetadata: request.mediaMetadata,
            mediaFormatPreference: request.mediaFormatPreference
        )

        if request.sourceKind == .magnetLink {
            item.metadataName = MagnetLinkMetadata(url: request.sourceURL).displayName
        }

        downloads.insert(item, at: 0)
        selectedDownloadID = item.id

        if request.shouldStartImmediately {
            startOrQueueDownload(id: item.id)
        } else {
            schedulePersist()
        }
    }

    private func backend(for sourceKind: DownloadSourceKind) -> DownloadBackend {
        switch sourceKind {
        case .directURL:
            .urlSession
        case .magnetLink, .torrentFile:
            .aria2
        case .mediaURL:
            .ytDlp
        }
    }

    func togglePauseResumeForSelection() {
        guard let selectedDownloadID else {
            return
        }

        togglePauseResume(id: selectedDownloadID)
    }

    func togglePauseResume(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if item.status == .browserSessionRequired {
            continueInBrowser(id: id)
            return
        }

        if item.canPause {
            pauseDownload(id: id)
        } else if item.canResume {
            startOrQueueDownload(id: id)
        }
    }

    func retrySelectedDownload() {
        guard let selectedDownloadID else {
            return
        }

        retryDownload(id: selectedDownloadID)
    }

    func retryDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        item.lastError = nil
        item.finishedAt = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            item.fileLocationPath = nil
            if item.status == .completed || item.status == .cancelled {
                item.bytesWritten = 0
                item.expectedBytes = 0
                item.progress = 0
                item.resumeData = nil
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }

            item.backendIdentifier = nil
            item.fileLocationPath = nil
            item.bytesWritten = 0
            item.expectedBytes = 0
            item.progress = 0
        case .ytDlp:
            Task {
                await mediaService.remove(id: id)
            }
            item.backendIdentifier = nil
            item.fileLocationPath = nil
            item.bytesWritten = 0
            item.expectedBytes = item.mediaMetadata?.expectedBytes ?? 0
            item.progress = 0
        }

        startOrQueueDownload(id: id)
    }

    func pauseAll() {
        for item in downloads {
            if item.canPause {
                pauseDownload(id: item.id)
            } else if item.status == .queued {
                setStatus(for: item, to: .paused)
                item.updatedAt = .now
            }
        }

        schedulePersist()
    }

    func resumeAll() {
        downloads
            .filter(\.canResume)
            .forEach { startOrQueueDownload(id: $0.id) }
    }

    func cancelSelectedDownload() {
        guard let selectedDownloadID else {
            return
        }

        cancelDownload(id: selectedDownloadID)
    }

    func cancelDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartIDs.contains(id))

        if activeBrowserSession?.downloadID == id {
            dismissBrowserSession()
        }

        switch item.backend {
        case .urlSession:
            if item.taskIdentifier != nil {
                coordinator.cancelDownload(id: id)
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.cancel(id: id)
            }
        }

        item.taskIdentifier = nil
        item.backendIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now
        transitionStatus(for: item, to: .cancelled)
        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    func removeSelectedDownload() {
        guard let selectedDownloadID else {
            return
        }

        removeDownload(id: selectedDownloadID)
    }

    func removeDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartIDs.contains(id))

        if activeBrowserSession?.downloadID == id {
            dismissBrowserSession()
        }

        switch item.backend {
        case .urlSession:
            if item.taskIdentifier != nil {
                coordinator.cancelDownload(id: id)
            }
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    await torrentService.remove(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.remove(id: id)
            }
        }

        downloads.removeAll { $0.id == id }

        if selectedDownloadID == id {
            selectedDownloadID = filteredDownloads.first?.id ?? downloads.first?.id
        }

        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    func clearCompleted() {
        cleanupBackendIdentifiers(for: downloads.filter { $0.status == .completed })
        downloads.removeAll { $0.status == .completed }
        if selectedDownload?.status == .completed {
            selectedDownloadID = filteredDownloads.first?.id ?? downloads.first?.id
        }
        schedulePersist()
    }

    func clearFailed() {
        cleanupBackendIdentifiers(for: downloads.filter { $0.status == .failed })
        downloads.removeAll { $0.status == .failed }
        if selectedDownload?.status == .failed {
            selectedDownloadID = filteredDownloads.first?.id ?? downloads.first?.id
        }
        schedulePersist()
    }

    func revealSelectedInFinder() {
        guard let selectedDownloadID else {
            return
        }

        revealInFinder(id: selectedDownloadID)
    }

    func revealInFinder(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        if let fileLocationPath = item.fileLocationPath {
            NSWorkspace.shared.selectFile(fileLocationPath, inFileViewerRootedAtPath: "")
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: item.destinationFolderPath)
        }
    }

    func openSelectedDownload() {
        guard let selectedDownloadID else {
            return
        }

        openDownload(id: selectedDownloadID)
    }

    func openDownload(id: UUID) {
        guard let url = item(for: id)?.fileLocationURL else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    func copySourceURL(id: UUID) {
        guard let sourceText = item(for: id)?.sourceDisplayText else {
            return
        }

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sourceText, forType: .string)
    }

    func continueInBrowser(id: UUID) {
        guard let item = item(for: id),
              item.sourceKind == .directURL
        else {
            return
        }

        if let activeBrowserSession, activeBrowserSession.downloadID != id {
            activeAlert = UserAlert(
                title: String(
                    localized: "alert.browserSessionAlreadyOpen.title",
                    defaultValue: "Browser Session Already Open",
                    comment: "Alert title shown when another browser-assisted download is already active."
                ),
                message: String(
                    localized: "alert.browserSessionAlreadyOpen.message",
                    defaultValue: "Finish the current browser-assisted download before starting another one.",
                    comment: "Alert message shown when another browser-assisted download is already active."
                )
            )
            return
        }

        let session = browserCoordinator.startSession(
            downloadID: item.id,
            sourceURL: item.sourceURL,
            displayName: item.displayName
        )

        activeBrowserSession = session
        item.updatedAt = .now
        schedulePersist()
    }

    func dismissBrowserSession() {
        browserCoordinator.cancelSession()
        activeBrowserSession = nil
    }

    private func startOrQueueDownload(id: UUID) {
        guard isShuttingDown == false else {
            return
        }

        guard let item = item(for: id) else {
            return
        }

        if item.backend == .urlSession, item.taskIdentifier != nil {
            return
        }

        if currentRunningDownloadsCount >= settings.transferSettings.maxConcurrentDownloads {
            setStatus(for: item, to: .queued)
            item.updatedAt = .now
            schedulePersist()
            return
        }

        item.lastError = nil
        item.finishedAt = nil
        item.speedBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            setStatus(for: item, to: .preparing)
            item.taskIdentifier = coordinator.startDownload(
                id: item.id,
                sourceURL: item.sourceURL,
                resumeData: item.resumeData
            )
            item.resumeData = nil
            item.startedAt = item.startedAt ?? .now
            schedulePersist()

        case .aria2:
            setStatus(for: item, to: .preparing)
            item.startedAt = item.startedAt ?? .now
            schedulePersist()
            Task { @MainActor [weak self] in
                await self?.startTorrentDownload(id: id)
            }

        case .ytDlp:
            setStatus(for: item, to: .preparing)
            item.startedAt = item.startedAt ?? .now
            mediaStartIDs.insert(id)
            schedulePersist()
            Task { @MainActor [weak self] in
                await self?.startMediaDownload(id: id)
            }
        }
    }

    private func startMediaDownload(id: UUID) async {
        var waitsForMediaStopEvent = false

        defer {
            mediaStartIDs.remove(id)

            if waitsForMediaStopEvent == false {
                if let item = item(for: id),
                   item.status == .paused || item.status == .cancelled {
                    startNextQueuedDownloadsIfNeeded()
                } else if item(for: id) == nil {
                    startNextQueuedDownloadsIfNeeded()
                }
            }
        }

        guard let currentItem = item(for: id),
              currentItem.status == .preparing else {
            return
        }

        do {
            let processIdentifier = try await mediaService.startDownload(
                id: currentItem.id,
                sourceURL: currentItem.sourceURL,
                destinationFolder: currentItem.destinationFolderURL,
                metadata: currentItem.mediaMetadata,
                formatPreference: currentItem.mediaFormatPreference
                    ?? currentItem.mediaMetadata?.defaultFormatPreference
                    ?? .bestMP4
            )

            guard let refreshedItem = item(for: id) else {
                waitsForMediaStopEvent = await mediaService.pause(id: id)
                return
            }

            guard refreshedItem.status == .preparing || refreshedItem.status == .downloading else {
                waitsForMediaStopEvent = await mediaService.pause(id: id)
                return
            }

            refreshedItem.backendIdentifier = String(processIdentifier)
            refreshedItem.updatedAt = .now
            schedulePersist()
        } catch {
            guard let refreshedItem = item(for: id) else {
                return
            }

            refreshedItem.backendIdentifier = nil
            refreshedItem.speedBytesPerSecond = 0
            refreshedItem.uploadBytesPerSecond = 0
            refreshedItem.updatedAt = .now
            refreshedItem.lastError = error.localizedDescription
            transitionStatus(for: refreshedItem, to: .failed)
            presentMediaErrorIfNeeded(error)
            schedulePersist()
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func startTorrentDownload(id: UUID) async {
        guard let currentItem = item(for: id) else {
            return
        }

        guard currentItem.status == .preparing else {
            return
        }

        let startAttemptUpdatedAt = currentItem.updatedAt
        let hadBackendIdentifier = currentItem.backendIdentifier != nil
        var activeBackendIdentifier = currentItem.backendIdentifier

        do {
            if let backendIdentifier = currentItem.backendIdentifier {
                do {
                    try await torrentService.unpause(gid: backendIdentifier)
                } catch {
                    guard isStaleTorrentIdentifierError(error) else {
                        throw error
                    }

                    guard let refreshedItem = item(for: id) else {
                        return
                    }

                    refreshedItem.backendIdentifier = nil
                    let replacementIdentifier = try await torrentService.addDownload(
                        sourceKind: refreshedItem.sourceKind,
                        sourceURL: refreshedItem.sourceURL,
                        destinationFolderPath: refreshedItem.destinationFolderPath
                    )

                    guard item(for: id) != nil else {
                        await torrentService.remove(gid: replacementIdentifier)
                        return
                    }

                    activeBackendIdentifier = replacementIdentifier
                }
            } else {
                let backendIdentifier = try await torrentService.addDownload(
                    sourceKind: currentItem.sourceKind,
                    sourceURL: currentItem.sourceURL,
                    destinationFolderPath: currentItem.destinationFolderPath
                )
                guard item(for: id) != nil else {
                    await torrentService.remove(gid: backendIdentifier)
                    return
                }
                activeBackendIdentifier = backendIdentifier
            }

            guard let refreshedItem = item(for: id),
                  let activeBackendIdentifier else {
                return
            }

            let isSameStartAttempt = refreshedItem.status == .preparing
                && refreshedItem.updatedAt == startAttemptUpdatedAt
            let isSameTorrentAlreadyObserved = refreshedItem.backendIdentifier == activeBackendIdentifier
                && (refreshedItem.status == .downloading || refreshedItem.status == .queued)

            if isSameStartAttempt == false,
               isSameTorrentAlreadyObserved == false {
                await settleStartedTorrent(activeBackendIdentifier, for: refreshedItem)
                return
            }

            refreshedItem.backendIdentifier = activeBackendIdentifier
            setStatus(for: refreshedItem, to: .downloading)
            refreshedItem.updatedAt = .now
            schedulePersist()
        } catch {
            guard let refreshedItem = item(for: id) else {
                return
            }

            if hadBackendIdentifier, isTransientTorrentEngineError(error) {
                setStatus(for: refreshedItem, to: .paused)
                refreshedItem.speedBytesPerSecond = 0
                refreshedItem.uploadBytesPerSecond = 0
                refreshedItem.updatedAt = .now
                refreshedItem.lastError = error.localizedDescription
                schedulePersist()
                return
            }

            refreshedItem.backendIdentifier = nil
            refreshedItem.speedBytesPerSecond = 0
            refreshedItem.uploadBytesPerSecond = 0
            refreshedItem.updatedAt = .now
            refreshedItem.lastError = error.localizedDescription
            transitionStatus(for: refreshedItem, to: .failed)
            presentTorrentErrorIfNeeded(error)
            schedulePersist()
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private func settleStartedTorrent(
        _ backendIdentifier: String,
        for item: DownloadItem
    ) async {
        switch item.status {
        case .paused:
            item.backendIdentifier = backendIdentifier
            try? await torrentService.pause(gid: backendIdentifier)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            schedulePersist()

        case .cancelled, .completed, .failed, .browserSessionRequired:
            await torrentService.remove(gid: backendIdentifier)
            if item.backendIdentifier == backendIdentifier {
                item.backendIdentifier = nil
            }
            schedulePersist()

        case .queued, .preparing, .downloading:
            await torrentService.remove(gid: backendIdentifier)
            if item.backendIdentifier == backendIdentifier {
                item.backendIdentifier = nil
                schedulePersist()
            }
        }
    }

    private func pauseDownload(id: UUID) {
        guard let item = item(for: id) else {
            return
        }

        let shouldWaitForMediaProcess = item.backend == .ytDlp
            && (item.backendIdentifier != nil || mediaStartIDs.contains(id))

        setStatus(for: item, to: .paused)
        item.taskIdentifier = nil
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.updatedAt = .now

        switch item.backend {
        case .urlSession:
            coordinator.pauseDownload(id: id)
        case .aria2:
            if let backendIdentifier = item.backendIdentifier {
                Task {
                    try? await torrentService.pause(gid: backendIdentifier)
                }
            }
        case .ytDlp:
            Task {
                await mediaService.pause(id: id)
            }
        }

        schedulePersist()
        if shouldWaitForMediaProcess == false {
            startNextQueuedDownloadsIfNeeded()
        }
    }

    private var currentRunningDownloadsCount: Int {
        downloads.filter(\.isRunning).count
    }

    private func startNextQueuedDownloadsIfNeeded() {
        guard isShuttingDown == false else {
            return
        }

        let availableSlots = max(settings.transferSettings.maxConcurrentDownloads - currentRunningDownloadsCount, 0)
        guard availableSlots > 0 else {
            return
        }

        let queuedItems = downloads
            .filter { $0.status == .queued }
            .sorted { $0.createdAt < $1.createdAt }

        for item in queuedItems.prefix(availableSlots) {
            startOrQueueDownload(id: item.id)
        }
    }

    private func applyTransferSettings(_ transferSettings: DownloadTransferSettings) {
        coordinator.updateTransferSettings(transferSettings)

        let activeTorrentIdentifiers = downloads
            .filter { $0.backend == .aria2 }
            .compactMap(\.backendIdentifier)

        Task { [torrentService] in
            await torrentService.updateTransferSettings(
                transferSettings,
                activeGIDs: activeTorrentIdentifiers
            )
        }

        startNextQueuedDownloadsIfNeeded()
    }

    private func startTorrentRefreshLoopIfNeeded() {
        guard torrentRefreshTask == nil else {
            return
        }

        torrentRefreshTask = Task { [weak self] in
            while Task.isCancelled == false {
                await self?.refreshTorrentDownloads()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func refreshTorrentDownloads() async {
        let torrentItems = downloads.filter {
            $0.backend == .aria2 && $0.backendIdentifier != nil
        }

        guard torrentItems.isEmpty == false else {
            return
        }

        var didMutate = false

        for item in torrentItems {
            guard let backendIdentifier = item.backendIdentifier else {
                continue
            }

            do {
                let snapshot = try await torrentService.status(for: backendIdentifier)
                apply(snapshot: snapshot, to: item)
                didMutate = true
            } catch {
                if isStaleTorrentIdentifierError(error) {
                    item.backendIdentifier = nil
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.updatedAt = .now
                    item.lastError = String(
                        localized: "torrent.restart.resumeToContinue",
                        defaultValue: "Torrent engine restarted. Resume to continue.",
                        comment: "Status message shown after the torrent engine restarts and a transfer can be resumed."
                    )
                    setStatus(for: item, to: .paused)
                    didMutate = true
                    continue
                }

                if isTransientTorrentEngineError(error) {
                    item.speedBytesPerSecond = 0
                    item.uploadBytesPerSecond = 0
                    item.updatedAt = .now
                    item.lastError = error.localizedDescription
                    didMutate = true
                    continue
                }

                item.backendIdentifier = nil
                item.speedBytesPerSecond = 0
                item.uploadBytesPerSecond = 0
                item.updatedAt = .now
                item.lastError = error.localizedDescription
                transitionStatus(for: item, to: .failed)
                didMutate = true
            }
        }

        if didMutate {
            schedulePersist()
        }
    }

    private func apply(snapshot: TorrentStatusSnapshot, to item: DownloadItem) {
        item.bytesWritten = snapshot.completedLength
        item.expectedBytes = max(snapshot.totalLength, 0)
        if snapshot.totalLength > 0 {
            item.progress = Double(snapshot.completedLength) / Double(snapshot.totalLength)
        }
        item.speedBytesPerSecond = snapshot.downloadSpeed
        item.uploadBytesPerSecond = snapshot.uploadSpeed
        item.metadataName = snapshot.metadataName ?? item.metadataName
        item.updatedAt = .now

        if let primaryPath = snapshot.primaryPath {
            item.fileLocationPath = primaryPath
        }

        switch snapshot.status {
        case "active":
            setStatus(for: item, to: .downloading)
            item.lastError = nil

        case "waiting":
            setStatus(for: item, to: .queued)

        case "paused":
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0

        case "error":
            item.lastError = snapshot.errorMessage ?? String(
                localized: "torrent.error.generic",
                defaultValue: "Torrent engine reported an error.",
                comment: "Fallback error message shown when the torrent engine reports an error without details."
            )
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            let gid = snapshot.gid
            item.backendIdentifier = nil
            transitionStatus(for: item, to: .failed)
            Task {
                await torrentService.remove(gid: gid)
            }
            startNextQueuedDownloadsIfNeeded()

        case "complete":
            item.progress = 1
            item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
            item.finishedAt = item.finishedAt ?? .now
            item.lastError = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            let gid = snapshot.gid
            item.backendIdentifier = nil
            transitionStatus(for: item, to: .completed)
            Task {
                await torrentService.remove(gid: gid)
            }
            startNextQueuedDownloadsIfNeeded()

        case "removed":
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.backendIdentifier = nil
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        default:
            break
        }
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case let .started(id, taskIdentifier):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = taskIdentifier
            setStatus(for: item, to: .downloading)
            item.updatedAt = .now
            item.uploadBytesPerSecond = 0

        case let .progress(id, bytesWritten, expectedBytes, speedBytesPerSecond):
            guard let item = item(for: id) else {
                return
            }

            item.bytesWritten = bytesWritten
            item.expectedBytes = max(expectedBytes, item.expectedBytes)
            if expectedBytes > 0 {
                item.progress = Double(bytesWritten) / Double(expectedBytes)
            }
            item.speedBytesPerSecond = speedBytesPerSecond
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .paused(id, resumeData):
            guard let item = item(for: id) else {
                return
            }

            item.resumeData = resumeData
            item.taskIdentifier = nil
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .cancelled(id):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message, resumeData):
            guard let item = item(for: id) else {
                return
            }

            item.taskIdentifier = nil
            item.lastError = message
            item.resumeData = resumeData
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()

        case let .finished(id, temporaryURL, suggestedFilename, responseMimeType, statusCode):
            guard let item = item(for: id) else {
                return
            }

            do {
                try finalizeFileDownload(
                    for: item,
                    temporaryURL: temporaryURL,
                    suggestedFilename: suggestedFilename,
                    responseMimeType: responseMimeType,
                    statusCode: statusCode
                )
            } catch let error as DirectDownloadValidationError {
                switch error {
                case let .browserSessionRequired(message):
                    markBrowserSessionRequired(item, message: message)
                    try? FileManager.default.removeItem(at: temporaryURL)
                case .invalidResponse:
                    item.lastError = error.localizedDescription
                    transitionStatus(for: item, to: .failed)
                    try? FileManager.default.removeItem(at: temporaryURL)
                }
            } catch {
                item.lastError = error.localizedDescription
                transitionStatus(for: item, to: .failed)
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            item.taskIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func handle(_ event: BrowserDownloadEvent) {
        switch event {
        case let .started(id, _, expectedBytes, _, _):
            guard let item = item(for: id) else {
                return
            }

            activeBrowserSession = nil
            setStatus(for: item, to: .downloading)
            item.progress = 0
            item.bytesWritten = 0
            if expectedBytes > 0 {
                item.expectedBytes = max(item.expectedBytes, expectedBytes)
            }
            item.lastError = nil
            item.resumeData = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            item.startedAt = item.startedAt ?? .now

        case let .finished(id, temporaryURL, suggestedFilename, responseMimeType, statusCode, expectedBytes):
            guard let item = item(for: id) else {
                return
            }

            do {
                try finalizeFileDownload(
                    for: item,
                    temporaryURL: temporaryURL,
                    suggestedFilename: suggestedFilename,
                    responseMimeType: responseMimeType,
                    statusCode: statusCode,
                    expectedBytesOverride: expectedBytes
                )
            } catch {
                item.lastError = error.localizedDescription
                transitionStatus(for: item, to: .failed)
                try? FileManager.default.removeItem(at: temporaryURL)
            }

            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message):
            activeBrowserSession = nil

            guard let item = item(for: id) else {
                return
            }

            item.lastError = message
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func handle(_ event: MediaDownloadEvent) {
        if let id = mediaDownloadID(from: event),
           item(for: id) == nil {
            if mediaEventReleasesQueueSlot(event) {
                startNextQueuedDownloadsIfNeeded()
            }
            return
        }

        switch event {
        case let .started(id, processIdentifier, expectedBytes, title, _):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = String(processIdentifier)
            item.metadataName = title ?? item.metadataName
            if expectedBytes > 0 {
                item.expectedBytes = max(item.expectedBytes, expectedBytes)
            }
            setStatus(for: item, to: .downloading)
            item.lastError = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .progress(id, bytesWritten, expectedBytes, speedBytesPerSecond):
            guard let item = item(for: id) else {
                return
            }

            item.bytesWritten = max(item.bytesWritten, bytesWritten)
            item.expectedBytes = max(item.expectedBytes, expectedBytes)
            if item.expectedBytes > 0 {
                item.progress = Double(item.bytesWritten) / Double(item.expectedBytes)
            }
            item.speedBytesPerSecond = speedBytesPerSecond
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now

        case let .paused(id):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            setStatus(for: item, to: .paused)
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            startNextQueuedDownloadsIfNeeded()

        case let .cancelled(id):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .cancelled)
            startNextQueuedDownloadsIfNeeded()

        case let .finished(id, fileURL, expectedBytes):
            guard let item = item(for: id) else {
                return
            }

            item.fileLocationPath = fileURL.path
            item.preferredFilename = fileURL.lastPathComponent
            item.progress = 1
            item.expectedBytes = max(item.expectedBytes, expectedBytes, item.bytesWritten)
            item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
            item.finishedAt = .now
            item.lastError = nil
            item.backendIdentifier = nil
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .completed)
            startNextQueuedDownloadsIfNeeded()

        case let .failed(id, message):
            guard let item = item(for: id) else {
                return
            }

            item.backendIdentifier = nil
            item.lastError = message
            item.speedBytesPerSecond = 0
            item.uploadBytesPerSecond = 0
            item.updatedAt = .now
            transitionStatus(for: item, to: .failed)
            startNextQueuedDownloadsIfNeeded()
        }

        schedulePersist()
    }

    private func mediaDownloadID(from event: MediaDownloadEvent) -> UUID? {
        switch event {
        case let .started(id, _, _, _, _),
             let .progress(id, _, _, _),
             let .paused(id),
             let .cancelled(id),
             let .finished(id, _, _),
             let .failed(id, _):
            id
        }
    }

    private func mediaEventReleasesQueueSlot(_ event: MediaDownloadEvent) -> Bool {
        switch event {
        case .paused, .cancelled, .finished, .failed:
            true
        case .started, .progress:
            false
        }
    }

    private func item(for id: UUID) -> DownloadItem? {
        downloads.first { $0.id == id }
    }

    private func finalizeFileDownload(
        for item: DownloadItem,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?,
        expectedBytesOverride: Int64? = nil
    ) throws {
        try validateDownloadedPayload(
            for: item,
            temporaryURL: temporaryURL,
            suggestedFilename: suggestedFilename,
            responseMimeType: responseMimeType,
            statusCode: statusCode
        )

        let destinationURL = try destinationResolver.moveDownloadedFile(
            from: temporaryURL,
            customFilename: item.preferredFilename,
            responseSuggestedFilename: suggestedFilename,
            sourceURL: item.sourceURL,
            into: item.destinationFolderURL
        )

        let expectedBytes = max(item.expectedBytes, expectedBytesOverride ?? 0)

        item.fileLocationPath = destinationURL.path
        item.preferredFilename = destinationURL.lastPathComponent
        item.progress = 1
        item.expectedBytes = max(expectedBytes, item.bytesWritten)
        item.bytesWritten = max(item.bytesWritten, item.expectedBytes)
        item.finishedAt = .now
        item.lastError = nil
        item.resumeData = nil
        transitionStatus(for: item, to: .completed)
    }

    private func markBrowserSessionRequired(_ item: DownloadItem, message: String) {
        item.taskIdentifier = nil
        setStatus(for: item, to: .browserSessionRequired)
        item.progress = 0
        item.bytesWritten = 0
        item.expectedBytes = 0
        item.speedBytesPerSecond = 0
        item.uploadBytesPerSecond = 0
        item.lastError = message
        item.resumeData = nil
        item.updatedAt = .now
    }

    private func validateDownloadedPayload(
        for item: DownloadItem,
        temporaryURL: URL,
        suggestedFilename: String?,
        responseMimeType: String?,
        statusCode: Int?
    ) throws {
        guard item.backend == .urlSession else {
            return
        }

        if let statusCode, (200 ... 299).contains(statusCode) == false {
            let template = String(
                localized: "error.direct.httpStatus",
                defaultValue: "The server returned HTTP %d instead of a downloadable file.",
                comment: "Download validation error. Parameter is an HTTP status code."
            )

            throw DirectDownloadValidationError.invalidResponse(
                String(format: template, statusCode)
            )
        }

        guard shouldAllowHTMLDownload(for: item, suggestedFilename: suggestedFilename) == false else {
            return
        }

        let normalizedMimeType = responseMimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isHTMLMimeType = normalizedMimeType == "text/html"
            || normalizedMimeType == "application/xhtml+xml"

        if isHTMLMimeType || payloadLooksLikeHTML(at: temporaryURL) {
            throw DirectDownloadValidationError.browserSessionRequired(
                String(
                    localized: "error.direct.browserSessionRequired",
                    defaultValue: "This site requires a browser session before Harbor can download the file.",
                    comment: "Download validation error shown when a site requires browser authentication before downloading."
                )
            )
        }
    }

    private func shouldAllowHTMLDownload(
        for item: DownloadItem,
        suggestedFilename: String?
    ) -> Bool {
        let extensions = [
            item.preferredFilename.flatMap {
                let pathExtension = URL(fileURLWithPath: $0).pathExtension
                return pathExtension.isEmpty ? nil : pathExtension
            },
            suggestedFilename.flatMap {
                let pathExtension = URL(fileURLWithPath: $0).pathExtension
                return pathExtension.isEmpty ? nil : pathExtension
            },
            item.sourceURL.pathExtension.isEmpty ? nil : item.sourceURL.pathExtension
        ]
            .compactMap { $0?.lowercased() }

        return extensions.contains("html") || extensions.contains("htm")
    }

    private func payloadLooksLikeHTML(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return false
        }

        defer {
            try? handle.close()
        }

        guard let data = try? handle.read(upToCount: 1024),
              let sample = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
        else {
            return false
        }

        return sample.hasPrefix("<!doctype html")
            || sample.hasPrefix("<html")
            || sample.contains("<html")
    }

    private func presentNextQueuedExternalAddSheetIfNeeded() {
        guard addSheetDraft == nil,
              pendingExternalAddSheetDrafts.isEmpty == false
        else {
            return
        }

        addSheetDraft = pendingExternalAddSheetDrafts.removeFirst()
    }

    private func makeBlankAddSheetDraft() -> AddDownloadSheetDraft {
        AddDownloadSheetDraft.blank(
            destinationFolderURL: settings.defaultDestinationURL,
            shouldStartImmediately: settings.startDownloadsAutomatically
        )
    }

    private func makeExternalTorrentDraft(for fileURL: URL) -> AddDownloadSheetDraft {
        AddDownloadSheetDraft.torrentFile(
            fileURL,
            destinationFolderURL: settings.defaultDestinationURL,
            shouldStartImmediately: settings.startDownloadsAutomatically
        )
    }

    private func makeExternalAddSheetDraft(for url: URL) -> AddDownloadSheetDraft? {
        switch DownloadSourceKind.detect(from: url) {
        case .magnetLink:
            AddDownloadSheetDraft.linkOrMagnet(
                url,
                destinationFolderURL: settings.defaultDestinationURL,
                shouldStartImmediately: settings.startDownloadsAutomatically
            )
        case .torrentFile:
            makeExternalTorrentDraft(for: url)
        case .directURL:
            AddDownloadSheetDraft.linkOrMagnet(
                url,
                destinationFolderURL: settings.defaultDestinationURL,
                shouldStartImmediately: settings.startDownloadsAutomatically
            )
        case .mediaURL, nil:
            nil
        }
    }

    private func transitionStatus(
        for item: DownloadItem,
        to status: DownloadStatus
    ) {
        let previousStatus = item.status
        setStatus(for: item, to: status)

        guard previousStatus != status,
              status == .completed || status == .failed || status == .cancelled,
              settings.notificationsEnabled,
              let payload = notificationPayload(for: item, status: status)
        else {
            return
        }

        Task { [notificationService] in
            await notificationService.deliver(payload)
        }
    }

    private func setStatus(
        for item: DownloadItem,
        to status: DownloadStatus
    ) {
        let previousStatus = item.status
        item.status = status

        guard previousStatus != status,
              let activityKind = activityKind(from: previousStatus, to: status)
        else {
            return
        }

        item.recordActivity(activityKind)
    }

    private func activityKind(
        from previousStatus: DownloadStatus,
        to status: DownloadStatus
    ) -> DownloadActivityKind? {
        switch status {
        case .queued:
            .queued
        case .preparing:
            previousStatus == .paused || previousStatus == .browserSessionRequired ? .resumed : .started
        case .downloading:
            if previousStatus == .paused || previousStatus == .browserSessionRequired {
                .resumed
            } else if previousStatus == .queued {
                .started
            } else {
                nil
            }
        case .browserSessionRequired:
            .browserSessionRequired
        case .paused:
            .paused
        case .completed:
            .completed
        case .failed:
            .failed
        case .cancelled:
            .cancelled
        }
    }

    private func notificationPayload(
        for item: DownloadItem,
        status: DownloadStatus
    ) -> DownloadNotificationPayload? {
        let title: String
        let body: String

        switch status {
        case .completed:
            title = String(
                localized: "notification.downloadFinished.title",
                defaultValue: "Download Finished",
                comment: "Notification title for a completed download."
            )
            body = String(
                format: String(
                    localized: "notification.downloadFinished.body",
                    defaultValue: "%@ is ready.",
                    comment: "Notification body for a completed download. Parameter is the download name."
                ),
                item.displayName
            )
        case .failed:
            title = String(
                localized: "notification.downloadFailed.title",
                defaultValue: "Download Failed",
                comment: "Notification title for a failed download."
            )
            body = item.displayLastError ?? String(
                format: String(
                    localized: "notification.downloadFailed.body",
                    defaultValue: "%@ couldn’t be downloaded.",
                    comment: "Notification body for a failed download. Parameter is the download name."
                ),
                item.displayName
            )
        case .cancelled:
            title = String(
                localized: "notification.downloadCancelled.title",
                defaultValue: "Download Cancelled",
                comment: "Notification title for a cancelled download."
            )
            body = String(
                format: String(
                    localized: "notification.downloadCancelled.body",
                    defaultValue: "%@ was cancelled.",
                    comment: "Notification body for a cancelled download. Parameter is the download name."
                ),
                item.displayName
            )
        case .queued, .preparing, .downloading, .browserSessionRequired, .paused:
            return nil
        }

        return DownloadNotificationPayload(
            identifier: "download-\(item.id.uuidString)-\(UUID().uuidString)",
            title: title,
            body: body
        )
    }

    private func cleanupBackendIdentifiers(for items: [DownloadItem]) {
        let backendIdentifiers = items
            .filter { $0.backend == .aria2 }
            .compactMap(\.backendIdentifier)

        let mediaIDs = items
            .filter { $0.backend == .ytDlp }
            .map(\.id)

        guard backendIdentifiers.isEmpty == false || mediaIDs.isEmpty == false else {
            return
        }

        Task {
            for backendIdentifier in backendIdentifiers {
                await torrentService.remove(gid: backendIdentifier)
            }

            for id in mediaIDs {
                await mediaService.remove(id: id)
            }
        }
    }

    private func presentMediaErrorIfNeeded(_ error: Error) {
        if hasShownMediaRuntimeAlert,
           case MediaDownloadError.runtimeNotFound = error {
            return
        }

        if case MediaDownloadError.runtimeNotFound = error {
            hasShownMediaRuntimeAlert = true
        }

        activeAlert = UserAlert(
            title: mediaErrorTitle(for: error),
            message: DownloadItem.displayErrorMessage(from: error.localizedDescription)
        )
    }

    private func presentTorrentErrorIfNeeded(_ error: Error) {
        if hasShownTorrentBinaryAlert,
           case TorrentEngineError.binaryNotFound = error {
            return
        }

        if case TorrentEngineError.binaryNotFound = error {
            hasShownTorrentBinaryAlert = true
        }

        activeAlert = UserAlert(
            title: torrentErrorTitle(for: error),
            message: DownloadItem.displayErrorMessage(from: error.localizedDescription)
        )
    }

    private func isTransientTorrentEngineError(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet:
                return true
            default:
                break
            }
        }

        if case let TorrentEngineError.startupFailed(message) = error {
            return message.localizedCaseInsensitiveContains("timed out")
        }

        return false
    }

    private func isStaleTorrentIdentifierError(_ error: Error) -> Bool {
        guard case let TorrentEngineError.rpc(message) = error else {
            return false
        }

        let normalizedMessage = message.lowercased()
        return normalizedMessage.contains("gid")
            && (
                normalizedMessage.contains("not found")
                    || normalizedMessage.contains("no such")
                    || normalizedMessage.contains("not exist")
            )
    }

    private func mediaErrorTitle(for error: Error) -> String {
        if case MediaDownloadError.runtimeNotFound = error {
            return String(
                localized: "alert.media.missingRuntime.title",
                defaultValue: "Media Support Needs yt-dlp",
                comment: "Alert title shown when the bundled yt-dlp media runtime cannot be found."
            )
        }

        return String(
            localized: "alert.media.engineError.title",
            defaultValue: "Media Engine Error",
            comment: "Alert title shown when the media backend reports an error."
        )
    }

    private func torrentErrorTitle(for error: Error) -> String {
        if case TorrentEngineError.binaryNotFound = error {
            return String(
                localized: "alert.torrent.missingAria2.title",
                defaultValue: "Torrent Support Needs aria2",
                comment: "Alert title shown when the bundled aria2 torrent runtime cannot be found."
            )
        }

        return String(
            localized: "alert.torrent.engineError.title",
            defaultValue: "Torrent Engine Error",
            comment: "Alert title shown when the torrent backend reports an error."
        )
    }

    private func schedulePersist() {
        let records = downloads.map { $0.makeRecord() }

        persistTask?.cancel()
        persistTask = Task { [persistence] in
            try? await Task.sleep(for: .milliseconds(250))
            try? await persistence.save(records)
        }
    }
}

private enum DirectDownloadValidationError: LocalizedError {
    case invalidResponse(String)
    case browserSessionRequired(String)

    var errorDescription: String? {
        switch self {
        case let .invalidResponse(message), let .browserSessionRequired(message):
            message
        }
    }
}
