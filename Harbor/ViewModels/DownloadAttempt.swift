import Foundation

/// Transient coordination for one download. Recovery paths and backend handles
/// remain on DownloadItem so persistence and live operations use the same owner.
nonisolated struct DownloadAttempt: Sendable {
    enum Operation: Hashable {
        case mediaStart, torrentStart, directPause, mediaPause, torrentPause
        case browserCancellation, mediaCleanup, completion, completionLookup
        case cancellation, removal, torrentStopSeeding, torrentCheck

        var reservesQueueSlot: Bool {
            switch self {
            case .completionLookup, .torrentStopSeeding:
                false
            default:
                true
            }
        }
    }

    enum Phase {
        case idle, preparing, active, pausing, cancelling, removing
        case completing, checking, cleaning, waitingToRetry, terminal
    }

    enum DirectPhase: Equatable {
        case active(UUID), pausing(UUID), cancelling(UUID), terminal(UUID)

        var identifier: UUID {
            switch self {
            case let .active(id), let .pausing(id), let .cancelling(id), let .terminal(id):
                id
            }
        }
    }

    private enum Writer {
        case direct(DirectPhase)
        case media(UUID)
        case torrent(UUID)
    }

    enum PauseFailure {
        case direct(DirectDownloadFailure)
        case browser(DirectDownloadFailure)
    }

    enum PauseResult {
        case direct(DirectDownloadPauseResult)
        case browser(BrowserDownloadQuiescence)
    }

    enum BrowserMutation {
        case cancel
        case remove(removingData: Bool)
    }

    enum Intent: Equatable {
        case pause, resume, retry, start, restartSeeding
        // A retry can wait behind cancellation without discarding the stop
        // request when WebKit has not confirmed writer quiescence.
        case cancel(retryAfterwards: Bool)
        case remove(removingData: Bool)
    }

    struct Retry {
        enum Schedule {
            case sleeping(Task<Void, Never>)
            case ready(restartingFromBeginning: Bool)
        }

        var count = 0
        var schedule: Schedule?

        var task: Task<Void, Never>? {
            guard case let .sleeping(task) = schedule else { return nil }
            return task
        }

        var ready: Bool? {
            guard case let .ready(restartingFromBeginning) = schedule else { return nil }
            return restartingFromBeginning
        }

        mutating func takeReady() -> Bool? {
            guard let ready else { return nil }
            schedule = nil
            return ready
        }
    }

    // Tasks can overlap while a writer stops. Keep every waiter until it drains;
    // the phase is derived from this ownership, never stored a second time.
    var tasks: [Operation: Task<Void, Never>] = [:]
    private(set) var pendingIntent: Intent?
    var browserReserved = false
    // A check can wait for an existing torrent start. Its operation token must
    // not replace that writer's token before the start has settled.
    var torrentCheckIdentifier: UUID?
    var retry = Retry()
    var pauseFailure: PauseFailure?
    var pauseResult: PauseResult?
    private var writer: Writer?

    var browserMutation: BrowserMutation? {
        get {
            switch pendingIntent {
            case .cancel: return .cancel
            case let .remove(removingData): return .remove(removingData: removingData)
            default: return nil
            }
        }
        set {
            switch newValue {
            case .cancel: request(.cancel(retryAfterwards: false))
            case let .remove(removingData): request(.remove(removingData: removingData))
            case nil:
                switch pendingIntent {
                case .cancel(retryAfterwards: true): pendingIntent = .retry
                case .cancel, .remove: pendingIntent = nil
                default: break
                }
            }
        }
    }

    mutating func request(_ intent: Intent) {
        switch (pendingIntent, intent) {
        case (.cancel, .retry), (.retry, .cancel), (.cancel(retryAfterwards: true), .cancel):
            pendingIntent = .cancel(retryAfterwards: true)
        case (_, .remove):
            pendingIntent = intent
        case (.remove, _):
            break
        case (_, .cancel):
            pendingIntent = intent
        case (.cancel, _), (.retry, .start), (.retry, .resume):
            break
        default:
            pendingIntent = intent
        }
    }

    @discardableResult
    mutating func takeIntent(_ intent: Intent) -> Bool {
        guard pendingIntent == intent else { return false }
        pendingIntent = nil
        return true
    }

    var directPhase: DirectPhase? {
        get {
            guard case let .direct(phase) = writer else { return nil }
            return phase
        }
        set {
            if let newValue { writer = .direct(newValue) }
            else if case .direct = writer { writer = nil }
        }
    }

    var mediaIdentifier: UUID? {
        get {
            guard case let .media(id) = writer else { return nil }
            return id
        }
        set {
            if let newValue { writer = .media(newValue) }
            else if case .media = writer { writer = nil }
        }
    }

    var torrentIdentifier: UUID? {
        get {
            guard case let .torrent(id) = writer else { return nil }
            return id
        }
        set {
            if let newValue { writer = .torrent(newValue) }
            else if case .torrent = writer { writer = nil }
        }
    }

    var phase: Phase {
        if tasks[.completion] != nil { return .completing }
        if tasks[.removal] != nil { return .removing }
        if tasks[.cancellation] != nil { return .cancelling }
        if tasks[.mediaCleanup] != nil { return .cleaning }
        if tasks[.torrentCheck] != nil { return .checking }
        if tasks[.directPause] != nil || tasks[.mediaPause] != nil
            || tasks[.torrentPause] != nil || tasks[.browserCancellation] != nil
            || tasks[.torrentStopSeeding] != nil { return .pausing }
        if tasks[.mediaStart] != nil || tasks[.torrentStart] != nil
            || tasks[.completionLookup] != nil { return .preparing }
        switch writer {
        case .direct(.pausing): return .pausing
        case .direct(.cancelling): return .cancelling
        case .direct(.terminal): return .terminal
        case .direct(.active), .media, .torrent: return .active
        case nil: return retry.schedule == nil ? .idle : .waitingToRetry
        }
    }

    var reservesQueueSlot: Bool {
        browserReserved
            || tasks.keys.contains(where: \.reservesQueueSlot)
    }

    @discardableResult
    mutating func takePauseFailure() -> PauseFailure? {
        defer { pauseFailure = nil }
        return pauseFailure
    }

    @discardableResult
    mutating func takePauseResult() -> PauseResult? {
        defer { pauseResult = nil }
        return pauseResult
    }
}
