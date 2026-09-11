import Foundation

private struct DirectDownloadRangeOverflowError: LocalizedError {
    let declaredEnd: Int64

    var errorDescription: String? {
        "The server sent data beyond the declared byte range ending at byte \(declaredEnd)."
    }
}

private struct DirectDownloadBodyOverflowError: LocalizedError {
    let expectedBytes: Int64

    var errorDescription: String? {
        "The server sent data beyond its declared body length of \(expectedBytes) bytes."
    }
}

struct DirectDownloadFailure: Sendable {
    let message: String
    let urlErrorCode: URLError.Code?
    let httpStatusCode: Int?
    let resumeData: Data?
    let wasResuming: Bool
    let recoverableBytes: Int64?
    private let retryableOverride: Bool
    private let freshStartOverride: Bool

    var isRetryable: Bool {
        DirectDownloadRetryPolicy.isRetryable(urlErrorCode)
            || DirectDownloadRetryPolicy.isRetryableHTTPStatus(httpStatusCode)
            || retryableOverride
            || (
                httpStatusCode == nil
                    && urlErrorCode != nil
                    && wasResuming
                    && resumeData == nil
                    && recoverableBytes == nil
            )
    }

    var requiresFreshStart: Bool {
        freshStartOverride || (resumeData == nil && (recoverableBytes ?? 0) == 0)
    }

    nonisolated init(
        error: Error,
        resumeData: Data?,
        wasResuming: Bool = false,
        recoverableBytes: Int64? = nil,
        httpStatusCode: Int? = nil,
        forcesFreshStart: Bool = false
    ) {
        let nsError = error as NSError
        self.message = nsError.localizedDescription
        self.urlErrorCode = DirectDownloadRetryPolicy.urlErrorCode(from: nsError)
        self.httpStatusCode = httpStatusCode
        self.resumeData = resumeData
        self.wasResuming = wasResuming
        self.recoverableBytes = recoverableBytes
        self.retryableOverride = error is DirectDownloadRecoveryRestartError
            || error is HTTPDownloadIncompleteResponseError
            || error is DirectDownloadRangeOverflowError
            || error is DirectDownloadBodyOverflowError
            || error is HTTPDownloadInvalidRangeResponseError
        self.freshStartOverride = forcesFreshStart
            || error is DirectDownloadRecoveryRestartError
    }
}

struct DirectDownloadPauseResult: Sendable {
    let attemptIdentifier: UUID?
    let ownedRecovery: DirectDownloadRecoverySnapshot?
    let recoveryUnavailableMessage: String?

    nonisolated init(
        attemptIdentifier: UUID?,
        ownedRecovery: DirectDownloadRecoverySnapshot?,
        recoveryUnavailableMessage: String? = nil
    ) {
        self.attemptIdentifier = attemptIdentifier
        self.ownedRecovery = ownedRecovery
        self.recoveryUnavailableMessage = recoveryUnavailableMessage
    }
}

enum DirectDownloadRetryPolicy {
    static var delays: [Duration] {
        if HarborTestRuntime.isUITesting {
            return []
        }
        return [
            .seconds(2),
            .seconds(5),
            .seconds(15),
            .seconds(30),
            .seconds(60)
        ]
    }

    static func delay(forAttempt attempt: Int) -> Duration? {
        guard attempt > 0, delays.indices.contains(attempt - 1) else {
            return nil
        }

        return delays[attempt - 1]
    }

    static func isRetryable(_ code: URLError.Code?) -> Bool {
        guard let code else {
            return false
        }

        switch code {
        case .timedOut,
             .cannotFindHost,
             .cannotConnectToHost,
             .networkConnectionLost,
             .dnsLookupFailed,
             .notConnectedToInternet,
             .secureConnectionFailed,
             .internationalRoamingOff,
             .callIsActive,
             .dataNotAllowed,
             .resourceUnavailable,
             .downloadDecodingFailedMidStream:
            return true
        default:
            return false
        }
    }

    nonisolated static func isRetryableHTTPStatus(_ statusCode: Int?) -> Bool {
        guard let statusCode else {
            return false
        }

        return statusCode == 408
            || statusCode == 425
            || statusCode == 429
            || statusCode == 500
            || statusCode == 502
            || statusCode == 503
            || statusCode == 504
    }

    nonisolated static func urlErrorCode(from error: NSError) -> URLError.Code? {
        if error.domain == NSURLErrorDomain {
            return URLError.Code(rawValue: error.code)
        }

        if let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return urlErrorCode(from: underlyingError)
        }

        return nil
    }
}

enum DownloadEvent: Sendable {
    case started(
        id: UUID,
        attemptIdentifier: UUID,
        taskIdentifier: Int,
        ownedRecovery: DirectDownloadRecoverySnapshot?,
        resetReason: DirectDownloadRecoveryResetReason?
    )
    case recoveryReset(id: UUID, attemptIdentifier: UUID, reason: DirectDownloadRecoveryResetReason)
    case progress(
        id: UUID,
        attemptIdentifier: UUID,
        bytesWritten: Int64,
        expectedBytes: Int64,
        speedBytesPerSecond: Double
    )
    case finished(
        id: UUID,
        attemptIdentifier: UUID,
        handoff: CompletedDownloadHandoff
    )
    case failed(id: UUID, attemptIdentifier: UUID, failure: DirectDownloadFailure)
}

final class DownloadCoordinator: NSObject, @unchecked Sendable {
    typealias EventHandler = @Sendable (DownloadEvent) -> Void

    private struct TransferSample {
        var lastTotalBytesWritten: Int64
        var sampleDate: Date
        var speedBytesPerSecond: Double
    }

