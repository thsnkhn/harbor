import Foundation
import Observation
import WebKit

enum BrowserDownloadEvent: Sendable {
    case started(
        id: UUID,
        attemptIdentifier: UUID,
        suggestedFilename: String?,
        expectedBytes: Int64,
        responseMimeType: String?,
        statusCode: Int?,
        isResumed: Bool
    )
    case finished(
        id: UUID,
        attemptIdentifier: UUID,
        handoff: CompletedDownloadHandoff
    )
    case failed(id: UUID, attemptIdentifier: UUID, failure: DirectDownloadFailure)
    case dismissed(id: UUID, attemptIdentifier: UUID, resumeData: Data?)
    case completionUnavailable(id: UUID, attemptIdentifier: UUID, message: String)
    case quiescenceFailed(id: UUID, attemptIdentifier: UUID, message: String)
    case quiescedAfterTimeout(
        id: UUID,
        attemptIdentifier: UUID,
        resumeData: Data?,
        wasCancelling: Bool
    )
}

struct BrowserDownloadQuiescence: Sendable {
    let attemptIdentifier: UUID
    let resumeData: Data?
    let completionUnavailableMessage: String?
    let writerQuiescenceUnavailableMessage: String?

    init(
        attemptIdentifier: UUID,
        resumeData: Data?,
        completionUnavailableMessage: String? = nil,
        writerQuiescenceUnavailableMessage: String? = nil
    ) {
        self.attemptIdentifier = attemptIdentifier
        self.resumeData = resumeData
        self.completionUnavailableMessage = completionUnavailableMessage
        self.writerQuiescenceUnavailableMessage = writerQuiescenceUnavailableMessage
    }
}

@MainActor
@Observable
final class BrowserDownloadSession: Identifiable {
    let id = UUID()
    let downloadID: UUID
    let attemptIdentifier: UUID
    let sourceURL: URL
    let displayName: String

    @ObservationIgnored let webView: WKWebView

    var currentURL: URL?
    var pageTitle: String?
    var statusMessage = "Complete any required sign-in or verification. Harbor will capture the file automatically."
    var isLoading = true

    fileprivate var hasStartedDownload = false

    init(
        downloadID: UUID,
        attemptIdentifier: UUID,
        sourceURL: URL,
        displayName: String,
        webView: WKWebView
    ) {
        self.downloadID = downloadID
        self.attemptIdentifier = attemptIdentifier
        self.sourceURL = sourceURL
        self.displayName = displayName
        self.webView = webView
        self.currentURL = sourceURL
    }
}

@MainActor
final class BrowserDownloadCoordinator: NSObject {
    typealias ResumeCompletion = @MainActor @Sendable (WKDownload) -> Void
    typealias ResumeDownload = @MainActor (
        WKWebView,
        Data,
        @escaping ResumeCompletion
    ) -> Void
    typealias CancelUnownedDownload = @MainActor (WKDownload) -> Void

    private enum TerminationReason {
        case pause
        case cancel
    }

    private struct DownloadContext {
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let webView: WKWebView
        let isResumeAttempt: Bool
        let originalResumeData: Data?
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var httpResponse: HTTPURLResponse?
        var expectedBytes: Int64
        var temporaryURL: URL?
        var terminationReason: TerminationReason?
        var rejectionError: Error?
    }

    private struct PendingResume {
        let session: BrowserDownloadSession
        let resumeData: Data
    }

    private struct CompletionPublication {
        let attemptIdentifier: UUID
        let task: Task<BrowserDownloadEvent, Never>
    }

    private enum PendingStopKind {
        case resume(Data)
        case navigation
    }

    private struct PendingStop {
        let session: BrowserDownloadSession
        let kind: PendingStopKind
        var reason: TerminationReason
        var waiters: [(Data?) -> Void]
    }

    private struct ActiveDownloadStopResult {
        let resumeData: Data?
        let writerQuiescenceUnavailableMessage: String?
    }

    private struct ActiveDownloadStopFailure {
        let attemptIdentifier: UUID
        let message: String
    }

    private struct ActiveDownloadHandle {
        let owner: AnyObject
        let identity: ObjectIdentifier
        let cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    }

    private let fileManager: FileManager
    private let temporaryDirectory: URL
    private let completedHandoffStore: CompletedDownloadHandoffStore
    private let onEvent: @MainActor (BrowserDownloadEvent) -> Void
    private let resumeDownload: ResumeDownload
    private let cancelUnownedDownload: CancelUnownedDownload

    private var activeSession: BrowserDownloadSession?
    private var pendingResumes: [UUID: PendingResume] = [:]
    private var pendingNavigationConversions: [UUID: BrowserDownloadSession] = [:]
    private var pendingStops: [UUID: PendingStop] = [:]
    private var downloadContexts: [ObjectIdentifier: DownloadContext] = [:]
    private var activeDownloadsByID: [UUID: ActiveDownloadHandle] = [:]
    private var stopWaiters: [UUID: [(ActiveDownloadStopResult) -> Void]] = [:]
    private var activeDownloadStopFailures: [UUID: ActiveDownloadStopFailure] = [:]
    private var completedActiveStopResults: [UUID: (UUID, ActiveDownloadStopResult)] = [:]
    private var completionPublications: [UUID: CompletionPublication] = [:]
    private var completionPublicationFailures: [UUID: (UUID, String)] = [:]
    private var acceptsResumeCallbacks = true
    private var isQuiescingForShutdown = false