    private typealias TaskKey = String

    private struct OwnedPartialState {
        let sourceURL: URL
        var resumeOffset: Int64
        var bytesWritten: Int64
        var expectedBytes: Int64
        var declaredExpectedBytes: Int64?
        var suggestedFilename: String?
        var responseMimeType: String?
        var statusCode: Int?
        var responseRangeEnd: Int64?
        var entityTag: String?
        var lastModified: String?
        var fileHandle: FileHandle?
    }

    private enum OwnedResponseDisposition {
        case receiveBody(resetReason: DirectDownloadRecoveryResetReason?)
        case finishExistingPartial
        case reject(
            error: Error,
            statusCode: Int?,
            wasResuming: Bool,
            requiresFreshStart: Bool
        )
    }

    private struct CompletionPublicationState {
        let context: TaskContext
        var waiters: [CheckedContinuation<DirectDownloadPauseResult, Never>] = []
    }

    private struct TaskContext: @unchecked Sendable {
        let downloadID: UUID
        let attemptIdentifier: UUID
        let sourceURL: URL
        let requestHeaders: [RequestHeader]
        let session: URLSession
        let task: URLSessionTask
        var state: OwnedPartialState
        var speedLimitOverride: TransferLimitOverride
        var transferSample: TransferSample
        var isThrottled = false
        var throttleGeneration: UInt64 = 0
    }

    private let eventHandler: EventHandler
    private let fileManager: FileManager
    private let stateLock = NSLock()
    private let ownedTemporaryDirectory: URL
    private let recoveryStore: DirectDownloadRecoveryStore
    private let completedHandoffStore: CompletedDownloadHandoffStore
    private let baseSessionConfiguration: URLSessionConfiguration
    private let delegateQueue: OperationQueue
    private let completionQueue = DispatchQueue(
        label: "Harbor.DownloadCompletionPublication",
        qos: .utility,
        attributes: .concurrent
    )

    private var contexts: [TaskKey: TaskContext] = [:]
    private var taskKeysByDownloadID: [UUID: TaskKey] = [:]
    private var reservedDownloadIDs: Set<UUID> = []
    private var suppressedCompletionTaskKeys: Set<TaskKey> = []
    private var completionPublications: [UUID: CompletionPublicationState] = [:]
    private var completedPublicationPauseResults: [UUID: DirectDownloadPauseResult] = [:]
    private var transferSettings: DownloadTransferSettings

    init(
        transferSettings: DownloadTransferSettings = .default,
        eventHandler: @escaping EventHandler,
        fileManager: FileManager = .default,
        recoveryDirectoryURL: URL? = nil,
        temporaryDirectory: URL? = nil,
        completedHandoffStore: CompletedDownloadHandoffStore? = nil,
        sessionConfiguration: URLSessionConfiguration = .default
    ) {
        self.eventHandler = eventHandler
        self.fileManager = fileManager
        self.transferSettings = transferSettings
        self.ownedTemporaryDirectory = temporaryDirectory
            ?? fileManager.temporaryDirectory
                .appendingPathComponent("HarborDownloads", isDirectory: true)
        self.recoveryStore = DirectDownloadRecoveryStore(
            fileManager: fileManager,
            directoryURL: recoveryDirectoryURL
        )
        self.completedHandoffStore = completedHandoffStore
            ?? CompletedDownloadHandoffStore(
                fileManager: fileManager,
                directoryURL: temporaryDirectory
            )
        self.baseSessionConfiguration = sessionConfiguration
        self.delegateQueue = OperationQueue()
        self.delegateQueue.name = "DownloadCoordinatorDelegateQueue"
        self.delegateQueue.maxConcurrentOperationCount = 1
        super.init()
    }

    deinit {
        let activeContexts = stateLock.withLock {
            Array(self.contexts.values)
        }
        for context in activeContexts {
            closeOwnedFile(in: context, preservingRecovery: false)
            context.session.invalidateAndCancel()
        }
    }

    func updateTransferSettings(_ transferSettings: DownloadTransferSettings) {
        let tasksToResume = stateLock.withLock { () -> [URLSessionTask] in
            self.transferSettings = transferSettings
            return releaseThrottledTasksLocked()
        }
        tasksToResume.forEach { $0.resume() }
    }

    func updateSpeedLimitOverride(
        _ speedLimitOverride: TransferLimitOverride,
        for id: UUID
    ) {
        let tasksToResume = stateLock.withLock { () -> [URLSessionTask] in
            guard let taskKey = taskKeysByDownloadID[id],
                  var context = contexts[taskKey] else {
                return []
            }

            context.speedLimitOverride = speedLimitOverride
            var tasks: [URLSessionTask] = []
            if context.isThrottled {
                context.isThrottled = false
                context.throttleGeneration &+= 1
                tasks.append(context.task)
            }
            contexts[taskKey] = context
            return tasks
        }
        tasksToResume.forEach { $0.resume() }
    }

    @discardableResult
    func startDownload(
        id: UUID,
        attemptIdentifier: UUID = UUID(),
        sourceURL: URL,
        requestHeaders: [RequestHeader] = [],
        speedLimitOverride: TransferLimitOverride = .inherit
    ) throws -> Int {
        guard stateLock.withLock({
            guard taskKeysByDownloadID[id] == nil,
                  reservedDownloadIDs.contains(id) == false else {
                return false
            }
            reservedDownloadIDs.insert(id)
            return true
        }) else {
            throw CocoaError(.fileWriteFileExists)
        }
        var installedContext = false
        defer {
            if installedContext == false {
                _ = stateLock.withLock {
                    reservedDownloadIDs.remove(id)
                }
            }
        }

        let session = makeSession()
        defer {
            if installedContext == false {
                session.invalidateAndCancel()
            }
        }
        let preparation = try recoveryStore.prepareStart(id: id, sourceURL: sourceURL)
        let task = session.dataTask(
            with: DirectDownloadResponsePolicy.request(
                sourceURL: sourceURL,
                recovery: preparation.snapshot,
                requestHeaders: requestHeaders
            )
        )
        let ownedRecovery = preparation.snapshot
        let recoveredBytes = ownedRecovery?.bytesWritten ?? 0

        let key = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        let context = TaskContext(
            downloadID: id,
            attemptIdentifier: attemptIdentifier,
            sourceURL: sourceURL,
            requestHeaders: requestHeaders,
            session: session,
            task: task,
            state: OwnedPartialState(
                sourceURL: sourceURL,
                resumeOffset: recoveredBytes,
                bytesWritten: recoveredBytes,
                expectedBytes: ownedRecovery?.metadata.expectedBytes ?? 0,
                declaredExpectedBytes: nil,
                suggestedFilename: ownedRecovery?.metadata.suggestedFilename,
                responseMimeType: ownedRecovery?.metadata.mimeType,
                statusCode: nil,
                responseRangeEnd: nil,
                entityTag: ownedRecovery?.metadata.entityTag,
                lastModified: ownedRecovery?.metadata.lastModified,
                fileHandle: nil
            ),
            speedLimitOverride: speedLimitOverride,
            transferSample: TransferSample(
                lastTotalBytesWritten: ownedRecovery?.bytesWritten ?? 0,
                sampleDate: .now,
                speedBytesPerSecond: 0
            )
        )

        stateLock.withLock {
            contexts[key] = context
            taskKeysByDownloadID[id] = key
            reservedDownloadIDs.remove(id)
            suppressedCompletionTaskKeys.remove(key)
            completedPublicationPauseResults.removeValue(forKey: id)
        }
        installedContext = true

        eventHandler(
            .started(
                id: id,
                attemptIdentifier: attemptIdentifier,
                taskIdentifier: task.taskIdentifier,
                ownedRecovery: ownedRecovery,
                resetReason: preparation.resetReason
            )
        )
        // Publish ownership before the task can produce response/progress
        // callbacks. The delegate queue is serial, but its events are bridged
        // to another executor by the caller and must not overtake `.started`.
        task.resume()
        return task.taskIdentifier
    }

    func pauseDownloadAndWait(id: UUID) async -> DirectDownloadPauseResult {
        guard let context = takeContext(forDownloadID: id) else {
            return await waitForCompletionPublication(id: id)
        }

        let didPreserveRecovery = closeOwnedFile(in: context, preservingRecovery: true)
        context.task.cancel()
        context.session.finishTasksAndInvalidate()
        return ownedPauseResult(for: context, didPreserveRecovery: didPreserveRecovery)
    }

    func cancelDownload(id: UUID) {
        guard let context = takeContext(forDownloadID: id) else {
            let ownsCompletion = stateLock.withLock {
                completionPublications[id] != nil
                    || completedPublicationPauseResults[id]?.attemptIdentifier != nil
            }
            guard ownsCompletion == false else {
                return
            }
            recoveryStore.discard(id: id)
            return
        }

        closeOwnedFile(in: context, preservingRecovery: false)
        context.task.cancel()
        context.session.invalidateAndCancel()
        recoveryStore.discard(id: id)
    }

    func discardRecoveryDataOrThrow(id: UUID) throws {
        stateLock.withLock {
            completedPublicationPauseResults[id] = nil
        }
        try recoveryStore.discardThrowing(id: id)
        try completedHandoffStore.discardThrowing(downloadID: id)
    }

    func acknowledgeTerminalOutcome(
        id: UUID,
        attemptIdentifier: UUID
    ) {
        stateLock.withLock {
            guard completedPublicationPauseResults[id]?.attemptIdentifier
                    == attemptIdentifier else {
                return
            }
            completedPublicationPauseResults[id] = nil
        }
    }

    func discardOwnedRecoveryData(id: UUID) {
        try? discardOwnedRecoveryDataOrThrow(id: id)
    }

    func discardOwnedRecoveryDataOrThrow(id: UUID) throws {
        stateLock.withLock {
            completedPublicationPauseResults[id] = nil
        }
        try recoveryStore.discardThrowing(id: id)
    }

    func discardOrphanedRecoveryData(retaining retainedIDs: Set<UUID>) {
        recoveryStore.discardOrphans(retaining: retainedIDs)
    }

    func discardOrphanedTemporaryFiles() {
        completedHandoffStore.discardLegacyUnvalidatedFiles(
            in: ownedTemporaryDirectory
        )
    }