    init(
        fileManager: FileManager = .default,
        temporaryDirectory: URL? = nil,
        completedHandoffStore: CompletedDownloadHandoffStore? = nil,
        resumeDownload: @escaping ResumeDownload = { webView, resumeData, completion in
            webView.resumeDownload(fromResumeData: resumeData, completionHandler: completion)
        },
        cancelUnownedDownload: @escaping CancelUnownedDownload = { download in
            download.cancel { _ in }
        },
        onEvent: @escaping @MainActor (BrowserDownloadEvent) -> Void
    ) {
        let resolvedTemporaryDirectory = temporaryDirectory
            ?? HarborApplicationSupport.directoryURL(fileManager: fileManager)
                .appendingPathComponent("BrowserDownloadRecovery", isDirectory: true)
        let resolvedHandoffStore = completedHandoffStore
            ?? CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: temporaryDirectory
            )
        self.fileManager = fileManager
        self.temporaryDirectory = resolvedTemporaryDirectory
        self.completedHandoffStore = resolvedHandoffStore
        self.resumeDownload = resumeDownload
        self.cancelUnownedDownload = cancelUnownedDownload
        self.onEvent = onEvent

        super.init()
    }

    func startSession(
        downloadID: UUID,
        attemptIdentifier: UUID = UUID(),
        sourceURL: URL,
        displayName: String,
        resumeData: Data? = nil
    ) -> BrowserDownloadSession {
        acceptsResumeCallbacks = true

        if completedActiveStopResults[downloadID]?.0 != attemptIdentifier {
            completedActiveStopResults.removeValue(forKey: downloadID)
        }

        if let activeSession,
           activeSession.downloadID == downloadID,
           activeSession.attemptIdentifier == attemptIdentifier {
            return activeSession
        }

        if let pending = pendingResumes[downloadID] {
            if pending.session.attemptIdentifier == attemptIdentifier {
                cancelSession()
                activeSession = pending.session
                return pending.session
            }

            // A new DownloadCenter attempt must never inherit a WebKit
            // callback that was registered for a retired token. Detach the
            // old callback now; if WebKit invokes it later, ownership checks
            // cancel the resulting WKDownload as unowned.
            abandonPendingResume(downloadID: downloadID, pending: pending)
        }

        cancelSession()

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        let session = BrowserDownloadSession(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            displayName: displayName,
            webView: webView
        )

        activeSession = session

        if let resumeData {
            session.statusMessage = "Resuming secure browser-backed download…"
            session.isLoading = false
            pendingResumes[downloadID] = PendingResume(
                session: session,
                resumeData: resumeData
            )
            resumeDownload(webView, resumeData) { [weak self, weak session, weak webView] download in
                guard let self, let session, let webView else {
                    download.cancel { _ in }
                    return
                }

                if self.cancelPendingResumeDownloadIfNeeded(
                    download,
                    downloadID: downloadID,
                    attemptIdentifier: attemptIdentifier,
                    session: session,
                    webView: webView
                ) {
                    return
                }

                guard self.acceptsResumeCallbacks,
                      self.claimPendingResume(
                        downloadID: downloadID,
                        attemptIdentifier: attemptIdentifier,
                        session: session,
                        webView: webView
                      ) else {
                    self.cancelUnownedDownload(download)
                    return
                }

                self.track(
                    download: download,
                    for: session,
                    isResumeAttempt: true,
                    originalResumeData: resumeData
                )
            }
        } else {
            webView.load(URLRequest(url: sourceURL))
        }
        return session
    }

    func claimPendingResume(
        downloadID: UUID,
        attemptIdentifier: UUID? = nil,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        guard let pending = pendingResumes[downloadID],
              pending.session.id == session.id,
              pendingStops[downloadID] == nil,
              attemptIdentifier == nil
                || pending.session.attemptIdentifier == attemptIdentifier else {
            return false
        }

        pendingResumes.removeValue(forKey: downloadID)
        return activeSession?.id == session.id
            && activeSession?.webView === webView
            && session.webView === webView
    }

    func cancelSession() {
        if let session = activeSession {
            pendingNavigationConversions.removeValue(forKey: session.downloadID)
            if case .navigation? = pendingStops[session.downloadID]?.kind {
                pendingStops.removeValue(forKey: session.downloadID)
            }
        }
        activeSession?.webView.stopLoading()
        activeSession = nil
    }

    func hasActiveDownload(id: UUID) -> Bool {
        activeDownloadsByID[id] != nil
    }

    func hasPendingOrActiveAttempt(id: UUID) -> Bool {
        pendingResumes[id] != nil
            || activeDownloadsByID[id] != nil
            || completionPublications[id] != nil
            || activeSession?.downloadID == id
    }

    func quiesceDownload(id: UUID, cancelling: Bool = false) async -> BrowserDownloadQuiescence? {
        if let completed = completedActiveStopResults[id] {
            if let currentAttemptIdentifier = currentAttemptIdentifier(for: id),
               currentAttemptIdentifier != completed.0 {
                completedActiveStopResults.removeValue(forKey: id)
            } else {
                completedActiveStopResults.removeValue(forKey: id)
                return BrowserDownloadQuiescence(
                    attemptIdentifier: completed.0,
                    resumeData: completed.1.resumeData,
                    writerQuiescenceUnavailableMessage: completed.1.writerQuiescenceUnavailableMessage
                )
            }
        }
        if let failure = completionPublicationFailures[id] {
            return BrowserDownloadQuiescence(
                attemptIdentifier: failure.0,
                resumeData: nil,
                completionUnavailableMessage: takeCompletionPublicationFailure(
                    id: id,
                    attemptIdentifier: failure.0
                )
            )
        }

        if let publication = completionPublications[id] {
            _ = await deliverCompletionPublication(
                id: id,
                attemptIdentifier: publication.attemptIdentifier
            )
            return BrowserDownloadQuiescence(
                attemptIdentifier: publication.attemptIdentifier,
                resumeData: nil,
                completionUnavailableMessage: takeCompletionPublicationFailure(
                    id: id,
                    attemptIdentifier: publication.attemptIdentifier
                )
            )
        }

        if let pendingSession = pendingResumes[id]?.session ?? pendingNavigationConversions[id] {
            let resumeData: Data? = await withCheckedContinuation { continuation in
                _ = requestPendingStop(
                    id: id,
                    reason: cancelling ? .cancel : .pause,
                    completion: { continuation.resume(returning: $0) }
                )
            }
            return BrowserDownloadQuiescence(
                attemptIdentifier: pendingSession.attemptIdentifier,
                resumeData: resumeData
            )
        }

        if let session = activeSession, session.downloadID == id,
           activeDownloadsByID[id] == nil {
            session.webView.stopLoading()
            activeSession = nil
            return BrowserDownloadQuiescence(
                attemptIdentifier: session.attemptIdentifier,
                resumeData: nil
            )
        }

        guard let download = activeDownloadsByID[id],
              let context = downloadContexts[download.identity] else {
            if let failure = completionPublicationFailures[id] {
                return BrowserDownloadQuiescence(
                    attemptIdentifier: failure.0,
                    resumeData: nil,
                    completionUnavailableMessage: takeCompletionPublicationFailure(
                        id: id,
                        attemptIdentifier: failure.0
                    )
                )
            }
            return nil
        }
        let stopResult: ActiveDownloadStopResult = await withCheckedContinuation { continuation in
            _ = requestStop(
                id: id,
                reason: cancelling ? .cancel : .pause,
                completion: { continuation.resume(returning: $0) }
            )
        }
        if let publication = completionPublications[id] {
            _ = await deliverCompletionPublication(
                id: id,
                attemptIdentifier: publication.attemptIdentifier
            )
        }
        return BrowserDownloadQuiescence(
            attemptIdentifier: context.attemptIdentifier,
            resumeData: stopResult.resumeData,
            completionUnavailableMessage: takeCompletionPublicationFailure(
                id: id,
                attemptIdentifier: context.attemptIdentifier
            ),
            writerQuiescenceUnavailableMessage: stopResult.writerQuiescenceUnavailableMessage
        )
    }

    func quiesceForShutdown() async -> [UUID: BrowserDownloadQuiescence] {
        acceptsResumeCallbacks = false
        isQuiescingForShutdown = true
        defer { isQuiescingForShutdown = false }
        var results: [UUID: BrowserDownloadQuiescence] = [:]
        var blockedWriterIDs: Set<UUID> = []
        while true {
            let resolvedWriterIDs = blockedWriterIDs.filter {
                activeDownloadsByID[$0] == nil
            }
            for id in resolvedWriterIDs {
                blockedWriterIDs.remove(id)
                results.removeValue(forKey: id)
            }
            var pendingIDs = Set(pendingResumes.keys)
            pendingIDs.formUnion(pendingNavigationConversions.keys)
            pendingIDs.formUnion(pendingStops.keys)
            pendingIDs.formUnion(activeDownloadsByID.keys)
            pendingIDs.formUnion(completionPublications.keys)
            pendingIDs.formUnion(completionPublicationFailures.keys)
            pendingIDs.formUnion(completedActiveStopResults.keys)
            if let activeSession {
                pendingIDs.insert(activeSession.downloadID)
            }
            pendingIDs.subtract(blockedWriterIDs)

            guard pendingIDs.isEmpty == false else {
                return results
            }

            for id in pendingIDs {
                if let result = await quiesceDownload(id: id) {
                    results[id] = result
                    if result.writerQuiescenceUnavailableMessage != nil {
                        blockedWriterIDs.insert(id)
                    }
                }
            }
        }
    }

    func resumeAfterFailedShutdown() {
        acceptsResumeCallbacks = true
    }

    func discardRecoveryData(id: UUID) {
        try? discardRecoveryDataOrThrow(id: id)
    }

    func discardRecoveryDataOrThrow(id: UUID) throws {
        pendingResumes.removeValue(forKey: id)
        pendingNavigationConversions.removeValue(forKey: id)
        pendingStops.removeValue(forKey: id)
        completedActiveStopResults.removeValue(forKey: id)
        completionPublicationFailures.removeValue(forKey: id)
        try discardPartialFiles(downloadID: id)
        try completedHandoffStore.discardThrowing(downloadID: id)
    }

    func discardPartialRecoveryData(id: UUID) {
        pendingResumes.removeValue(forKey: id)
        pendingNavigationConversions.removeValue(forKey: id)
        pendingStops.removeValue(forKey: id)
        completedActiveStopResults.removeValue(forKey: id)
        try? discardPartialFiles(downloadID: id)
    }

    func discardOrphanedTemporaryFiles() {
        completedHandoffStore.discardLegacyUnvalidatedFiles(in: temporaryDirectory)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ) else {
            return
        }
        for url in contents where url.pathExtension == "part" {
            try? fileManager.removeItem(at: url)
        }
    }

    private func discardPartialFiles(downloadID: UUID) throws {
        guard try DurableFileSystem.itemExists(at: temporaryDirectory) else {
            return
        }
        let legacyURL = temporaryDirectory
            .appendingPathComponent(downloadID.uuidString)
            .appendingPathExtension("download")
        if try DurableFileSystem.itemExists(at: legacyURL) {
            try fileManager.removeItem(at: legacyURL)
        }
        let prefix = downloadID.uuidString + "-"
        let contents = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        )
        for url in contents where url.pathExtension == "part"
            && url.deletingPathExtension().lastPathComponent.hasPrefix(prefix) {
            try fileManager.removeItem(at: url)
        }
    }

    private func freshPayloadURL(downloadID: UUID, attemptIdentifier: UUID) throws -> URL {
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let url = temporaryDirectory
            .appendingPathComponent("\(downloadID.uuidString)-\(attemptIdentifier.uuidString)")
            .appendingPathExtension("part")
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        return url
    }

    private func track(
        download: WKDownload,
        for session: BrowserDownloadSession,
        isResumeAttempt: Bool = false,
        originalResumeData: Data? = nil
    ) {
        guard activeSession?.id == session.id,
              activeDownloadsByID[session.downloadID] == nil
        else {
            cancelUnownedDownload(download)
            return
        }

        session.hasStartedDownload = true
        session.statusMessage = "Starting secure browser-backed download…"

        downloadContexts[ObjectIdentifier(download)] = DownloadContext(
            downloadID: session.downloadID,
            attemptIdentifier: session.attemptIdentifier,
            sourceURL: session.sourceURL,
            webView: session.webView,
            isResumeAttempt: isResumeAttempt,
            originalResumeData: originalResumeData,
            suggestedFilename: nil,
            responseMimeType: nil,
            statusCode: nil,
            httpResponse: nil,
            expectedBytes: 0,
            temporaryURL: nil,
            terminationReason: nil,
            rejectionError: nil
        )

        activeDownloadsByID[session.downloadID] = ActiveDownloadHandle(
            owner: download,
            identity: ObjectIdentifier(download),
            cancel: { completion in download.cancel(completion) }
        )
        download.delegate = self
    }

    private func requestPendingStop(
        id: UUID,
        reason: TerminationReason,
        completion: @escaping (Data?) -> Void
    ) -> Bool {
        let session: BrowserDownloadSession
        let kind: PendingStopKind
        if let pending = pendingResumes[id] {
            session = pending.session
            kind = .resume(pending.resumeData)
        } else if let pending = pendingNavigationConversions[id] {
            session = pending
            kind = .navigation
        } else {
            return false
        }

        if var stop = pendingStops[id] {
            if case .resume = stop.kind, reason == .cancel {
                stop.reason = reason
            }
            stop.waiters.append(completion)
            pendingStops[id] = stop
        } else {
            pendingStops[id] = PendingStop(
                session: session, kind: kind, reason: reason, waiters: [completion]
            )
        }
        if case .navigation = kind {
            session.webView.stopLoading()
        } else if activeSession?.id == session.id {
            session.webView.stopLoading()
        }
        if activeSession?.id == session.id {
            activeSession = nil
        }
        // WebKit may omit a resume or conversion callback after the view stops.
        // Bound the wait; identity checks reject callbacks for retired sessions.
        let sessionIdentifier = session.id
        let webViewIdentifier = ObjectIdentifier(session.webView)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.finishPendingStop(
                id: id,
                sessionIdentifier: sessionIdentifier,
                webViewIdentifier: webViewIdentifier
            )
        }
        return true
    }

    private func finishPendingStop(
        id: UUID,
        sessionIdentifier: UUID,
        webViewIdentifier: ObjectIdentifier,
        resumeData deliveredResumeData: Data? = nil
    ) {
        guard let stop = pendingStops[id],
              stop.session.id == sessionIdentifier,
              ObjectIdentifier(stop.session.webView) == webViewIdentifier else {
            return
        }
        let resumeData: Data?
        switch stop.kind {
        case let .resume(originalResumeData):
            pendingResumes.removeValue(forKey: id)
            resumeData = stop.reason == .pause
                ? (deliveredResumeData ?? originalResumeData)
                : nil
        case .navigation:
            pendingNavigationConversions.removeValue(forKey: id)
            resumeData = deliveredResumeData
        }
        pendingStops.removeValue(forKey: id)
        stop.session.webView.stopLoading()
        if activeSession?.id == sessionIdentifier {
            activeSession = nil
        }
        stop.waiters.forEach { $0(resumeData) }
    }

    private func abandonPendingResume(
        downloadID: UUID,
        pending: PendingResume
    ) {
        pendingResumes.removeValue(forKey: downloadID)
        let stop = pendingStops.removeValue(forKey: downloadID)
        let resumeData = stop?.reason == .pause ? pending.resumeData : nil
        stop?.waiters.forEach { $0(resumeData) }
        if activeSession?.id == pending.session.id {
            pending.session.webView.stopLoading()
            activeSession = nil
        }
    }

    private func cancelPendingNavigationDownloadIfNeeded(
        _ download: WKDownload,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        beginCancellingPendingNavigation(
            downloadID: session.downloadID,
            session: session,
            webView: webView,
            cancel: { completion in download.cancel(completion) }
        )
    }

    private func beginCancellingPendingNavigation(
        downloadID: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let stop = pendingStops[downloadID],
              case .navigation = stop.kind,
              stop.session.id == session.id,
              stop.session.webView === webView else {
            return false
        }
        cancelPendingDownload(session: stop.session, cancel: cancel)
        return true
    }

    private func cancelPendingResumeDownloadIfNeeded(
        _ download: WKDownload,
        downloadID: UUID,
        attemptIdentifier: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView
    ) -> Bool {
        beginCancellingPendingResume(
            downloadID: downloadID,
            attemptIdentifier: attemptIdentifier,
            session: session,
            webView: webView,
            cancel: { completion in download.cancel(completion) }
        )
    }

    private func beginCancellingPendingResume(
        downloadID: UUID,
        attemptIdentifier: UUID,
        session: BrowserDownloadSession,
        webView: WKWebView,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) -> Bool {
        guard let pending = pendingResumes[downloadID],
              pending.session.id == session.id,
              pending.session.attemptIdentifier == attemptIdentifier,
              pending.session.webView === webView,
              case .resume? = pendingStops[downloadID]?.kind else {
            return false
        }

        cancelPendingDownload(session: session, cancel: cancel)
        return true
    }

    private func cancelPendingDownload(
        session: BrowserDownloadSession,
        cancel: (@escaping @Sendable (Data?) -> Void) -> Void
    ) {
        let downloadID = session.downloadID
        let sessionIdentifier = session.id
        let webView = session.webView
        let webViewIdentifier = ObjectIdentifier(webView)
        cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finishPendingStop(
                    id: downloadID,
                    sessionIdentifier: sessionIdentifier,
                    webViewIdentifier: webViewIdentifier,
                    resumeData: resumeData
                )
            }
        }
    }

    private func clearActiveSession(matching context: DownloadContext) {
        guard activeSession?.downloadID == context.downloadID,
              activeSession?.attemptIdentifier == context.attemptIdentifier,
              activeSession?.webView === context.webView else {
            return
        }

        activeSession = nil
    }

    private func deliverCompletionPublication(
        id: UUID,
        attemptIdentifier: UUID
    ) async -> BrowserDownloadEvent? {
        guard let publication = completionPublications[id],
              publication.attemptIdentifier == attemptIdentifier else {
            return nil
        }
        let event = await publication.task.value
        guard completionPublications[id]?.attemptIdentifier == attemptIdentifier else {
            return nil
        }
        completionPublications.removeValue(forKey: id)
        if case let .failed(_, _, failure) = event {
            completionPublicationFailures[id] = (
                attemptIdentifier,
                failure.message
            )
        }
        onEvent(event)
        return event
    }

    private func takeCompletionPublicationFailure(
        id: UUID,
        attemptIdentifier: UUID
    ) -> String? {
        guard let failure = completionPublicationFailures[id],
              failure.0 == attemptIdentifier else {
            return nil
        }
        completionPublicationFailures.removeValue(forKey: id)
        return failure.1
    }

    @discardableResult
    private func requestStop(
        id: UUID,
        reason: TerminationReason,
        completion: @escaping (ActiveDownloadStopResult) -> Void
    ) -> Bool {
        guard let download = activeDownloadsByID[id] else {
            return false
        }

        let key = download.identity
        guard var context = downloadContexts[key] else {
            return false
        }

        if context.terminationReason != nil {
            if case .cancel = reason {
                context.terminationReason = .cancel
                downloadContexts[key] = context
            }
            if let failure = activeDownloadStopFailures[id],
               failure.attemptIdentifier == context.attemptIdentifier {
                completion(
                    ActiveDownloadStopResult(
                        resumeData: nil,
                        writerQuiescenceUnavailableMessage: failure.message
                    )
                )
                return true
            }
            stopWaiters[id, default: []].append(completion)
            return true
        }

        context.terminationReason = reason
        downloadContexts[key] = context
        stopWaiters[id, default: []].append(completion)
        let attemptIdentifier = context.attemptIdentifier
        download.cancel { [weak self] resumeData in
            Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                self.finishActiveDownloadStop(
                    id: id,
                    key: key,
                    resumeData: resumeData
                )
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            self?.failActiveDownloadStopIfStillPending(
                id: id,
                key: key,
                attemptIdentifier: attemptIdentifier
            )
        }
        return true
    }

    private func failActiveDownloadStopIfStillPending(
        id: UUID,
        key: ObjectIdentifier,
        attemptIdentifier: UUID
    ) {
        guard let download = activeDownloadsByID[id],
              download.identity == key,
              let context = downloadContexts[key],
              context.attemptIdentifier == attemptIdentifier,
              context.terminationReason != nil else {
            return
        }
        let message = String(
            localized: "download.browser.writerQuiescenceUnavailable",
            defaultValue: "WebKit did not confirm that the active browser download stopped. Harbor left its temporary file and recovery state untouched.",
            comment: "Failure shown when WebKit does not acknowledge cancellation of an active browser download."
        )
        activeDownloadStopFailures[id] = ActiveDownloadStopFailure(
            attemptIdentifier: attemptIdentifier,
            message: message
        )
        let result = ActiveDownloadStopResult(
            resumeData: nil,
            writerQuiescenceUnavailableMessage: message
        )
        let waiters = stopWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0(result) }
    }

    private func finishActiveDownloadStop(
        id: UUID,
        key: ObjectIdentifier,
        resumeData: Data?
    ) {
        guard activeDownloadsByID[id]?.identity == key,
              let stoppedContext = downloadContexts.removeValue(forKey: key),
              let reason = stoppedContext.terminationReason else {
            return
        }
        activeDownloadsByID.removeValue(forKey: id)
        let hadTimedOut = activeDownloadStopFailures.removeValue(forKey: id) != nil

        if let publication = completionPublications[id],
           publication.attemptIdentifier == stoppedContext.attemptIdentifier {
            // downloadDidFinish won the stop race and transferred payload
            // ownership to an asynchronous integrity publication. Do not
            // delete its source path, and do not release quiescence until the
            // resulting completion/failure event is delivered.
            let waiters = stopWaiters.removeValue(forKey: id) ?? []
            Task { @MainActor [weak self] in
                _ = await self?.deliverCompletionPublication(
                    id: id,
                    attemptIdentifier: publication.attemptIdentifier
                )
                let result = ActiveDownloadStopResult(
                    resumeData: nil,
                    writerQuiescenceUnavailableMessage: nil
                )
                waiters.forEach { $0(result) }
            }
            return
        }

        stoppedContext.webView.stopLoading()
        if let temporaryURL = stoppedContext.temporaryURL {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let result = ActiveDownloadStopResult(
            resumeData: reason == .pause ? resumeData : nil,
            writerQuiescenceUnavailableMessage: nil
        )
        let waiters = stopWaiters.removeValue(forKey: id) ?? []
        waiters.forEach { $0(result) }
        if hadTimedOut {
            if isQuiescingForShutdown {
                completedActiveStopResults[id] = (
                    stoppedContext.attemptIdentifier,
                    result
                )
            }
            onEvent(
                .quiescedAfterTimeout(
                    id: id,
                    attemptIdentifier: stoppedContext.attemptIdentifier,
                    resumeData: reason == .pause ? resumeData : nil,
                    wasCancelling: reason == .cancel
                )
            )
        }
    }

    private func currentAttemptIdentifier(for id: UUID) -> UUID? {
        if let download = activeDownloadsByID[id],
           let context = downloadContexts[download.identity] {
            return context.attemptIdentifier
        }
        if let pending = pendingResumes[id] {
            return pending.session.attemptIdentifier
        }
        if let pending = pendingNavigationConversions[id] {
            return pending.attemptIdentifier
        }
        if let pending = pendingStops[id] {
            return pending.session.attemptIdentifier
        }
        if let activeSession, activeSession.downloadID == id {
            return activeSession.attemptIdentifier
        }
        return nil
    }

    private func shouldDownloadInBrowser(response: URLResponse, isForMainFrame: Bool) -> Bool {
        guard isForMainFrame else {
            return false
        }

        let normalizedMimeType = response.mimeType?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        return normalizedMimeType != "text/html"
            && normalizedMimeType != "application/xhtml+xml"
    }

    private func shouldIgnoreNavigationError(_ error: Error) -> Bool {
        let nsError = error as NSError
        let frameLoadInterruptedByPolicyChange = 102

        if nsError.domain == WKErrorDomain,
           nsError.code == frameLoadInterruptedByPolicyChange {
            return true
        }

        if nsError.domain == NSURLErrorDomain,
           nsError.code == NSURLErrorCancelled {
            return true
        }

        return false
    }

    private func session(for webView: WKWebView) -> BrowserDownloadSession? {
        guard let activeSession, activeSession.webView === webView else {
            return nil
        }

        return activeSession
    }

    private func refreshSessionURL(from webView: WKWebView) {
        guard let session = session(for: webView), let url = webView.url else {
            return
        }

        session.currentURL = url
    }

    private func completeNavigationFailure(_ error: Error, from webView: WKWebView) {
        if let pendingStop = pendingStops.first(where: {
            if case .navigation = $0.value.kind {
                return $0.value.session.webView === webView
            }
            return false
        }) {
            finishPendingStop(
                id: pendingStop.key,
                sessionIdentifier: pendingStop.value.session.id,
                webViewIdentifier: ObjectIdentifier(pendingStop.value.session.webView),
                resumeData: nil
            )
            return
        }

        guard let activeSession = session(for: webView) else {
            return
        }

        if shouldIgnoreNavigationError(error) || activeSession.hasStartedDownload {
            return
        }

        let downloadID = activeSession.downloadID
        let attemptIdentifier = activeSession.attemptIdentifier
        self.activeSession = nil
        pendingNavigationConversions.removeValue(forKey: downloadID)
        pendingStops.removeValue(forKey: downloadID)
        onEvent(
            .failed(
                id: downloadID,
                attemptIdentifier: attemptIdentifier,
                failure: DirectDownloadFailure(error: error, resumeData: nil)
            )
        )
    }
}