    func recoverySnapshot(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoverySnapshot? {
        recoveryStore.snapshot(id: id, sourceURL: sourceURL)
    }

    func recoveryLookup(
        id: UUID,
        sourceURL: URL
    ) -> DirectDownloadRecoveryLookup {
        recoveryStore.lookup(id: id, sourceURL: sourceURL)
    }

    /// Startup-only forwarding into the recovery store's compatibility importer.
    /// Active direct downloads never consume opaque resume data; after startup,
    /// the coordinator operates exclusively on Harbor-owned recovery state.
    func adoptResumeData(
        _ data: Data,
        id: UUID,
        sourceURL: URL,
        expectedBytes: Int64
    ) {
        recoveryStore.adoptResumeData(
            data,
            id: id,
            sourceURL: sourceURL,
            expectedBytes: expectedBytes
        )
    }

    private func takeContext(forDownloadID id: UUID) -> TaskContext? {
        stateLock.withLock {
            guard let taskKey = taskKeysByDownloadID.removeValue(forKey: id),
                  let context = contexts.removeValue(forKey: taskKey) else {
                return nil
            }

            suppressedCompletionTaskKeys.insert(taskKey)

            return context
        }
    }

    private func beginCompletionPublication(forTaskKey taskKey: TaskKey) -> TaskContext? {
        stateLock.withLock {
            guard let context = contexts.removeValue(forKey: taskKey),
                  completionPublications[context.downloadID] == nil else {
                return nil
            }
            if taskKeysByDownloadID[context.downloadID] == taskKey {
                taskKeysByDownloadID.removeValue(forKey: context.downloadID)
            }
            completionPublications[context.downloadID] = CompletionPublicationState(
                context: context
            )
            return context
        }
    }

    private func finishCompletionPublication(
        context: TaskContext,
        ownedRecovery: DirectDownloadRecoverySnapshot? = nil,
        recoveryUnavailableMessage: String?
    ) {
        let result = DirectDownloadPauseResult(
            attemptIdentifier: context.attemptIdentifier,
            ownedRecovery: ownedRecovery,
            recoveryUnavailableMessage: recoveryUnavailableMessage
        )
        let waiters = stateLock.withLock { () -> [CheckedContinuation<DirectDownloadPauseResult, Never>] in
            guard let publication = completionPublications[context.downloadID],
                  publication.context.attemptIdentifier == context.attemptIdentifier else {
                return []
            }
            completionPublications.removeValue(forKey: context.downloadID)
            completedPublicationPauseResults[context.downloadID] = result
            return publication.waiters
        }
        waiters.forEach { $0.resume(returning: result) }
    }

    private func ownedPauseResult(
        for context: TaskContext,
        didPreserveRecovery: Bool
    ) -> DirectDownloadPauseResult {
        guard didPreserveRecovery else {
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                ownedRecovery: nil
            )
        }
        switch recoveryStore.lookup(id: context.downloadID, sourceURL: context.state.sourceURL) {
        case let .available(snapshot):
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                ownedRecovery: snapshot
            )
        case .absent:
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                ownedRecovery: nil
            )
        case let .unavailable(message):
            return DirectDownloadPauseResult(
                attemptIdentifier: context.attemptIdentifier,
                ownedRecovery: nil,
                recoveryUnavailableMessage: message
            )
        }
    }

    private func waitForCompletionPublication(
        id: UUID
    ) async -> DirectDownloadPauseResult {
        if let completed = stateLock.withLock({
            completedPublicationPauseResults.removeValue(forKey: id)
        }) {
            return completed
        }

        return await withCheckedContinuation { continuation in
            let shouldReturnNil = stateLock.withLock { () -> Bool in
                if let completed = completedPublicationPauseResults.removeValue(forKey: id) {
                    continuation.resume(returning: completed)
                    return false
                }
                guard var publication = completionPublications[id] else {
                    return true
                }
                publication.waiters.append(continuation)
                completionPublications[id] = publication
                return false
            }
            if shouldReturnNil {
                continuation.resume(
                    returning: DirectDownloadPauseResult(
                        attemptIdentifier: nil,
                        ownedRecovery: nil
                    )
                )
            }
        }
    }

    private func updateContext(
        for taskKey: TaskKey,
        _ update: (inout TaskContext) -> Void
    ) -> TaskContext? {
        mutateContext(for: taskKey) { context in
            update(&context)
        }?.context
    }

    private func mutateContext<Result>(
        for taskKey: TaskKey,
        _ mutation: (inout TaskContext) -> Result
    ) -> (context: TaskContext, result: Result)? {
        stateLock.withLock {
            guard var context = contexts[taskKey] else {
                return nil
            }

            let result = mutation(&context)
            contexts[taskKey] = context
            return (context, result)
        }
    }

    private func shouldIgnoreCompletion(taskKey: TaskKey) -> Bool {
        stateLock.withLock {
            suppressedCompletionTaskKeys.remove(taskKey) != nil
        }
    }

    private func makeSession() -> URLSession {
        let perDownloadConnectionCount = stateLock.withLock {
            transferSettings.perDownloadConnectionCount
        }

        let configuration = baseSessionConfiguration.copy() as! URLSessionConfiguration
        configuration.waitsForConnectivity = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = perDownloadConnectionCount
        configuration.allowsConstrainedNetworkAccess = true
        configuration.allowsExpensiveNetworkAccess = true

        return URLSession(
            configuration: configuration,
            delegate: self,
            delegateQueue: delegateQueue
        )
    }

    private func makeTaskKey(session: URLSession, taskIdentifier: Int) -> TaskKey {
        "\(ObjectIdentifier(session))-\(taskIdentifier)"
    }

    private func recoveryMetadata(
        for response: HTTPURLResponse,
        state: OwnedPartialState
    ) -> DirectDownloadRecoveryMetadata {
        DirectDownloadRecoveryMetadata(
            sourceURL: state.sourceURL,
            entityTag: response.value(forHTTPHeaderField: "ETag") ?? state.entityTag,
            lastModified: response.value(forHTTPHeaderField: "Last-Modified") ?? state.lastModified,
            expectedBytes: state.expectedBytes,
            suggestedFilename: response.suggestedFilename ?? state.suggestedFilename,
            mimeType: response.mimeType ?? state.responseMimeType
        )
    }

    private func resumeIdentity(
        for state: OwnedPartialState
    ) -> DirectDownloadResponsePolicy.ResumeIdentity? {
        guard state.resumeOffset > 0 else {
            return nil
        }
        let metadata = DirectDownloadRecoveryMetadata(
            sourceURL: state.sourceURL,
            entityTag: state.entityTag,
            lastModified: state.lastModified,
            expectedBytes: state.expectedBytes,
            suggestedFilename: state.suggestedFilename,
            mimeType: state.responseMimeType
        )
        return DirectDownloadResponsePolicy.ResumeIdentity(
            offset: state.resumeOffset,
            expectedBytes: state.expectedBytes,
            validator: metadata.ifRangeValidator
        )
    }

    private func apply(
        _ plan: DirectDownloadResponsePolicy.Plan,
        response: HTTPURLResponse,
        downloadID: UUID,
        state: inout OwnedPartialState,
        transferSample: inout TransferSample
    ) throws -> OwnedResponseDisposition {
        switch plan {
        case let .finishExisting(expectedBytes):
            state.expectedBytes = expectedBytes
            state.declaredExpectedBytes = expectedBytes
            // A validated 416 certifies the existing partial as the complete
            // representation. Keep the payload metadata from the original
            // response rather than adopting the 416 error body's metadata.
            state.statusCode = 206
            return .finishExistingPartial

        case let .receiveBody(destination, contentRange, expectedBytes, resetReason):
            switch destination {
            case .append:
                state.fileHandle = try recoveryStore.openFileForAppending(
                    id: downloadID,
                    expectedOffset: state.resumeOffset
                )

            case .fresh:
                if resetReason != nil {
                    try recoveryStore.discardThrowing(id: downloadID)
                    state.resumeOffset = 0
                    state.bytesWritten = 0
                    state.declaredExpectedBytes = nil
                    state.entityTag = nil
                    state.lastModified = nil
                    state.suggestedFilename = nil
                    state.responseMimeType = nil
                    transferSample = TransferSample(
                        lastTotalBytesWritten: 0,
                        sampleDate: .now,
                        speedBytesPerSecond: 0
                    )
                }
                state.fileHandle = try recoveryStore.openFreshFile(id: downloadID)
            }

            state.declaredExpectedBytes = expectedBytes
            if let expectedBytes {
                state.expectedBytes = expectedBytes
            } else if resetReason != nil {
                state.expectedBytes = 0
            }
            state.suggestedFilename = response.suggestedFilename ?? state.suggestedFilename
            state.responseMimeType = response.mimeType ?? state.responseMimeType
            state.statusCode = response.statusCode
            state.responseRangeEnd = contentRange?.end
            state.entityTag = response.value(forHTTPHeaderField: "ETag") ?? state.entityTag
            state.lastModified = response.value(forHTTPHeaderField: "Last-Modified")
                ?? state.lastModified

            try recoveryStore.saveMetadata(
                recoveryMetadata(for: response, state: state),
                id: downloadID
            )
            return .receiveBody(resetReason: resetReason)
        }
    }

    private func discardRejectedResume(
        downloadID: UUID,
        state: inout OwnedPartialState
    ) -> Error {
        state.resumeOffset = 0
        state.bytesWritten = 0
        state.declaredExpectedBytes = nil
        do {
            try recoveryStore.discardThrowing(id: downloadID)
            return DirectDownloadRecoveryRestartError()
        } catch {
            return error
        }
    }

    @discardableResult
    private func closeOwnedFile(
        in context: TaskContext,
        preservingRecovery: Bool
    ) -> Bool {
        guard let fileHandle = context.state.fileHandle else {
            return true
        }

        do {
            if preservingRecovery {
                try fileHandle.synchronize()
            }
            try fileHandle.close()
            return true
        } catch {
            try? fileHandle.close()
            if preservingRecovery {
                recoveryStore.discard(id: context.downloadID)
            }
            return false
        }
    }

    private func sealOwnedFile(in context: TaskContext) throws {
        guard let fileHandle = context.state.fileHandle else {
            return
        }
        do {
            try fileHandle.synchronize()
            try fileHandle.close()
        } catch {
            try? fileHandle.close()
            recoveryStore.discard(id: context.downloadID)
            throw error
        }
    }

    private func recoverableOwnedByteCount(in context: TaskContext) -> Int64? {
        switch recoveryStore.lookup(
            id: context.downloadID,
            sourceURL: context.state.sourceURL
        ) {
        case let .available(snapshot):
            return snapshot.bytesWritten
        case .absent:
            return 0
        case .unavailable:
            // The file handle was synchronized before this lookup. Preserve
            // the last byte count instead of converting a transient lookup
            // failure into a destructive fresh retry.
            return context.state.bytesWritten > 0 ? context.state.bytesWritten : nil
        }
    }

    private func claimOwnedPartial(
        context: TaskContext,
        state: OwnedPartialState
    ) throws -> CompletedDownloadHandoffClaim {
        try recoveryStore.publishCompletedPayload(
            id: context.downloadID,
            expectedBytes: state.expectedBytes
        ) { payloadURL in
            let actualBytes = try fileSize(at: payloadURL)
            return try completedHandoffStore.claim(
                payloadAt: payloadURL,
                manifest: CompletedDownloadHandoffManifest(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    owner: .direct,
                    sourceURL: context.sourceURL,
                    statusCode: state.statusCode,
                    mimeType: state.responseMimeType,
                    suggestedFilename: state.suggestedFilename,
                    actualBytes: actualBytes,
                    expectedBytes: state.expectedBytes
                )
            )
        }
    }

    private func finalizeCompletionClaim(
        _ claim: CompletedDownloadHandoffClaim,
        context: TaskContext,
        wasResuming: Bool,
        httpStatusCode: Int?
    ) {
        completionQueue.async { [self] in
            var publicationFailureMessage: String?
            do {
                let handoff = try completedHandoffStore.finalize(claim)
                eventHandler(
                    .finished(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        handoff: handoff
                    )
                )
            } catch {
                if completedHandoffStore.ownsAttempt(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                ) {
                    publicationFailureMessage = error.localizedDescription
                }
                eventHandler(
                    .failed(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: wasResuming,
                            recoverableBytes: 0,
                            httpStatusCode: httpStatusCode
                        )
                    )
                )
            }
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: publicationFailureMessage
            )
            context.session.finishTasksAndInvalidate()
        }
    }

    nonisolated static func throttleDelay(
        deltaBytes: Int64,
        elapsed: TimeInterval,
        activeTransferCount: Int,
        transferSettings: DownloadTransferSettings,
        speedLimitOverride: TransferLimitOverride
    ) -> TimeInterval? {
        guard elapsed > 0,
              deltaBytes > 0,
              let effectiveLimit = effectiveSpeedLimit(
                activeTransferCount: activeTransferCount,
                transferSettings: transferSettings,
                speedLimitOverride: speedLimitOverride
              ),
              effectiveLimit > 0 else {
            return nil
        }

        let desiredElapsed = Double(deltaBytes) / Double(effectiveLimit)
        let delay = desiredElapsed - elapsed
        guard delay > 0 else {
            return nil
        }

        return max(delay, 0.1)
    }

    nonisolated static func effectiveSpeedLimit(
        activeTransferCount: Int,
        transferSettings: DownloadTransferSettings,
        speedLimitOverride: TransferLimitOverride
    ) -> Int64? {
        var limits: [Int64] = []

        if let globalSpeedLimit = transferSettings.globalSpeedLimitBytesPerSecond {
            limits.append(max(globalSpeedLimit / Int64(max(activeTransferCount, 1)), 1))
        }

        if let perDownloadSpeedLimit = speedLimitOverride.resolvedBytesPerSecond(
            inheriting: transferSettings.perDownloadSpeedLimitBytesPerSecond
        ) {
            limits.append(perDownloadSpeedLimit)
        }

        return limits.min()
    }

    private func suspendForThrottle(taskKey: TaskKey, delay: TimeInterval) {
        var shouldSuspend = false
        var throttleGeneration: UInt64?
        let task = updateContext(for: taskKey) { context in
            guard context.isThrottled == false else {
                return
            }

            context.isThrottled = true
            context.throttleGeneration &+= 1
            throttleGeneration = context.throttleGeneration
            shouldSuspend = true
        }?.task

        guard shouldSuspend, let task, let throttleGeneration else {
            return
        }

        task.suspend()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            self?.resumeThrottledTask(
                taskKey: taskKey,
                throttleGeneration: throttleGeneration
            )
        }
    }

    private func resumeThrottledTask(
        taskKey: TaskKey,
        throttleGeneration: UInt64
    ) {
        var shouldResume = false
        let task = updateContext(for: taskKey) { context in
            guard context.isThrottled,
                  context.throttleGeneration == throttleGeneration else {
                return
            }

            context.isThrottled = false
            shouldResume = true
        }?.task

        if shouldResume {
            task?.resume()
        }
    }

    private func releaseThrottledTasksLocked() -> [URLSessionTask] {
        var tasks: [URLSessionTask] = []

        for taskKey in Array(contexts.keys) {
            guard var context = contexts[taskKey], context.isThrottled else {
                continue
            }

            context.isThrottled = false
            context.throttleGeneration &+= 1
            contexts[taskKey] = context
            tasks.append(context.task)
        }

        return tasks
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(
            forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size >= 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return Int64(size)
    }

}