extension BrowserDownloadCoordinator: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        if navigationAction.shouldPerformDownload,
           let session = session(for: webView) {
            pendingNavigationConversions[session.downloadID] = session
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        guard let activeSession = session(for: webView) else {
            decisionHandler(.cancel)
            return
        }

        activeSession.currentURL = navigationResponse.response.url ?? activeSession.currentURL

        if shouldDownloadInBrowser(
            response: navigationResponse.response,
            isForMainFrame: navigationResponse.isForMainFrame
        ) {
            pendingNavigationConversions[activeSession.downloadID] = activeSession
            decisionHandler(.download)
            return
        }

        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        guard let activeSession = session(for: webView) else {
            return
        }

        activeSession.isLoading = true
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard let activeSession = session(for: webView) else {
            return
        }

        activeSession.isLoading = false
        activeSession.pageTitle = webView.title
        refreshSessionURL(from: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completeNavigationFailure(error, from: webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completeNavigationFailure(error, from: webView)
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        guard let session = pendingNavigationConversions.values.first(where: {
            $0.webView === webView
        }) ?? activeSession,
              session.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        if cancelPendingNavigationDownloadIfNeeded(
            download,
            session: session,
            webView: webView
        ) {
            return
        }
        pendingNavigationConversions.removeValue(forKey: session.downloadID)
        track(download: download, for: session)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        guard let session = pendingNavigationConversions.values.first(where: {
            $0.webView === webView
        }) ?? activeSession,
              session.webView === webView else {
            cancelUnownedDownload(download)
            return
        }
        if cancelPendingNavigationDownloadIfNeeded(
            download,
            session: session,
            webView: webView
        ) {
            return
        }
        pendingNavigationConversions.removeValue(forKey: session.downloadID)
        track(download: download, for: session)
    }
}

extension BrowserDownloadCoordinator: WKDownloadDelegate {
    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let key = ObjectIdentifier(download)

        guard var context = downloadContexts[key] else {
            completionHandler(nil)
            return
        }

        do {
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HTTPDownloadInvalidRangeResponseError()
            }
            context.statusCode = httpResponse.statusCode
            guard (200 ... 299).contains(httpResponse.statusCode) else {
                throw HTTPDownloadStatusError(statusCode: httpResponse.statusCode)
            }
            guard httpResponse.statusCode == 200 || httpResponse.statusCode == 206 else {
                throw URLError(.badServerResponse)
            }

            let temporaryURL = try freshPayloadURL(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier
            )

            context.suggestedFilename = suggestedFilename
            context.responseMimeType = response.mimeType
            context.statusCode = httpResponse.statusCode
            context.httpResponse = httpResponse
            if httpResponse.statusCode == 206 {
                let range = try DownloadHTTPResponseValidator
                    .validatedPartialContentRange(httpResponse)
                guard context.isResumeAttempt, range.start > 0,
                      let total = range.total else {
                    throw HTTPDownloadInvalidRangeResponseError()
                }
                context.expectedBytes = total
            } else {
                guard httpResponse.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw HTTPDownloadInvalidRangeResponseError()
                }
                if DownloadHTTPResponseValidator.usesIdentityEncoding(httpResponse) {
                    context.expectedBytes = try DownloadHTTPResponseValidator
                        .declaredContentLength(httpResponse)
                        ?? max(response.expectedContentLength, 0)
                } else {
                    context.expectedBytes = 0
                }
            }
            context.temporaryURL = temporaryURL
            downloadContexts[key] = context

            completionHandler(temporaryURL)

            clearActiveSession(matching: context)
            onEvent(
                .started(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    suggestedFilename: suggestedFilename,
                    expectedBytes: context.expectedBytes,
                    responseMimeType: context.responseMimeType,
                    statusCode: context.statusCode,
                    isResumed: context.isResumeAttempt
                )
            )
        } catch {
            context.rejectionError = error
            downloadContexts[key] = context
            completionHandler(nil)
            clearActiveSession(matching: context)
            // Supplying no destination asks WebKit to cancel. Keep ownership
            // until didFailWithError returns its replacement resume blob;
            // falling back to the original opaque blob preserves a safe retry.
        }
    }

    func download(
        _ download: WKDownload,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        decisionHandler: @escaping (WKDownload.RedirectPolicy) -> Void
    ) {
        decisionHandler(.allow)
    }

    func download(
        _ download: WKDownload,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func downloadDidFinish(_ download: WKDownload) {
        let key = ObjectIdentifier(download)

        guard let context = downloadContexts.removeValue(forKey: key),
              let temporaryURL = context.temporaryURL
        else {
            return
        }

        if activeDownloadsByID[context.downloadID]?.identity == key {
            activeDownloadsByID.removeValue(forKey: context.downloadID)
        }
        activeDownloadStopFailures.removeValue(forKey: context.downloadID)
        let pendingStopWaiters = context.terminationReason == nil
            ? []
            : (stopWaiters.removeValue(forKey: context.downloadID) ?? [])

        var claimedCompletion = false
        do {
            let values = try temporaryURL.resourceValues(
                forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let fileSize = values.fileSize,
                  fileSize >= 0 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let actualBytes = Int64(fileSize)
            guard let httpResponse = context.httpResponse else {
                throw URLError(.badServerResponse)
            }
            let expectedBytes: Int64
            if DownloadHTTPResponseValidator.usesIdentityEncoding(httpResponse) {
                expectedBytes = try DownloadHTTPResponseValidator
                    .validatedBrowserCompletedByteCount(
                        response: httpResponse,
                        actualBytes: actualBytes,
                        isResumeAttempt: context.isResumeAttempt
                    )
            } else {
                guard httpResponse.statusCode == 200,
                      httpResponse.value(forHTTPHeaderField: "Content-Range") == nil else {
                    throw URLError(.cannotDecodeContentData)
                }
                expectedBytes = actualBytes
            }
            let manifest = CompletedDownloadHandoffManifest(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                owner: .browser,
                sourceURL: context.sourceURL,
                statusCode: context.statusCode,
                mimeType: context.responseMimeType,
                suggestedFilename: context.suggestedFilename,
                actualBytes: actualBytes,
                expectedBytes: expectedBytes
            )
            let claim = try completedHandoffStore.claim(
                payloadAt: temporaryURL,
                manifest: manifest
            )
            claimedCompletion = true
            let completedHandoffStore = completedHandoffStore
            let wasResuming = context.isResumeAttempt
            let statusCode = context.statusCode
            let publicationTask = Task.detached(priority: .utility) {
                () -> BrowserDownloadEvent in
                do {
                    let handoff = try completedHandoffStore.finalize(claim)
                    return BrowserDownloadEvent.finished(
                        id: manifest.downloadID,
                        attemptIdentifier: manifest.attemptIdentifier,
                        handoff: handoff
                    )
                } catch {
                    return .failed(
                        id: manifest.downloadID,
                        attemptIdentifier: manifest.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: wasResuming,
                            httpStatusCode: statusCode
                        )
                    )
                }
            }
            completionPublications[context.downloadID] = CompletionPublication(
                attemptIdentifier: context.attemptIdentifier,
                task: publicationTask
            )
            Task { @MainActor [weak self] in
                _ = await self?.deliverCompletionPublication(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                )
                let result = ActiveDownloadStopResult(
                    resumeData: nil,
                    writerQuiescenceUnavailableMessage: nil
                )
                pendingStopWaiters.forEach { $0(result) }
            }
        } catch {
            if claimedCompletion == false {
                try? fileManager.removeItem(at: temporaryURL)
            }
            onEvent(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: context.isResumeAttempt,
                        httpStatusCode: context.statusCode
                    )
                )
            )
            let result = ActiveDownloadStopResult(
                resumeData: nil,
                writerQuiescenceUnavailableMessage: nil
            )
            pendingStopWaiters.forEach { $0(result) }
        }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let key = ObjectIdentifier(download)
        guard let context = downloadContexts[key] else {
            return
        }

        if context.terminationReason != nil {
            // A delegate failure is also authoritative proof that WebKit's
            // writer stopped. Complete a pending pause/cancel even if the
            // separate cancel completion handler is delayed or never called.
            finishActiveDownloadStop(
                id: context.downloadID,
                key: key,
                resumeData: resumeData
            )
            return
        }

        downloadContexts.removeValue(forKey: key)
        if activeDownloadsByID[context.downloadID]?.identity == key {
            activeDownloadsByID.removeValue(forKey: context.downloadID)
        }

        if let temporaryURL = context.temporaryURL {
            try? fileManager.removeItem(at: temporaryURL)
        }

        let reportedError = context.rejectionError ?? error
        let shouldRetireResumeData = context.isResumeAttempt
            && Self.shouldRetireResumeData(
                after: reportedError,
                statusCode: context.statusCode
            )
        let preservedResumeData = shouldRetireResumeData
            ? nil
            : (resumeData ?? context.originalResumeData)
        clearActiveSession(matching: context)

        onEvent(
            .failed(
                id: context.downloadID,
                attemptIdentifier: context.attemptIdentifier,
                failure: DirectDownloadFailure(
                    error: reportedError,
                    resumeData: preservedResumeData,
                    wasResuming: context.isResumeAttempt,
                    httpStatusCode: context.statusCode
                )
            )
        )
    }

    nonisolated static func shouldRetireResumeData(
        after error: Error,
        statusCode: Int?
    ) -> Bool {
        if let statusCode,
           (200 ... 299).contains(statusCode) == false,
           DirectDownloadRetryPolicy.isRetryableHTTPStatus(statusCode) == false {
            return true
        }
        return DownloadHTTPResponseValidator.isInvalidResumeProtocolResponse(error)
    }
}

extension BrowserDownloadCoordinator: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }

        return nil
    }

    func webViewDidClose(_ webView: WKWebView) {
        guard let session = session(for: webView) else {
            return
        }
        Task { @MainActor [weak self, weak session] in
            guard let self, let session else {
                return
            }
            let result = await self.quiesceDownload(id: session.downloadID)
            if let message = result?.writerQuiescenceUnavailableMessage,
               result?.attemptIdentifier == session.attemptIdentifier {
                self.onEvent(
                    .quiescenceFailed(
                        id: session.downloadID,
                        attemptIdentifier: session.attemptIdentifier,
                        message: message
                    )
                )
                return
            }
            if let message = result?.completionUnavailableMessage,
               result?.attemptIdentifier == session.attemptIdentifier {
                self.onEvent(
                    .completionUnavailable(
                        id: session.downloadID,
                        attemptIdentifier: session.attemptIdentifier,
                        message: message
                    )
                )
                return
            }
            self.onEvent(
                .dismissed(
                    id: session.downloadID,
                    attemptIdentifier: session.attemptIdentifier,
                    resumeData: result?.attemptIdentifier == session.attemptIdentifier
                        ? result?.resumeData
                        : nil
                )
            )
        }
    }
}