extension DownloadCoordinator: URLSessionDataDelegate {
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: dataTask.taskIdentifier)
        guard let handledResponse = mutateContext(for: taskKey, { context in
            var state = context.state
            defer { context.state = state }
            guard let httpResponse = response as? HTTPURLResponse else {
                return OwnedResponseDisposition.reject(
                    error: URLError(.badServerResponse),
                    statusCode: nil,
                    wasResuming: false,
                    requiresFreshStart: false
                )
            }

            let wasResuming = state.resumeOffset > 0

            let plan: DirectDownloadResponsePolicy.Plan
            do {
                plan = try DirectDownloadResponsePolicy.plan(
                    for: httpResponse,
                    resume: resumeIdentity(for: state)
                )
            } catch {
                if error is DirectDownloadRecoveryRestartError {
                    return .reject(
                        error: discardRejectedResume(
                            downloadID: context.downloadID,
                            state: &state
                        ),
                        statusCode: httpResponse.statusCode,
                        wasResuming: wasResuming,
                        requiresFreshStart: true
                    )
                }
                return .reject(
                    error: error,
                    statusCode: httpResponse.statusCode,
                    wasResuming: wasResuming,
                    requiresFreshStart: false
                )
            }

            let requiresFreshStart: Bool
            if case let .receiveBody(_, _, _, resetReason) = plan {
                requiresFreshStart = resetReason != nil
            } else {
                requiresFreshStart = false
            }
            do {
                return try apply(
                    plan,
                    response: httpResponse,
                    downloadID: context.downloadID,
                    state: &state,
                    transferSample: &context.transferSample
                )
            } catch {
                return .reject(
                    error: error,
                    statusCode: httpResponse.statusCode,
                    wasResuming: wasResuming,
                    requiresFreshStart: requiresFreshStart
                )
            }
        }) else {
            completionHandler(.cancel)
            return
        }

        let updatedContext = handledResponse.context
        switch handledResponse.result {
        case .finishExistingPartial:
            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = stateLock.withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            completionHandler(.cancel)

            do {
                try sealOwnedFile(in: context)
                let claim = try claimOwnedPartial(context: context, state: context.state)
                finalizeCompletionClaim(
                    claim,
                    context: context,
                    wasResuming: true,
                    httpStatusCode: context.state.statusCode
                )
                return
            } catch {
                var publicationFailureMessage: String?
                if completedHandoffStore.ownsAttempt(
                    downloadID: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier
                ) {
                    publicationFailureMessage = error.localizedDescription
                }
                eventHandler(
                    .failed(
                        id: context.downloadID,
                        attemptIdentifier: context.attemptIdentifier,
                        failure: DirectDownloadFailure(
                            error: error,
                            resumeData: nil,
                            wasResuming: true,
                            recoverableBytes: recoverableOwnedByteCount(in: context)
                        )
                    )
                )
                finishCompletionPublication(
                    context: context,
                    recoveryUnavailableMessage: publicationFailureMessage
                )
                context.session.finishTasksAndInvalidate()
            }
            return

        case let .reject(
            responseError,
            responseStatusCode,
            responseWasResuming,
            responseRequiresFreshStart
        ):
            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                completionHandler(.cancel)
                return
            }
            _ = stateLock.withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            let didPreserveRecovery = closeOwnedFile(
                in: context,
                preservingRecovery: true
            )
            let pauseResult = ownedPauseResult(
                for: context,
                didPreserveRecovery: didPreserveRecovery
            )
            completionHandler(.cancel)
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: responseError,
                        resumeData: nil,
                        wasResuming: responseWasResuming,
                        recoverableBytes: didPreserveRecovery
                            ? recoverableOwnedByteCount(in: context)
                            : 0,
                        httpStatusCode: responseStatusCode,
                        forcesFreshStart: responseRequiresFreshStart
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            context.session.finishTasksAndInvalidate()
            return

        case let .receiveBody(resetReason):
            if let resetReason {
                eventHandler(
                    .recoveryReset(
                        id: updatedContext.downloadID,
                        attemptIdentifier: updatedContext.attemptIdentifier,
                        reason: resetReason
                    )
                )
            }
            completionHandler(.allow)
        }
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive data: Data
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: dataTask.taskIdentifier)
        var writeError: Error?
        var throttleDelay: TimeInterval?
        var progress: (
            id: UUID,
            attemptIdentifier: UUID,
            bytesWritten: Int64,
            expectedBytes: Int64,
            speed: Double
        )?

        guard let context = updateContext(for: taskKey, { context in
            var state = context.state
            defer { context.state = state }
            guard let fileHandle = state.fileHandle else {
                writeError = CocoaError(.fileWriteUnknown)
                return
            }

            do {
                let receivedByteCount = Int64(data.count)
                if receivedByteCount > 0 {
                    let rangeLimit = state.responseRangeEnd.flatMap { end in
                        end == Int64.max ? nil : end + 1
                    }
                    let absoluteByteLimit: Int64?
                    switch (rangeLimit, state.declaredExpectedBytes) {
                    case let (range?, declared?):
                        absoluteByteLimit = min(range, declared)
                    case let (range?, nil):
                        absoluteByteLimit = range
                    case let (nil, declared?):
                        absoluteByteLimit = declared
                    case (nil, nil):
                        absoluteByteLimit = nil
                    }
                    if let absoluteByteLimit {
                        let permittedByteCount = max(absoluteByteLimit - state.bytesWritten, 0)
                        let exceedsDeclaredBody = state.bytesWritten > absoluteByteLimit
                            || receivedByteCount > permittedByteCount
                        if exceedsDeclaredBody {
                            if permittedByteCount > 0 {
                                try fileHandle.write(
                                    contentsOf: Data(data.prefix(Int(permittedByteCount)))
                                )
                                state.bytesWritten += permittedByteCount
                            }
                            if let responseRangeEnd = state.responseRangeEnd,
                               absoluteByteLimit == rangeLimit {
                                writeError = DirectDownloadRangeOverflowError(
                                    declaredEnd: responseRangeEnd
                                )
                            } else {
                                writeError = DirectDownloadBodyOverflowError(
                                    expectedBytes: absoluteByteLimit
                                )
                            }
                            return
                        }
                    }
                }

                try fileHandle.write(contentsOf: data)
                state.bytesWritten += receivedByteCount

                let now = Date()
                let elapsed = now.timeIntervalSince(context.transferSample.sampleDate)
                if elapsed >= 0.35 {
                    let deltaBytes = state.bytesWritten - context.transferSample.lastTotalBytesWritten
                    let speed = elapsed > 0
                        ? Double(deltaBytes) / elapsed
                        : context.transferSample.speedBytesPerSecond
                    throttleDelay = Self.throttleDelay(
                        deltaBytes: deltaBytes,
                        elapsed: elapsed,
                        activeTransferCount: contexts.count,
                        transferSettings: transferSettings,
                        speedLimitOverride: context.speedLimitOverride
                    )
                    context.transferSample = TransferSample(
                        lastTotalBytesWritten: state.bytesWritten,
                        sampleDate: now,
                        speedBytesPerSecond: speed
                    )
                }

                progress = (
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    bytesWritten: state.bytesWritten,
                    expectedBytes: state.expectedBytes,
                    speed: context.transferSample.speedBytesPerSecond
                )
            } catch {
                writeError = error
            }
        }) else {
            return
        }

        if let writeError {
            guard let failedContext = beginCompletionPublication(forTaskKey: taskKey) else {
                return
            }
            _ = stateLock.withLock {
                suppressedCompletionTaskKeys.insert(taskKey)
            }
            let didPreserveRecovery = closeOwnedFile(
                in: failedContext,
                preservingRecovery: true
            )
            let pauseResult = ownedPauseResult(
                for: failedContext,
                didPreserveRecovery: didPreserveRecovery
            )
            failedContext.task.cancel()
            failedContext.session.finishTasksAndInvalidate()
            eventHandler(
                .failed(
                    id: failedContext.downloadID,
                    attemptIdentifier: failedContext.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: writeError,
                        resumeData: nil,
                        wasResuming: failedContext.state.resumeOffset > 0,
                        recoverableBytes: didPreserveRecovery
                            ? recoverableOwnedByteCount(in: failedContext)
                            : 0
                    )
                )
            )
            finishCompletionPublication(
                context: failedContext,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            return
        }

        if let progress {
            eventHandler(
                .progress(
                    id: progress.id,
                    attemptIdentifier: progress.attemptIdentifier,
                    bytesWritten: progress.bytesWritten,
                    expectedBytes: progress.expectedBytes,
                    speedBytesPerSecond: progress.speed
                )
            )
        }

        if let throttleDelay {
            suspendForThrottle(taskKey: taskKey, delay: throttleDelay)
        }
        _ = context
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        guard let context = stateLock.withLock({ contexts[taskKey] }) else {
            completionHandler(request)
            return
        }
        let state = context.state

        var redirectedRequest = request
        context.requestHeaders.apply(
            toSameOriginRedirect: &redirectedRequest,
            originatingAt: context.sourceURL
        )
        redirectedRequest.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        redirectedRequest.setValue(nil, forHTTPHeaderField: "Range")
        redirectedRequest.setValue(nil, forHTTPHeaderField: "If-Range")
        if state.resumeOffset > 0 {
            redirectedRequest.setValue(
                "bytes=\(state.resumeOffset)-",
                forHTTPHeaderField: "Range"
            )
            let validator = DirectDownloadRecoveryMetadata(
                sourceURL: state.sourceURL,
                entityTag: state.entityTag,
                lastModified: state.lastModified,
                expectedBytes: state.expectedBytes,
                suggestedFilename: state.suggestedFilename,
                mimeType: state.responseMimeType
            ).ifRangeValidator
            redirectedRequest.setValue(validator, forHTTPHeaderField: "If-Range")
        }
        completionHandler(redirectedRequest)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let taskKey = makeTaskKey(session: session, taskIdentifier: task.taskIdentifier)
        if let error {
            let nsError = error as NSError
            if shouldIgnoreCompletion(taskKey: taskKey) {
                return
            }

            guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
                return
            }

            let didPreserveRecovery = closeOwnedFile(
                in: context,
                preservingRecovery: true
            )
            let pauseResult = ownedPauseResult(
                for: context,
                didPreserveRecovery: didPreserveRecovery
            )

            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: nsError,
                        resumeData: nil,
                        wasResuming: context.state.resumeOffset > 0,
                        recoverableBytes: didPreserveRecovery
                            ? recoverableOwnedByteCount(in: context)
                            : 0
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                ownedRecovery: pauseResult.ownedRecovery,
                recoveryUnavailableMessage: pauseResult.recoveryUnavailableMessage
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        guard let context = beginCompletionPublication(forTaskKey: taskKey) else {
            return
        }
        let state = context.state

        do {
            try sealOwnedFile(in: context)
        } catch {
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: nil
            )
            context.session.finishTasksAndInvalidate()
            return
        }
        let actualBytes = recoveryStore.recoveredByteCount(id: context.downloadID)
            ?? state.bytesWritten
        let matchesDeclaredRange = state.responseRangeEnd.map {
            actualBytes > 0 && actualBytes - 1 == $0
        } ?? true
        let matchesDeclaredTotal = state.declaredExpectedBytes.map {
            actualBytes == $0
        } ?? true
        let hasVerifiableCompleteLength = state.statusCode != 206
            || state.declaredExpectedBytes != nil

        guard matchesDeclaredRange,
              matchesDeclaredTotal,
              hasVerifiableCompleteLength else {
            let expectedBytes = state.declaredExpectedBytes
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: HTTPDownloadIncompleteResponseError(
                            actualBytes: actualBytes,
                            expectedBytes: expectedBytes
                        ),
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: nil
            )
            context.session.finishTasksAndInvalidate()
            return
        }

        do {
            let claim = try claimOwnedPartial(context: context, state: state)
            finalizeCompletionClaim(
                claim,
                context: context,
                wasResuming: state.resumeOffset > 0,
                httpStatusCode: state.statusCode
            )
            return
        } catch {
            var publicationFailureMessage: String?
            if completedHandoffStore.ownsAttempt(
                downloadID: context.downloadID,
                attemptIdentifier: context.attemptIdentifier
            ) {
                publicationFailureMessage = error.localizedDescription
            }
            eventHandler(
                .failed(
                    id: context.downloadID,
                    attemptIdentifier: context.attemptIdentifier,
                    failure: DirectDownloadFailure(
                        error: error,
                        resumeData: nil,
                        wasResuming: state.resumeOffset > 0,
                        recoverableBytes: recoverableOwnedByteCount(in: context)
                    )
                )
            )
            finishCompletionPublication(
                context: context,
                recoveryUnavailableMessage: publicationFailureMessage
            )
            context.session.finishTasksAndInvalidate()
        }
    }
}
